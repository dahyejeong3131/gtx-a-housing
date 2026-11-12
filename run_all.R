# Run the full pipeline in order (about 30-40 minutes in total).
# Requires DATA_GO_KR_KEY and VWORLD_KEY in ~/.Renviron.
for (s in c("01_download.R", "02a_clean.R", "02b_geocode_merge.R",
            "03_analysis.R", "04_robustness.R")) {
  message("\n==== Running ", s, " ====")
  source(s, echo = FALSE)
}
writeLines(capture.output(sessionInfo()), "output/session_info.txt")
message("All done.")
