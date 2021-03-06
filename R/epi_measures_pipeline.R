#' Estimate time-varying measures and forecast
#'
#' @param nowcast A nowcast as produced by `nowcast_pipeline`
#' @param rt_windows Numeric vector, windows over which to estimate time-varying R. The best performing window will be 
#' selected per serial interval sample by default (based on which window best forecasts current cases).
#' @param rate_window Numeric, the window to use to estimate the rate of spread.
#' @param verbose Logical, defaults to `TRUE`. Should progress messages be shown.
#' @inheritParams estimate_R0
#' @return
#' @export
#' @importFrom tidyr gather nest unnest drop_na
#' @importFrom dplyr filter group_by ungroup mutate select summarise n group_split bind_rows
#' @importFrom purrr safely compact map_dbl map pmap transpose
#' @importFrom HDInterval hdi
#' @importFrom furrr future_map future_options
#' @importFrom data.table setDT setorder
#' @examples 
#'
epi_measures_pipeline <- function(nowcast = NULL,
                                  serial_intervals = NULL,
                                  min_est_date = NULL,
                                  si_samples = NULL, rt_samples = NULL,
                                  rt_windows = 7, rate_window = 7,
                                  rt_prior = NULL, forecast_model = NULL,
                                  horizon = NULL, verbose = TRUE) {

  ## Estimate time-varying R0
  safe_R0 <- purrr::safely(EpiNow::estimate_R0)
  
  process_R0 <- function(data) {
    estimates <- safe_R0(cases = data,
                         serial_intervals = serial_intervals,
                         rt_prior = rt_prior,
                         si_samples = si_samples,
                         rt_samples = rt_samples,
                         windows = rt_windows,
                         min_est_date = min_est_date, 
                         forecast_model = forecast_model,
                         horizon = horizon)[[1]]
    
    if (!is.null(estimates$rts)) {
      estimates$rts <-  dplyr::mutate(estimates$rts[[1]], type = data$type[1],
                                      sample = data$sample[1])
    }
    
    if (!is.null(estimates$cases)) {
      estimates$cases <-  dplyr::mutate(estimates$cases[[1]], type = data$type[1],
                                        sample = data$sample[1])
    }
    
    return(estimates)
  }

  if (verbose) {
    message("Estimate time-varying R0")
  }

  data_list <-  dplyr::group_split(nowcast, type, sample, keep = TRUE)

 
  estimates <- furrr::future_map(data_list, process_R0, 
                                 .progress = verbose,
                                 .options = furrr::future_options(packages = c("EpiNow", "dplyr"),
                                                                  scheduling = 20))
  
  ## Clean up NULL rt estimates and bind together
  R0_estimates <-   
    purrr::map(estimates, ~ .$rts) %>% 
    purrr::compact() %>% 
    dplyr::bind_rows()

  
  ## Generic HDI return function
  return_hdi <- function(vect = NULL, mass = NULL, index = NULL) {
    as.numeric(purrr::map_dbl(list(HDInterval::hdi(vect, credMass = mass)), ~ .[[index]]))
  }

  if (verbose) {
  message("Summarising time-varying R0")
  }

  R0_estimates_sum <- data.table::setDT(R0_estimates, key = c("type", "date", "rt_type"))[, .(
    bottom  = return_hdi(R, 0.9, 1),
    top = return_hdi(R, 0.9, 2),
    lower  = return_hdi(R, 0.5, 1),
    upper = return_hdi(R, 0.5, 2),
    median = median(R, na.rm = TRUE),
    mean = mean(R, na.rm = TRUE),
    std = sd(R, na.rm = TRUE),
    prob_control = (sum(R < 1) / .N),
    mean_window = mean(window), 
    sd_window = sd(window)),
    by = .(type, date, rt_type)
    ][, R0_range := purrr::pmap(
      list(mean, bottom, top, lower, upper),
      function(mean, bottom, top, lower, upper) {
        list(point = mean,
             lower = bottom, 
             upper = top,
             mid_lower = lower,
             mid_upper = upper)
      }),]


  R0_estimates_sum <- data.table::setorder(R0_estimates_sum, date)

  if (verbose) {
    message("Summarising forecast cases")
  }
  
  cases_forecast <- estimates %>% 
    purrr::map(~ .$cases) %>% 
    purrr::compact()
    
    
  if (!(is.null(cases_forecast) | length(cases_forecast) == 0)) {
    
    ## Clean up case forecasts
    cases_forecast <- cases_forecast %>% 
      dplyr::bind_rows()
    
    ## Summarise case forecasts
    sum_cases_forecast <- data.table::setDT(cases_forecast, key = c("type", "date", "rt_type"))[, .(
      bottom  = return_hdi(cases, 0.9, 1),
      top = return_hdi(cases, 0.9, 2),
      lower  = return_hdi(cases, 0.5, 1),
      upper = return_hdi(cases, 0.5, 2),
      median = as.numeric(median(cases, na.rm = TRUE)),
      mean = as.numeric(mean(cases, na.rm = TRUE)),
      std = as.numeric(sd(cases, na.rm = TRUE))),
      by = .(type, date, rt_type)
      ][, range := purrr::pmap(
        list(mean, bottom, top),
        function(mean, bottom, top) {
          list(point = mean,
               lower = bottom, 
               upper = top)
        }),]
    
    sum_cases_forecast <- data.table::setorder(sum_cases_forecast, date)
  }

  ## Estimate time-varying little r
  if (verbose) {
    message("Estimate time-varying rate of growth")
  }

  if (!is.null(min_est_date)) {
    little_r_estimates <-  
      dplyr::filter(nowcast, date >= (min_est_date - lubridate::days(rate_window)))
  }else{
    little_r_estimates <- nowcast
  }

  ## Sum across cases and imports
  little_r_estimates <-
    group_by(little_r_estimates, type, sample, date) %>%
    dplyr::summarise(cases = sum(cases, na.rm  = TRUE)) %>%
    dplyr::ungroup() %>%
    tidyr::drop_na()

  ## Nest by type and sample then split by type only
  little_r_estimates_list <-
    dplyr::group_by(little_r_estimates, type, sample) %>%
    tidyr::nest() %>%
    dplyr::ungroup() %>%
    dplyr::group_split(type, keep = TRUE)

  ## Pull out unique list
  little_r_estimates_res <- dplyr::select(little_r_estimates, type) %>%
    unique()

  ## Estimate overall
  little_r_estimates_res$overall_little_r <- furrr::future_map(little_r_estimates_list,
                                                        ~ EpiNow::estimate_r_in_window(.$data), 
                                                        .options = furrr::future_options(packages = "EpiNow",
                                                                                         scheduling = 10),
                                                        .progress = verbose)

  ## Estimate time-varying
  little_r_estimates_res$time_varying_r <- furrr::future_map(little_r_estimates_list,
                                                             ~ EpiNow::estimate_time_varying_r(.$data,
                                                                                               window = rate_window),
                                                             .options = furrr::future_options(globals = c("rate_window"),
                                                                                              packages = "EpiNow",
                                                                                              scheduling = 10),
                                                             .progress = verbose)


  out <- list(R0_estimates_sum, little_r_estimates_res, R0_estimates)
  names(out) <- c("R0", "rate_of_spread", "raw_R0")

  if (!(is.null(cases_forecast) | length(cases_forecast) == 0)) {
    
    out$case_forecast <- sum_cases_forecast
    out$raw_case_forecast <- cases_forecast

  }
  
  return(out)
}

