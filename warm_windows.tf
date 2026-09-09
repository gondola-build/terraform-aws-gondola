variable "warm_windows" {
  description = "Weekly UTC minimum/replenishment windows keyed by fleet (default for legacy mode). Windows only raise the baseline minimum; ending a window does not terminate existing runners."
  type = map(list(object({
    days             = list(string)
    start_utc        = string
    duration_minutes = number
    min_runners      = number
  })))
  default = {}

  validation {
    condition = alltrue([
      for name, windows in var.warm_windows :
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", name)) && length(windows) <= 16 && alltrue([
        for window in windows :
        length(window.days) >= 1 && length(window.days) <= 7 && length(distinct(window.days)) == length(window.days) &&
        alltrue([for day in window.days : contains(["sun", "mon", "tue", "wed", "thu", "fri", "sat"], day)]) &&
        can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", window.start_utc)) &&
        window.duration_minutes >= 15 && window.duration_minutes <= 1440 && floor(window.duration_minutes) == window.duration_minutes &&
        window.min_runners >= 0 && window.min_runners <= 1000 && floor(window.min_runners) == window.min_runners
      ])
    ])
    error_message = "Each fleet accepts at most 16 windows with unique lowercase weekday names, HH:MM UTC start, duration 15-1440 whole minutes, and a non-negative integer minimum no greater than 1000."
  }
}

locals {
  warm_window_configuration = {
    for name, windows in var.warm_windows : name => windows if length(windows) > 0
  }
}
