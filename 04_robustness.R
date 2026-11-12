# =============================================================================
# 04_robustness.R
# Robustness checks for the main difference-in-differences estimates.
#
#  A. Few treated clusters
#     A1. Wild cluster bootstrap (restricted, Webb weights) p-values
#     A2. Permutation test: reassign treated status across complexes
#         (assumes exchangeability; treatment is set by distance, not at random)
#     A3. Leave-one-treated-complex-out (Unjeong)
#  B. Pre-trends
#     B1. Sample starting January 2023 (drops the 2022 rate-shock quarters)
#         + joint pre-trend test on the shorter window
#     B2. DiD with a treated-specific linear time trend
#  C. Design choices
#     C1. Treatment radius 500 m / 1 km / 1.5 km (control always 2-4 km)
#     C2. Placebo opening date (July 2023), pre-opening data only
#     C3. Seoul: contracts through September 2025 (before the October 2025
#         land-transaction permit zone)
#
# Main samples: brokered sales; new jeonse contracts.
# Run 01, 02a, 02b first. Runtime: roughly 10-20 minutes (set B below).
# Output: output/robustness.csv, output/loo_unjeong.csv,
#         output/pretrend_tests_2023.csv
# =============================================================================

library(dplyr)
library(readr)
library(lubridate)
library(fixest)
library(sf)

set.seed(20261112)
B <- 999                                   # bootstrap / permutation draws

open_month <- 2025 * 12 + 1                # Jan 2025 = first post month
stations <- tibble(district = c("eunpyeong", "paju"),
                   lat = c(37.61882, 37.71597), lon = c(126.92133, 126.72812))
station_name <- c(eunpyeong = "Yeonsinnae", paju = "Unjeong")


# ---- 0. Rebuild the analysis data with exact distances ----------------------
# (02b drops complexes 1-2 km away; the radius check needs them back.)

geo <- read_csv("data/clean/complexes_geo.csv", col_types = cols(aptSeq = "c", lon = "d", lat = "d")) |>
  filter(!is.na(lon)) |>
  inner_join(read_csv("data/clean/complexes.csv", col_types = cols(.default = "c")) |>
               select(aptSeq, district), by = "aptSeq")

pts <- st_transform(st_as_sf(geo, coords = c("lon", "lat"), crs = 4326), 5179)
sts <- st_transform(st_as_sf(stations, coords = c("lon", "lat"), crs = 4326), 5179)
geo$dist_m <- vapply(seq_len(nrow(pts)), function(i) {
  as.numeric(st_distance(pts[i, ], sts[sts$district == pts$district[i], ]))
}, numeric(1))

prep <- function(df, y) {
  df |>
    inner_join(select(geo, aptSeq, dist_m), by = "aptSeq") |>
    mutate(
      ym       = floor_date(date, "month"),
      rel_m    = (year(date) * 12 + month(date)) - open_month,
      post     = as.integer(rel_m >= 0),
      rel_q    = floor(rel_m / 3),
      log_y    = log(.data[[y]]),
      log_area = log(area_m2)
    ) |>
    filter(is.finite(log_y), !is.na(floor))
}

sale <- read_csv("data/clean/trade_clean.csv", col_types = cols(aptSeq = "c", jibun = "c")) |>
  filter(!direct) |> prep("price_per_m2")
jeon <- read_csv("data/clean/jeonse_clean.csv", col_types = cols(aptSeq = "c", jibun = "c")) |>
  filter(contract_type == "new") |> prep("deposit_per_m2")

# Assign groups for a given treatment radius (control = 2-4 km)
assign_groups <- function(df, radius = 1000) {
  df |>
    mutate(treated = case_when(dist_m <= radius ~ 1L,
                               dist_m >= 2000 & dist_m <= 4000 ~ 0L,
                               TRUE ~ NA_integer_)) |>
    filter(!is.na(treated))
}

main <- list(
  "Sale (brokered)" = assign_groups(sale),
  "Jeonse (new)"    = assign_groups(jeon)
)


# ---- Helpers ----------------------------------------------------------------

fml_did <- log_y ~ treated:post + log_area + floor | aptSeq + ym

fit <- function(df, fml = fml_did) feols(fml, data = df, cluster = ~ aptSeq)

row_of <- function(model, df, check, sample, station, extra = list()) {
  used <- df[obs(model), ]
  b  <- unname(coef(model)["treated:post"])
  se <- unname(se(model)["treated:post"])
  as_tibble(c(list(
    check = check, sample = sample, station = station,
    estimate = b, se = se,
    ci_low = b - 1.96 * se, ci_high = b + 1.96 * se,
    p_cluster = unname(pvalue(model)["treated:post"]),
    n_obs = nobs(model),
    n_treated = n_distinct(used$aptSeq[used$treated == 1]),
    n_control = n_distinct(used$aptSeq[used$treated == 0])
  ), extra))
}

# A1. Restricted wild cluster bootstrap with Webb six-point weights
wild_boot_p <- function(df) {
  m_u  <- fit(df)
  df   <- df[obs(m_u), ]
  m_r  <- feols(log_y ~ log_area + floor | aptSeq + ym, data = df)   # impose b = 0
  df   <- df[obs(m_r), ]
  m_u  <- fit(df)
  t0   <- unname(tstat(m_u)["treated:post"])
  yhat <- fitted(m_r); e <- resid(m_r)
  cl   <- unique(df$aptSeq)
  webb <- c(-sqrt(1.5), -1, -sqrt(0.5), sqrt(0.5), 1, sqrt(1.5))
  t_star <- vapply(seq_len(B), function(b) {
    w <- setNames(sample(webb, length(cl), replace = TRUE), cl)
    df$log_y <- yhat + e * w[df$aptSeq]
    unname(tstat(fit(df))["treated:post"])
  }, numeric(1))
  (1 + sum(abs(t_star) >= abs(t0))) / (B + 1)   # finite-sample Monte Carlo p-value
}

# A2. Permutation test: shuffle treated status across complexes, keeping the
#     number of treated complexes fixed. Treatment is determined by distance to
#     the station, so this is a sensitivity analysis under exchangeability,
#     not design-based randomization inference.
ri_p <- function(df) {
  b0 <- unname(coef(fit(df))["treated:post"])
  cx <- distinct(df, aptSeq, treated)
  b_perm <- vapply(seq_len(B), function(b) {
    cx_p <- mutate(cx, treated_p = sample(treated))
    d <- df |> select(-treated) |> left_join(select(cx_p, aptSeq, treated = treated_p), by = "aptSeq")
    unname(coef(fit(d))["treated:post"])
  }, numeric(1))
  (1 + sum(abs(b_perm) >= abs(b0))) / (B + 1)
}


# ---- A. Inference with few treated clusters ---------------------------------

rows <- list()
for (s in names(main)) {
  for (d in names(station_name)) {
    df <- filter(main[[s]], district == d)
    message(sprintf("Wild bootstrap and permutation test: %s - %s", s, station_name[d]))
    rows[[length(rows) + 1]] <- row_of(fit(df), df, "Baseline", s, station_name[d],
                                       list(p_wild_boot = wild_boot_p(df), p_permutation = ri_p(df)))
  }
}

# A3. Leave one treated complex out (Unjeong only)
loo <- list()
for (s in names(main)) {
  df <- filter(main[[s]], district == "paju")
  for (a in unique(df$aptSeq[df$treated == 1])) {
    d <- filter(df, aptSeq != a)
    m <- fit(d)
    loo[[length(loo) + 1]] <- tibble(sample = s, dropped_complex = a,
                                     aptNm = df$aptNm[df$aptSeq == a][1],
                                     estimate = unname(coef(m)["treated:post"]),
                                     se = unname(se(m)["treated:post"]))
  }
}
loo <- bind_rows(loo)
write_csv(loo, "output/loo_unjeong.csv")
print(loo |> group_by(sample) |>
        summarise(min = min(estimate), median = median(estimate), max = max(estimate)))


# ---- B. Pre-trends -----------------------------------------------------------

pre23 <- list()
for (s in names(main)) {
  for (d in names(station_name)) {
    df <- filter(main[[s]], district == d)

    # B1. Start in January 2023
    d23 <- filter(df, date >= as.Date("2023-01-01"))
    rows[[length(rows) + 1]] <- row_of(fit(d23), d23, "Sample from Jan 2023", s, station_name[d])
    es23 <- feols(log_y ~ i(rel_q, treated, ref = -1) + log_area + floor | aptSeq + ym,
                  data = d23, cluster = ~ aptSeq)
    w <- wald(es23, keep = "^rel_q::-[0-9]+:treated$", print = FALSE)
    pre23[[length(pre23) + 1]] <- tibble(sample = s, station = station_name[d],
                                         wald_stat = w$stat, p_value = w$p, n_pre_coefs = w$df1)

    # B2. Treated-specific linear trend
    m_tr <- fit(df, log_y ~ treated:post + treated:rel_m + log_area + floor | aptSeq + ym)
    rows[[length(rows) + 1]] <- row_of(m_tr, df, "Treated-specific linear trend", s, station_name[d])
  }
}
write_csv(bind_rows(pre23), "output/pretrend_tests_2023.csv")
print(bind_rows(pre23))


# ---- C. Design choices ------------------------------------------------------

raw <- list("Sale (brokered)" = sale, "Jeonse (new)" = jeon)
for (s in names(raw)) {
  for (d in names(station_name)) {

    # C1. Treatment radius
    for (r in c(500, 1500)) {
      df <- assign_groups(filter(raw[[s]], district == d), radius = r)
      rows[[length(rows) + 1]] <- row_of(fit(df), df, sprintf("Treatment radius %d m", r), s, station_name[d])
    }

    # C2. Placebo: pretend the line opened in July 2023; use data before Oct 2024
    df <- filter(main[[s]], district == d, date < as.Date("2024-10-01")) |>
      mutate(post = as.integer(date >= as.Date("2023-07-01")))
    rows[[length(rows) + 1]] <- row_of(fit(df), df, "Placebo opening Jul 2023", s, station_name[d])
  }

  # C3. Seoul before the October 2025 permit-zone designation
  df <- filter(main[[s]], district == "eunpyeong", date <= as.Date("2025-09-30"))
  rows[[length(rows) + 1]] <- row_of(fit(df), df, "Seoul: contracts through Sep 2025", s, "Yeonsinnae")
}


# ---- Save -------------------------------------------------------------------

robust <- bind_rows(rows) |> mutate(pct_change = 100 * (exp(estimate) - 1))
write_csv(robust, "output/robustness.csv")
print(robust |> select(check, sample, station, estimate, se, p_cluster, any_of(c("p_wild_boot", "p_permutation")),
                       n_treated, n_control) |>
        mutate(across(where(is.numeric), \(x) round(x, 3))), n = Inf, width = Inf)
message("Done. See output/robustness.csv, output/loo_unjeong.csv, output/pretrend_tests_2023.csv")
