# =============================================================================
# 02b_geocode_merge.R
# 1) Geocode each apartment complex (parcel address -> lon/lat) with the
#    VWorld geocoder API.
# 2) Compute distance from each complex to its GTX-A station.
# 3) Assign treatment (<= 1 km) and control (2-4 km) groups and merge back
#    onto the sales and jeonse records.
#
# Setup: add your VWorld key to ~/.Renviron as  VWORLD_KEY=xxxxxxxx
#        and fill in the two station coordinates in section 3.
#
# Input : data/clean/complexes.csv, trade_clean.csv, jeonse_clean.csv
# Output: data/clean/complexes_geo.csv, trade_geo.csv, jeonse_geo.csv
# =============================================================================

library(httr2)
library(dplyr)
library(purrr)
library(readr)
library(sf)

vworld_key <- Sys.getenv("VWORLD_KEY")
if (vworld_key == "") stop("VWORLD_KEY is not set. Add it to ~/.Renviron and restart R.")


# ---- 1. Geocoding function --------------------------------------------------

geocode_parcel <- function(address) {
  resp <- request("https://api.vworld.kr/req/address") |>
    req_url_query(
      service = "address", request = "getcoord", version = "2.0",
      crs = "epsg:4326", type = "parcel", refine = "true", simple = "false",
      format = "json", address = address, key = vworld_key
    ) |>
    req_retry(max_tries = 3) |>
    req_timeout(30) |>
    req_perform() |>
    resp_body_json()

  if (resp$response$status != "OK") return(tibble(lon = NA_real_, lat = NA_real_))
  tibble(lon = as.numeric(resp$response$result$point$x),
         lat = as.numeric(resp$response$result$point$y))
}


# ---- 2. Geocode complexes (cached, so re-runs only fill the gaps) -----------

complexes <- read_csv("data/clean/complexes.csv", col_types = cols(.default = col_character()))
cache_file <- "data/clean/complexes_geo.csv"

if (file.exists(cache_file)) {
  done <- read_csv(cache_file, col_types = cols(aptSeq = "c", lon = "d", lat = "d")) |>
    filter(!is.na(lon))
} else {
  done <- tibble(aptSeq = character(), lon = double(), lat = double())
}

todo <- filter(complexes, !aptSeq %in% done$aptSeq)
message(sprintf("Geocoding %d complexes (%d already cached)", nrow(todo), nrow(done)))

new <- map_dfr(seq_len(nrow(todo)), function(i) {
  if (i %% 50 == 0) message(sprintf("  %d / %d", i, nrow(todo)))
  out <- tryCatch(geocode_parcel(todo$address[i]),
                  error = function(e) tibble(lon = NA_real_, lat = NA_real_))
  Sys.sleep(0.1)
  bind_cols(tibble(aptSeq = todo$aptSeq[i]), out)
})

geo <- bind_rows(done, new)
write_csv(geo, cache_file)

failed <- complexes |> left_join(geo, by = "aptSeq") |> filter(is.na(lon))
message(sprintf("Geocoded: %d   Not found: %d", nrow(complexes) - nrow(failed), nrow(failed)))
if (nrow(failed) > 0) write_csv(failed, "data/clean/geocode_failed.csv")


# ---- 3. Station coordinates --------------------------------------------------

stations <- tibble(
  district = c("eunpyeong", "paju"),
  station  = c("Yeonsinnae", "Unjeong Jungang"),
  lat      = c(37.61882, 37.71597),   # Yeonsinnae (Wikipedia), Unjeong Jungang (OpenStreetMap)
  lon      = c(126.92133, 126.72812)
)
if (any(is.na(stations$lat))) stop("Fill in the station coordinates in section 3.")


# ---- 4. Distance to station and treatment groups ----------------------------
# EPSG:5179 (Korea 2000 / Unified CS) is in meters.

cx <- complexes |>
  inner_join(geo, by = "aptSeq") |>
  filter(!is.na(lon)) |>
  st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE) |>
  st_transform(5179)

st <- stations |> st_as_sf(coords = c("lon", "lat"), crs = 4326) |> st_transform(5179)

cx$dist_m <- map_dbl(seq_len(nrow(cx)), function(i) {
  s <- st[st$district == cx$district[i], ]
  as.numeric(st_distance(cx[i, ], s))
})

cx <- cx |>
  st_drop_geometry() |>
  mutate(group = case_when(
    dist_m <= 1000                  ~ "treated",
    dist_m >= 2000 & dist_m <= 4000 ~ "control",
    TRUE                            ~ "excluded"
  )) |>
  select(aptSeq, lon, lat, dist_m, group)

print(count(left_join(cx, distinct(complexes, aptSeq, district), by = "aptSeq"), district, group))


# ---- 5. Merge onto transactions ---------------------------------------------

open_date <- as.Date("2024-12-28")   # GTX-A Unjeong Jungang - Seoul Station opening

add_geo <- function(df) {
  df |>
    inner_join(cx, by = "aptSeq") |>
    filter(group != "excluded") |>
    mutate(treated = as.integer(group == "treated"),
           post    = as.integer(date >= open_date))
}

trade  <- read_csv("data/clean/trade_clean.csv",  col_types = cols(aptSeq = "c", jibun = "c")) |> add_geo()
jeonse <- read_csv("data/clean/jeonse_clean.csv", col_types = cols(aptSeq = "c", jibun = "c")) |> add_geo()

write_csv(trade,  "data/clean/trade_geo.csv")
write_csv(jeonse, "data/clean/jeonse_geo.csv")

message("Analysis sample:")
print(count(trade,  district, group, post))
print(count(jeonse, district, group, post))
