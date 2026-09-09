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

  mock_data "aws_subnet" {
    defaults = {
      availability_zone_id = "use2-az1"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
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
  desired_count           = 1
  name                    = "gondola-warm-test"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  github_config_url       = "https://github.com/example/project"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
  entitlement_required    = false
}
run "windows_absent_by_default" {
  command = plan
  assert {
    condition     = !can(local.fleet_runtime_configuration[0].warm_windows)
    error_message = "Default runtime JSON must not gain a warm_windows field."
  }
}
run "utc_overnight_window" {
  command = apply
  variables {
    warm_windows = { default = [{ days = ["sun"], start_utc = "23:30", duration_minutes = 120, min_runners = 3 }] }
  }
  assert {
    condition     = local.fleet_runtime_configuration[0].warm_windows[0].duration_minutes == 120 && local.fleet_runtime_configuration[0].warm_windows[0].start_utc == "23:30"
    error_message = "Runtime configuration must preserve explicit UTC window boundaries."
  }
}
run "reject_unknown_fleet" {
  command = plan
  variables { warm_windows = { missing = [{ days = ["mon"], start_utc = "08:00", duration_minutes = 60, min_runners = 1 }] } }
  expect_failures = [aws_ecs_task_definition.this]
}
run "reject_above_maximum" {
  command = plan
  variables {
    max_runners  = 2
    warm_windows = { default = [{ days = ["mon"], start_utc = "08:00", duration_minutes = 60, min_runners = 3 }] }
  }
  expect_failures = [aws_ecs_task_definition.this]
}
run "reject_invalid_time" {
  command = plan
  variables { warm_windows = { default = [{ days = ["mon"], start_utc = "24:00", duration_minutes = 60, min_runners = 1 }] } }
  expect_failures = [var.warm_windows]
}
run "reject_duplicate_days" {
  command = plan
  variables { warm_windows = { default = [{ days = ["mon", "mon"], start_utc = "08:00", duration_minutes = 60, min_runners = 1 }] } }
  expect_failures = [var.warm_windows]
}
run "reject_short_interval" {
  command = plan
  variables { warm_windows = { default = [{ days = ["mon"], start_utc = "08:00", duration_minutes = 14, min_runners = 1 }] } }
  expect_failures = [var.warm_windows]
}
run "reject_too_many_windows" {
  command = plan
  variables { warm_windows = { default = [for i in range(17) : { days = ["mon"], start_utc = "08:00", duration_minutes = 60, min_runners = 1 }] } }
  expect_failures = [var.warm_windows]
}
