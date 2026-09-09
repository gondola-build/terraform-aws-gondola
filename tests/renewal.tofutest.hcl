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

  mock_data "aws_subnet" {
    defaults = { availability_zone_id = "use2-az1" }
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

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-2:123456789012:cluster/gondola-renewal-test"
    }
  }

  mock_resource "aws_dynamodb_table" {
    defaults = {
      arn = "arn:aws:dynamodb:us-east-2:123456789012:table/gondola-renewal-test-coordination"
    }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-2:123456789012:task-definition/gondola-renewal-test-renewal:1"
    }
  }
  mock_resource "aws_scheduler_schedule_group" {
    defaults = {
      arn = "arn:aws:scheduler:us-east-2:123456789012:schedule-group/gondola-renewal-test-renewal"
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
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  github_config_url       = "https://github.com/example/gondola"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:github-ABC123"
  entitlement_secret_arn  = "arn:aws:secretsmanager:us-east-2:123456789012:secret:entitlement-DEF456"
  entitlement_public_key  = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  entitlement_key_id      = "published-key"
}

run "manual_profile_has_no_renewal_resources" {
  command = apply
  assert {
    condition     = length(aws_ecs_task_definition.renewal) == 0 && length(aws_scheduler_schedule.renewal) == 0 && length(aws_iam_role.renewal) == 0
    error_message = "Manual profile must create no renewal helper, timer, or role."
  }
  assert {
    condition     = !contains([for pair in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : pair.name], "GONDOLA_ENTITLEMENT_GENERATION_ENABLED")
    error_message = "Manual profile must preserve configured-generation semantics."
  }
}

run "opt_in_creates_scoped_helper_and_monitoring" {
  command = apply
  variables {
    entitlement_renewal_enabled   = true
    renewal_activation_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:activation-GHI789"
  }
  assert {
    condition     = length(aws_ecs_task_definition.renewal) == 1 && aws_scheduler_schedule.renewal[0].schedule_expression == "rate(6 hours)" && length(aws_cloudwatch_metric_alarm.renewal_missing) == 1 && length(aws_cloudwatch_metric_alarm.renewal_failure) == 1
    error_message = "Opt-in requires a scheduled helper and failed/missing-check monitoring."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.renewal[0].container_definitions)[0].command == ["renew-entitlement"] && !contains(keys(jsondecode(aws_ecs_task_definition.renewal[0].container_definitions)[0]), "secrets")
    error_message = "Helper must run the one-shot command without injecting secret values."
  }
  assert {
    condition     = !contains([for pair in jsondecode(aws_ecs_task_definition.renewal[0].container_definitions)[0].environment : pair.name], "GONDOLA_GITHUB_TOKEN") && !contains([for pair in jsondecode(aws_ecs_task_definition.renewal[0].container_definitions)[0].environment : pair.name], "GONDOLA_ENTITLEMENT")
    error_message = "Helper environment must contain only nonsecret configuration."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.renewal[0].policy).Statement[1].Resource == [var.entitlement_secret_arn] && jsondecode(aws_iam_role_policy.renewal[0].policy).Statement[2].Resource == [local.renewal_service_arn]
    error_message = "Renewal mutations must be scoped to the existing entitlement secret and service."
  }
  assert {
    condition     = !contains(flatten([for item in jsondecode(aws_iam_role_policy.renewal[0].policy).Statement : item.Action]), "iam:PassRole") && !contains(flatten([for item in jsondecode(aws_iam_role_policy.renewal[0].policy).Statement : item.Action]), "ecs:RegisterTaskDefinition") && !contains(flatten([for item in jsondecode(aws_iam_role_policy.renewal[0].policy).Statement : item.Resource]), var.github_token_secret_arn)
    error_message = "Helper must not receive controller credentials, PassRole, or task-registration permissions."
  }
}

run "renewal_rejects_ssm_profile" {
  command = plan
  variables {
    entitlement_renewal_enabled   = true
    entitlement_secret_arn        = "arn:aws:ssm:us-east-2:123456789012:parameter/entitlement"
    renewal_activation_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:activation-GHI789"
  }
  expect_failures = [aws_ecs_task_definition.renewal]
}

run "key_overlap_is_public_configuration" {
  command = apply
  variables {
    entitlement_trusted_keys = { "next-published-key" = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" }
  }
  assert {
    condition     = contains([for pair in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : pair.name], "GONDOLA_ENTITLEMENT_TRUSTED_KEYS_JSON")
    error_message = "Pinned key overlap must reach controller public configuration."
  }
}
