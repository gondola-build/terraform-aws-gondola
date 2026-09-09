mock_provider "aws" {
  mock_data "aws_ec2_instance_type" { defaults = { supported_architectures = ["x86_64"] } }
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

run "optional_features_compose_in_deployed_configuration" {
  command = apply
  variables {
    entitlement_renewal_enabled       = true
    renewal_activation_secret_arn     = "arn:aws:secretsmanager:us-east-2:123456789012:secret:activation-GHI789"
    bootstrap_diagnostics_enabled     = true
    runner_instance_type_alternatives = ["m7a.large"]
    runner_root_volume_size           = 100
    runner_root_volume_iops           = 6000
    runner_root_volume_throughput     = 250
    cache_fleets                      = { default = { repository = "example/gondola", trust_namespace = "trusted" } }
    warm_windows                      = { default = [{ days = ["mon"], start_utc = "08:00", duration_minutes = 60, min_runners = 2 }] }
  }
  assert {
    condition     = jsondecode(local.environment.GONDOLA_FLEETS_JSON)[0].cache.repository == "example/gondola" && join(",", jsondecode(local.environment.GONDOLA_FLEETS_JSON)[0].instance_types) == "m7i.large,m7a.large" && jsondecode(local.environment.GONDOLA_FLEETS_JSON)[0].warm_windows[0].min_runners == 2
    error_message = "Fleet JSON must preserve cache, approved capacity and warm windows together."
  }
  assert {
    condition     = local.environment.GONDOLA_ENTITLEMENT_GENERATION_ENABLED == "true" && local.environment.GONDOLA_BOOTSTRAP_DIAGNOSTICS_ENABLED == "true" && length(aws_scheduler_schedule.renewal) == 1
    error_message = "Composed deployment must retain both controller flags and the independent renewal helper."
  }
  assert {
    condition     = one(aws_launch_template.runner["default"].block_device_mappings).ebs[0].iops == 6000 && one(aws_launch_template.runner["default"].block_device_mappings).ebs[0].throughput == 250
    error_message = "Capacity configuration must not overwrite the approved gp3 performance settings."
  }
}
