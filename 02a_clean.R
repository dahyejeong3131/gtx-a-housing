# =============================================================================
# 02a_clean.R  (revised)
# Clean the raw MOLIT transaction files, document every sample restriction,
# and build the list of apartment complexes to geocode.
#
# Input : data/raw/all_trade.csv, data/raw/all_rent.csv  (from 01_download.R)
# Output: data/clean/trade_clean.csv    sales
#         data/clean/jeonse_clean.csv   pure jeonse leases (monthly rent = 0)
#         data/clean/complexes.csv      one row per complex, with parcel address
#         output/sample_flow.csv        rows kept/dropped at each step
#         output/jeonse_contract_types.csv
# =============================================================================

library(dplyr)
library(readr)
library(lubridate)

dir.create("data/clean", recursive = TRUE, showWarnings = FALSE)
dir.create("output", showWarnings = FALSE)

# Last complete contract month. Transactions may be reported up to 30 days
# after signing, so months close to the extraction date are incomplete.
extraction_date <- as.Date("2026-11-12")
last_month_end  <- as.Date("2026-09-30")

trade_raw <- read_csv("data/raw/all_trade.csv", col_types = cols(.default = col_character()))
rent_raw  <- read_csv("data/raw/all_rent.csv",  col_types = cols(.default = col_character()))

num  <- function(x) parse_number(x)          # "85,000" -> 85000
sido <- c(eunpyeong = "서울특별시 은평구", paju = "경기도 파주시")

flow <- list()                               # sample-flow log
log_step <- function(df, data, step) {
  flow[[length(flow) + 1]] <<- tibble(data = data, step = step, rows = nrow(df))
  df
}


# ---- 1. Sales ---------------------------------------------------------------

trade <- trade_raw |>
  log_step("sale", "1 raw records") |>
  mutate(
    date       = make_date(num(dealYear), num(dealMonth), num(dealDay)),
    price_man  = num(dealAmount),                       # 10,000 KRW
    area_m2    = num(excluUseAr),
    floor      = num(floor),
    build_year = num(buildYear),
    cancelled  = !is.na(cdealType) & cdealType != "",
    direct     = dealingGbn == "직거래"                   # no broker; often related-party
  ) |>
  filter(!cancelled)                                       |> log_step("sale", "2 drop cancelled deals") |>
  filter(!is.na(date), !is.na(price_man), price_man > 0,
         !is.na(area_m2), area_m2 > 0)                     |> log_step("sale", "3 drop invalid date/price/area") |>
  filter(date <= last_month_end)                           |> log_step("sale", "4 keep contracts through 2026-09") |>
  distinct(aptSeq, aptDong, floor, area_m2, price_man, date, .keep_all = TRUE) |>
                                                              log_step("sale", "5 drop exact duplicates (same building, floor, area, price, date)") |>
  mutate(price_per_m2 = price_man / area_m2) |>
  select(district, aptSeq, aptNm, umdNm, jibun, date, price_man, area_m2,
         price_per_m2, floor, build_year, direct)

trade |> filter(!direct) |> log_step("sale", "6 brokered only (main specification)") |> invisible()


# ---- 2. Jeonse leases --------------------------------------------------------
# contract_type: "new", "renewal_right" (tenant exercised the statutory renewal
# right), "renewal_other" (renewal without exercising it), "unknown" (blank).

jeonse <- rent_raw |>
  log_step("jeonse", "1 raw lease records") |>
  mutate(
    date         = make_date(num(dealYear), num(dealMonth), num(dealDay)),
    deposit_man  = num(deposit),
    monthly_rent = num(monthlyRent),
    area_m2      = num(excluUseAr),
    floor        = num(floor),
    build_year   = num(buildYear),
    contract_type = case_when(
      contractType == "신규"                          ~ "new",
      contractType == "갱신" & useRRRight == "사용"   ~ "renewal_right",
      contractType == "갱신"                          ~ "renewal_other",
      TRUE                                            ~ "unknown"
    )
  ) |>
  filter(monthly_rent == 0)                                |> log_step("jeonse", "2 pure jeonse (monthly rent = 0)") |>
  filter(!is.na(date), !is.na(deposit_man), deposit_man > 0,
         !is.na(area_m2), area_m2 > 0)                     |> log_step("jeonse", "3 drop invalid date/deposit/area") |>
  filter(date <= last_month_end)                           |> log_step("jeonse", "4 keep contracts through 2026-09") |>
  mutate(deposit_per_m2 = deposit_man / area_m2) |>
  select(district, aptSeq, aptNm, umdNm, jibun, date, deposit_man, area_m2,
         deposit_per_m2, floor, build_year, contract_type)

jeonse |> filter(contract_type == "new") |> log_step("jeonse", "5 new contracts only (main specification)") |> invisible()

write_csv(count(jeonse, district, contract_type), "output/jeonse_contract_types.csv")


# ---- 3. Complex list for geocoding -----------------------------------------
# aptSeq starts with the 5-digit district code (e.g., 11380-xxxx), so it is
# unique across districts. Check this explicitly.

stopifnot(all(substr(trade$aptSeq, 1, 5) %in% c("11380", "41480")))

complexes <- bind_rows(
  select(trade,  district, aptSeq, aptNm, umdNm, jibun),
  select(jeonse, district, aptSeq, aptNm, umdNm, jibun)
) |>
  filter(!is.na(jibun), jibun != "") |>
  distinct(aptSeq, .keep_all = TRUE) |>
  mutate(address = paste(sido[district], umdNm, jibun))


# ---- 4. Save and report -----------------------------------------------------

write_csv(trade,     "data/clean/trade_clean.csv")
write_csv(jeonse,    "data/clean/jeonse_clean.csv")
write_csv(complexes, "data/clean/complexes.csv")

sample_flow <- bind_rows(flow) |> mutate(extraction_date = extraction_date)
write_csv(sample_flow, "output/sample_flow.csv")

print(sample_flow, n = Inf)
print(count(jeonse, contract_type))
message(sprintf("Complexes to geocode: %d", nrow(complexes)))
