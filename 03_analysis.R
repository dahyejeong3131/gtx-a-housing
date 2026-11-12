# =============================================================================
# 03_analysis.R  (revised)
# Did the GTX-A opening (Dec 28, 2024) raise sale prices and jeonse deposits
# near Yeonsinnae and Unjeong Jungang stations?
#
# Design: difference-in-differences within each district
#   treated = complexes within 1 km of the GTX-A station
#   control = complexes 2-4 km from the station (1-2 km excluded)
#   post    = contracts from January 2025 onward
#   outcome = log price (or jeonse deposit) per m2
#   fixed effects: complex + contract month; SEs clustered by complex
#   sample  = contracts through September 2026 (see 02a_clean.R)
#
# Main specifications: brokered sales; new jeonse contracts.
#
# Input : data/clean/trade_geo.csv, data/clean/jeonse_geo.csv
# Output: output/did_main.csv, output/did_secondary.csv, output/pretrend_tests.csv,
#         output/event_study.png, output/event_study_coefs.csv,
#         output/event_study_counts.csv, output/map_*.png
# =============================================================================

library(dplyr)
library(readr)
library(lubridate)
library(fixest)
library(ggplot2)
library(sf)

dir.create("output", showWarnings = FALSE)


# ---- 1. Load and prepare ----------------------------------------------------

prep <- function(df, y) {
  df |>
    mutate(
      ym       = floor_date(date, "month"),
      rel_m    = (year(date) * 12 + month(date)) - (2025 * 12 + 1),  # Jan 2025 = 0
      post     = as.integer(rel_m >= 0),
      rel_q    = floor(rel_m / 3),                                   # quarters since opening
      log_y    = log(.data[[y]]),
      log_area = log(area_m2)
    ) |>
    filter(is.finite(log_y))
}

trade  <- read_csv("data/clean/trade_geo.csv",  col_types = cols(aptSeq = "c", jibun = "c")) |> prep("price_per_m2")
jeonse <- read_csv("data/clean/jeonse_geo.csv", col_types = cols(aptSeq = "c", jibun = "c")) |> prep("deposit_per_m2")

samples <- list(
  # main specifications
  "Sale (brokered)"      = filter(trade, !direct),
  "Jeonse (new)"         = filter(jeonse, contract_type == "new"),
  # secondary
  "Sale (all)"           = trade,
  "Jeonse (all)"         = jeonse,
  "Jeonse (renewal, right used)"     = filter(jeonse, contract_type == "renewal_right"),
  "Jeonse (renewal, right not used)" = filter(jeonse, contract_type == "renewal_other")
)
main_names <- c("Sale (brokered)", "Jeonse (new)")
districts  <- c(Yeonsinnae = "eunpyeong", Unjeong = "paju")


# ---- 2. Difference-in-differences -------------------------------------------

did <- function(df) {
  feols(log_y ~ treated:post + log_area + floor | aptSeq + ym,
        data = df, cluster = ~ aptSeq)
}

# One tidy row per model: estimate, SE, 95% CI, p-value, N, clusters
tidy_did <- function(model, df, sample, station) {
  used <- df[obs(model), ]
  b  <- unname(coef(model)["treated:post"])
  se <- unname(se(model)["treated:post"])
  tibble(
    sample, station,
    estimate  = b, se = se,
    ci_low    = b - 1.96 * se, ci_high = b + 1.96 * se,
    p_value   = unname(pvalue(model)["treated:post"]),
    pct_change = 100 * (exp(b) - 1),
    n_obs     = nobs(model),
    n_treated_complexes = n_distinct(used$aptSeq[used$treated == 1]),
    n_control_complexes = n_distinct(used$aptSeq[used$treated == 0])
  )
}

results <- list()
for (s in names(samples)) {
  for (st in names(districts)) {
    df <- filter(samples[[s]], district == districts[[st]])
    results[[paste(s, st)]] <- tidy_did(did(df), df, s, st)
  }
}
results <- bind_rows(results)

write_csv(filter(results,  sample %in% main_names), "output/did_main.csv")
write_csv(filter(results, !sample %in% main_names), "output/did_secondary.csv")
print(results |> mutate(across(where(is.numeric), \(x) round(x, 3))), n = Inf, width = Inf)


# ---- 3. Event study (quarters relative to opening) --------------------------
# Coefficient for each quarter = treated-control gap relative to the quarter
# just before opening (rel_q = -1).

es <- function(df) {
  feols(log_y ~ i(rel_q, treated, ref = -1) + log_area + floor | aptSeq + ym,
        data = df, cluster = ~ aptSeq)
}

es_coefs <- function(model) {
  ct <- as.data.frame(coeftable(model))
  ct <- ct[grepl("^rel_q::", rownames(ct)), ]
  q  <- as.numeric(sub("^rel_q::(-?[0-9]+):treated$", "\\1", rownames(ct)))
  stopifnot(!anyNA(q))                       # coefficient names parsed correctly
  bind_rows(
    tibble(quarter = q, estimate = ct[, 1], se = ct[, 2]),
    tibble(quarter = -1, estimate = 0, se = 0)
  )
}

# Joint test that all pre-opening coefficients are zero
pretrend_test <- function(model) {
  w <- wald(model, keep = "^rel_q::-[0-9]+:treated$", print = FALSE)
  tibble(wald_stat = w$stat, p_value = w$p, n_pre_coefs = w$df1)
}

es_list <- list(); pre_list <- list(); count_list <- list()
for (s in main_names) {
  for (st in names(districts)) {
    df <- filter(samples[[s]], district == districts[[st]])
    m  <- es(df)
    lab <- paste(s, "-", st)
    es_list[[lab]]    <- mutate(es_coefs(m), series = lab)
    pre_list[[lab]]   <- mutate(pretrend_test(m), series = lab)
    count_list[[lab]] <- df |> count(rel_q, group = ifelse(treated == 1, "treated", "control")) |>
                           mutate(series = lab)
  }
}
es_df     <- bind_rows(es_list)
pre_df    <- bind_rows(pre_list)
counts_df <- bind_rows(count_list)

write_csv(es_df,     "output/event_study_coefs.csv")
write_csv(pre_df,    "output/pretrend_tests.csv")
write_csv(counts_df, "output/event_study_counts.csv")
print(pre_df)

# Label each panel with the pre-trend test p-value
pre_lab <- pre_df |> mutate(label = sprintf("Pre-trend joint test p = %.2f", p_value))

p_es <- ggplot(es_df, aes(quarter, estimate)) +
  geom_hline(yintercept = 0, colour = "grey50") +
  geom_vline(xintercept = -0.5, linetype = "dashed") +
  geom_ribbon(aes(ymin = estimate - 1.96 * se, ymax = estimate + 1.96 * se), alpha = 0.2) +
  geom_point() + geom_line() +
  geom_text(data = pre_lab, aes(x = -Inf, y = Inf, label = label),
            hjust = -0.05, vjust = 1.5, size = 3, inherit.aes = FALSE) +
  facet_wrap(~ series, ncol = 2) +
  labs(x = "Quarters relative to GTX-A opening (Dec 2024)",
       y = "Treated - control gap in log price per m2 (95% CI)",
       title = "Event study: apartments within 1 km vs. 2-4 km of the station",
       caption = "Contracts Jan 2022 - Sep 2026. Reference quarter: Oct-Dec 2024. SEs clustered by complex.") +
  theme_minimal()
ggsave("output/event_study.png", p_es, width = 9, height = 6.5, dpi = 200)

# Transactions per quarter behind each estimate
p_n <- ggplot(counts_df, aes(rel_q, n, fill = group)) +
  geom_col(position = "dodge") +
  geom_vline(xintercept = -0.5, linetype = "dashed") +
  facet_wrap(~ series, ncol = 2, scales = "free_y") +
  scale_fill_manual(values = c(treated = "#D55E00", control = "#0072B2")) +
  labs(x = "Quarters relative to GTX-A opening", y = "Transactions", fill = NULL,
       title = "Number of transactions per quarter") +
  theme_minimal()
ggsave("output/event_study_counts.png", p_n, width = 9, height = 6, dpi = 200)


# ---- 4. Maps ----------------------------------------------------------------

cx <- bind_rows(select(trade, aptSeq, district, group, lon, lat),
                select(jeonse, aptSeq, district, group, lon, lat)) |>
  distinct(aptSeq, .keep_all = TRUE) |>
  st_as_sf(coords = c("lon", "lat"), crs = 4326)

stations <- data.frame(
  district = c("eunpyeong", "paju"),
  lat = c(37.61882, 37.71597), lon = c(126.92133, 126.72812)
) |> st_as_sf(coords = c("lon", "lat"), crs = 4326)

for (d in districts) {
  p_map <- ggplot(filter(cx, district == d)) +
    geom_sf(aes(colour = group), size = 1.5) +
    geom_sf(data = filter(stations, district == d), shape = 17, size = 4, colour = "black") +
    scale_x_continuous(n.breaks = 4) +
    scale_colour_manual(values = c(treated = "#D55E00", control = "#0072B2")) +
    labs(title = sprintf("%s: complexes by distance to GTX-A station",
                         ifelse(d == "eunpyeong", "Yeonsinnae (Seoul)", "Unjeong Jungang (Paju)")),
         caption = "Black triangle = GTX-A station", colour = NULL) +
    theme_minimal()
  ggsave(sprintf("output/map_%s.png", d), p_map, width = 6, height = 6, dpi = 200)
}

message("Done. See output/ for tables and figures.")
