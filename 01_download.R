# =============================================================================
# 01_download.R
# Download apartment sale and rent (jeonse/wolse) transaction records from the
# Ministry of Land, Infrastructure and Transport (MOLIT) open API
# (data.go.kr) for the two GTX-A study areas.
#
#   - Eunpyeong-gu, Seoul (Yeonsinnae Station)   LAWD_CD = 11380
#   - Paju-si, Gyeonggi (Unjeong Jungang Station) LAWD_CD = 41480
#
# Output: one CSV per (type, district, month) in data/raw/, so the script can
#         be re-run safely and only fetches months that are missing.
#
# Setup: put your data.go.kr "Decoding" service key in ~/.Renviron as
#        DATA_GO_KR_KEY=xxxxxxxx
#        then restart R. Never write the key in this file.
# =============================================================================

library(httr2)
library(xml2)
library(dplyr)
library(purrr)
library(readr)

# ---- 1. Settings ------------------------------------------------------------

service_key <- Sys.getenv("DATA_GO_KR_KEY")
if (service_key == "") stop("DATA_GO_KR_KEY is not set. Add it to ~/.Renviron and restart R.")

endpoints <- c(
  # "아파트 매매 실거래가 상세 자료" (detailed version) uses the ...Dev endpoint
  trade = "https://apis.data.go.kr/1613000/RTMSDataSvcAptTradeDev/getRTMSDataSvcAptTradeDev",
  rent  = "https://apis.data.go.kr/1613000/RTMSDataSvcAptRent/getRTMSDataSvcAptRent"
)

districts <- c(eunpyeong = "11380", paju = "41480")

# Contract months: January 2022 through the current month
months <- format(seq(as.Date("2022-01-01"), Sys.Date(), by = "month"), "%Y%m")

rows_per_page <- 1000
raw_dir <- "data/raw"
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)


# ---- 2. Helper functions ----------------------------------------------------

# Request one page and return the parsed XML document
fetch_page <- function(endpoint, lawd_cd, deal_ymd, page_no) {
  resp <- request(endpoint) |>
    req_url_query(
      serviceKey = service_key,
      LAWD_CD    = lawd_cd,
      DEAL_YMD   = deal_ymd,
      pageNo     = page_no,
      numOfRows  = rows_per_page
    ) |>
    req_retry(max_tries = 3, backoff = ~ 2) |>
    req_timeout(30) |>
    req_perform()

  doc <- read_xml(resp_body_string(resp))

  # The API returns errors inside the XML body, not as HTTP errors
  code <- xml_text(xml_find_first(doc, "//resultCode"))
  if (!code %in% c("00", "000")) {
    msg <- xml_text(xml_find_first(doc, "//resultMsg"))
    stop(sprintf("API error %s (%s) for %s %s page %d", code, msg, lawd_cd, deal_ymd, page_no))
  }
  doc
}

# Turn every <item> into one row; keep all fields as text for now
# (cleaning and type conversion happen in 02_clean_merge.R)
parse_items <- function(doc) {
  items <- xml_find_all(doc, "//item")
  if (length(items) == 0) return(tibble())
  map_dfr(items, function(it) {
    kids <- xml_children(it)
    as_tibble(as.list(setNames(trimws(xml_text(kids)), xml_name(kids))))
  })
}

# Download all pages for one district-month and return a single data frame
fetch_month <- function(endpoint, lawd_cd, deal_ymd) {
  first <- fetch_page(endpoint, lawd_cd, deal_ymd, 1)
  total <- as.integer(xml_text(xml_find_first(first, "//totalCount")))
  if (is.na(total) || total == 0) return(tibble())

  n_pages <- ceiling(total / rows_per_page)
  pages <- c(list(parse_items(first)),
             map(seq_len(n_pages)[-1], \(p) parse_items(fetch_page(endpoint, lawd_cd, deal_ymd, p))))
  out <- bind_rows(pages)

  if (nrow(out) != total) warning(sprintf("%s %s: expected %d rows, got %d", lawd_cd, deal_ymd, total, nrow(out)))
  out
}


# ---- 3. Main loop -----------------------------------------------------------

jobs <- expand.grid(type = names(endpoints), district = names(districts), month = months,
                    stringsAsFactors = FALSE)

for (i in seq_len(nrow(jobs))) {
  job  <- jobs[i, ]
  file <- file.path(raw_dir, sprintf("%s_%s_%s.csv", job$type, job$district, job$month))
  if (file.exists(file)) next                     # already downloaded

  message(sprintf("[%d/%d] %s %s %s", i, nrow(jobs), job$type, job$district, job$month))
  df <- tryCatch(
    fetch_month(endpoints[[job$type]], districts[[job$district]], job$month),
    error = function(e) { message("  failed: ", conditionMessage(e)); NULL }
  )
  if (is.null(df)) next                           # skip; re-run the script later

  df <- mutate(df, type = job$type, district = job$district, query_month = job$month)
  write_csv(df, file)
  Sys.sleep(0.3)                                  # be gentle with the server
}


# ---- 4. Combine into one file per type --------------------------------------

for (t in names(endpoints)) {
  files <- list.files(raw_dir, pattern = sprintf("^%s_.*\\.csv$", t), full.names = TRUE)
  combined <- map_dfr(files, \(f) read_csv(f, col_types = cols(.default = col_character())))
  write_csv(combined, file.path(raw_dir, sprintf("all_%s.csv", t)))
  message(sprintf("%s: %d rows from %d files", t, nrow(combined), length(files)))
}

# Note: the most recent 1-2 months are incomplete because transactions can be
# reported up to 30 days after the contract. Delete those monthly files and
# re-run before the final analysis.
