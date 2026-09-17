variable "adaptive_warm_pools" {
  description = "Opt-in adaptive warm targets keyed by fleet (default for legacy mode). Uses observed GitHub queue-to-runner-assignment delays; never terminates runners to reduce a warm target."
  type = map(object({
    max_runners                 = number
    target_queue_seconds        = number
    adjustment_interval_minutes = number
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for name, policy in var.adaptive_warm_pools : try(
        can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", name)) &&
        policy.max_runners >= 1 && floor(policy.max_runners) == policy.max_runners &&
        policy.target_queue_seconds >= 1 && policy.target_queue_seconds <= 3600 && floor(policy.target_queue_seconds) == policy.target_queue_seconds &&
        policy.adjustment_interval_minutes >= 1 && policy.adjustment_interval_minutes <= 60 && floor(policy.adjustment_interval_minutes) == policy.adjustment_interval_minutes,
      false)
    ])
    error_message = "Adaptive warm policies require a positive whole max_runners, a target of 1-3600 whole seconds, and an adjustment interval of 1-60 whole minutes."
  }
}

variable "fleet_budgets" {
  description = "Optional daily launch-admission allowances in USD by fleet. Reserves the operator's hourly rate times maximum runner lifetime per launch, including warm runners; this is not an AWS billing cap."
  type = map(object({
    daily_limit_usd        = number
    runner_hourly_rate_usd = number
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for name, policy in var.fleet_budgets : try(
        can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", name)) &&
        policy.daily_limit_usd > 0 && policy.daily_limit_usd <= 1000000 && floor(policy.daily_limit_usd * 1000000) == policy.daily_limit_usd * 1000000 &&
        policy.runner_hourly_rate_usd > 0 && policy.runner_hourly_rate_usd <= 1000000 && floor(policy.runner_hourly_rate_usd * 1000000) == policy.runner_hourly_rate_usd * 1000000,
      false)
    ])
    error_message = "Fleet budget limits and hourly estimates must be positive USD amounts no greater than 1 million with at most six decimal places."
  }
}

resource "aws_dynamodb_table" "budgets" {
  count        = length(var.fleet_budgets) > 0 ? 1 : 0
  name         = "${var.name}-budgets"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "BudgetKey"

  attribute {
    name = "BudgetKey"
    type = "S"
  }

  ttl {
    attribute_name = "ExpiresAt"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.tags
}

output "budget_table_name" {
  description = "Customer-owned daily admission ledger; null when fleet budgets are disabled. Preserve this table to preserve allowance usage."
  value       = length(var.fleet_budgets) > 0 ? aws_dynamodb_table.budgets[0].name : null
}

resource "aws_cloudwatch_metric_alarm" "budget_admission_errors" {
  for_each = var.alarms_enabled ? var.fleet_budgets : {}

  alarm_name          = "${var.name}-${each.key}-budget-admission-errors"
  alarm_description   = "Gondola cannot safely reserve launch allowance for fleet ${each.key}. Normal allowance exhaustion does not trigger this alarm."
  namespace           = var.metrics_namespace
  metric_name         = "BudgetAdmissionErrors"
  dimensions          = { Deployment = var.name, Fleet = each.key }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = tolist(var.alarm_action_arns)
  tags                = local.tags
}
