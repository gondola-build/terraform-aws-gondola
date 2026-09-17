mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-2"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  override_data {
    target = data.aws_subnet.control_plane["0"]
    values = {
      availability_zone_id = "use2-az1"
    }
  }

  override_data {
    target = data.aws_subnet.control_plane["1"]
    values = {
      availability_zone_id = "use2-az2"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-2:123456789012:table/gondola-policy-test-budgets" }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/gondola-test"
      name = "gondola-test"
    }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:instance-profile/gondola-test"
      name = "gondola-test"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      arn            = "arn:aws:ec2:us-east-2:123456789012:launch-template/lt-0123456789abcdef0"
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }
}

variables {
  name                    = "gondola-policy-test"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  github_config_url       = "https://github.com/example/project"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
  entitlement_required    = false
}
run "unchanged_defaults" {
  command = plan
  assert {
    condition     = length(aws_dynamodb_table.budgets) == 0 && output.budget_table_name == null && !can(local.environment.GONDOLA_BUDGET_TABLE) && !can(local.fleet_runtime_configuration[0].budget) && !can(local.fleet_runtime_configuration[0].adaptive_warm_pool)
    error_message = "Default deployments must gain no policy fields, budget table, or budget environment."
  }
  assert {
    condition     = length([for statement in data.aws_iam_policy_document.controller.statement : statement if contains(["ReadFleetBudgetAdmissions", "ReserveFleetBudgetAdmissions"], statement.sid)]) == 0
    error_message = "Default controller IAM must gain no budget permissions."
  }
}

run "bounded_warm_policy_without_budget" {
  command = apply
  variables {
    max_runners         = 4
    adaptive_warm_pools = { default = { max_runners = 2, target_queue_seconds = 30, adjustment_interval_minutes = 5 } }
    warm_windows        = { default = [{ days = ["mon"], start_utc = "08:00", duration_minutes = 60, min_runners = 3 }] }
  }
  assert {
    condition     = local.fleet_runtime_configuration[0].adaptive_warm_pool.max_runners == 2 && local.fleet_runtime_configuration[0].adaptive_warm_pool.target_queue_seconds == 30 && local.fleet_runtime_configuration[0].adaptive_warm_pool.adjustment_interval_minutes == 5 && local.fleet_runtime_configuration[0].warm_windows[0].min_runners == 3
    error_message = "Explicit adaptive bounds and scheduled floors must reach the controller together."
  }
  assert {
    condition     = length(aws_dynamodb_table.budgets) == 0 && length(aws_cloudwatch_metric_alarm.budget_admission_errors) == 0
    error_message = "Adaptive capacity alone must not provision a budget ledger."
  }
}

run "separate_fleet_policies_and_durable_ledger" {
  command = apply
  variables {
    metrics_enabled = true
    alarms_enabled  = true
    fleets = {
      build   = { max_runners = 4 }
      release = { max_runners = 3 }
    }
    adaptive_warm_pools = { build = { max_runners = 2, target_queue_seconds = 45, adjustment_interval_minutes = 3 } }
    fleet_budgets = {
      build   = { daily_limit_usd = 20, runner_hourly_rate_usd = 0.125 }
      release = { daily_limit_usd = 50, runner_hourly_rate_usd = 0.25 }
    }
  }
  assert {
    condition     = local.fleet_runtime_configuration[0].budget.daily_limit_usd == 20 && local.fleet_runtime_configuration[1].budget.daily_limit_usd == 50 && !can(local.fleet_runtime_configuration[1].adaptive_warm_pool)
    error_message = "Budget allowances must remain fleet-specific; adaptive capacity must affect only opted-in fleets."
  }
  assert {
    condition     = aws_dynamodb_table.budgets[0].name == "gondola-policy-test-budgets" && aws_dynamodb_table.budgets[0].hash_key == "BudgetKey" && aws_dynamodb_table.budgets[0].billing_mode == "PAY_PER_REQUEST" && one(aws_dynamodb_table.budgets[0].ttl).enabled && one(aws_dynamodb_table.budgets[0].ttl).attribute_name == "ExpiresAt" && one(aws_dynamodb_table.budgets[0].server_side_encryption).enabled && one(aws_dynamodb_table.budgets[0].point_in_time_recovery).enabled
    error_message = "The ledger must use a stable name, BudgetKey, server-side encryption, PITR, and ExpiresAt retention."
  }
  assert {
    condition     = local.environment.GONDOLA_BUDGET_TABLE == aws_dynamodb_table.budgets[0].name && output.budget_table_name == aws_dynamodb_table.budgets[0].name && aws_dynamodb_table.coordination.hash_key == "LeaseKey"
    error_message = "The controller must use the separate ledger while lease coordination remains unchanged."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.budget_admission_errors) == 2 && alltrue([for alarm in values(aws_cloudwatch_metric_alarm.budget_admission_errors) : alarm.metric_name == "BudgetAdmissionErrors" && alarm.treat_missing_data == "notBreaching"]) && contains(keys(output.alarm_arns), "build:BudgetAdmissionErrors")
    error_message = "Only admission storage errors must receive a budget alarm, exposed by the module output."
  }
  assert {
    condition     = toset(one([for statement in data.aws_iam_policy_document.controller.statement : statement if statement.sid == "ReadFleetBudgetAdmissions"]).actions) == toset(["dynamodb:GetItem"]) && toset(one([for statement in data.aws_iam_policy_document.controller.statement : statement if statement.sid == "ReadFleetBudgetAdmissions"]).resources) == toset([aws_dynamodb_table.budgets[0].arn])
    error_message = "Budget reads must be GetItem scoped to the customer ledger."
  }
  assert {
    condition     = toset(one([for statement in data.aws_iam_policy_document.controller.statement : statement if statement.sid == "ReserveFleetBudgetAdmissions"]).actions) == toset(["dynamodb:PutItem", "dynamodb:UpdateItem"]) && toset(one([for statement in data.aws_iam_policy_document.controller.statement : statement if statement.sid == "ReserveFleetBudgetAdmissions"]).resources) == toset([aws_dynamodb_table.budgets[0].arn]) && one(one([for statement in data.aws_iam_policy_document.controller.statement : statement if statement.sid == "ReserveFleetBudgetAdmissions"]).condition).variable == "dynamodb:EnclosingOperation" && one(one([for statement in data.aws_iam_policy_document.controller.statement : statement if statement.sid == "ReserveFleetBudgetAdmissions"]).condition).test == "StringEquals" && toset(one(one([for statement in data.aws_iam_policy_document.controller.statement : statement if statement.sid == "ReserveFleetBudgetAdmissions"]).condition).values) == toset(["TransactWriteItems"])
    error_message = "Budget writes must require transactional PutItem/UpdateItem on the ledger without scan, delete, or broad table access."
  }
}

run "reject_unknown_adaptive_fleet" {
  command = plan
  variables { adaptive_warm_pools = { missing = { max_runners = 1, target_queue_seconds = 30, adjustment_interval_minutes = 5 } } }
  expect_failures = [aws_ecs_task_definition.this]
}
run "reject_adaptive_above_fleet_maximum" {
  command = plan
  variables {
    max_runners         = 2
    adaptive_warm_pools = { default = { max_runners = 3, target_queue_seconds = 30, adjustment_interval_minutes = 5 } }
  }
  expect_failures = [aws_ecs_task_definition.this]
}
run "reject_fractional_warm_target" {
  command = plan
  variables { adaptive_warm_pools = { default = { max_runners = 1.5, target_queue_seconds = 30, adjustment_interval_minutes = 5 } } }
  expect_failures = [var.adaptive_warm_pools]
}
run "reject_invalid_queue_target" {
  command = plan
  variables { adaptive_warm_pools = { default = { max_runners = 1, target_queue_seconds = 0, adjustment_interval_minutes = 5 } } }
  expect_failures = [var.adaptive_warm_pools]
}
run "reject_invalid_adjustment_interval" {
  command = plan
  variables { adaptive_warm_pools = { default = { max_runners = 1, target_queue_seconds = 30, adjustment_interval_minutes = 61 } } }
  expect_failures = [var.adaptive_warm_pools]
}
run "reject_unknown_budget_fleet" {
  command = plan
  variables { fleet_budgets = { missing = { daily_limit_usd = 20, runner_hourly_rate_usd = 0.1 } } }
  expect_failures = [aws_ecs_task_definition.this]
}
run "reject_nonpositive_budget" {
  command = plan
  variables { fleet_budgets = { default = { daily_limit_usd = 0, runner_hourly_rate_usd = 0.1 } } }
  expect_failures = [var.fleet_budgets]
}
run "reject_negative_hourly_rate" {
  command = plan
  variables { fleet_budgets = { default = { daily_limit_usd = 20, runner_hourly_rate_usd = -0.1 } } }
  expect_failures = [var.fleet_budgets]
}
run "reject_submicro_amount" {
  command = plan
  variables { fleet_budgets = { default = { daily_limit_usd = 20, runner_hourly_rate_usd = 0.0000001 } } }
  expect_failures = [var.fleet_budgets]
}
run "reject_out_of_range_amount" {
  command = plan
  variables { fleet_budgets = { default = { daily_limit_usd = 1000001, runner_hourly_rate_usd = 0.1 } } }
  expect_failures = [var.fleet_budgets]
}
