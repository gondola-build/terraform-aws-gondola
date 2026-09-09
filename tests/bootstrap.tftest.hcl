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
      arn = "arn:aws:ec2:us-east-2:123456789012:launch-template/lt-0123456789abcdef0"
      id  = "lt-0123456789abcdef0"
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
}

variables {
  name                    = "gondola-upgrade-test"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  github_config_url       = "https://github.com/example/gondola"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
  entitlement_required    = false
}

run "disabled_preserves_existing_shape" {
  command = apply
  assert {
    condition     = !contains(keys(local.environment), "GONDOLA_BOOTSTRAP_DIAGNOSTICS_ENABLED")
    error_message = "Disabled diagnostics must not add a controller environment variable."
  }
  assert {
    condition = local.controller_generation == sha256(jsonencode({
      container_image    = var.container_image
      cpu                = var.cpu
      memory             = var.memory
      stop_timeout       = var.controller_stop_timeout_seconds
      adopt_scale_sets   = var.adopt_existing_scale_sets
      generation_nonce   = var.deployment_generation_nonce
      github_config_url  = var.github_config_url
      github_environment = local.github_environment
      entitlement        = local.entitlement_environment
      secret_references  = merge(var.secrets, local.github_secrets, local.entitlement_secrets)
      fleets             = local.fleet_runtime_configuration
      environment        = var.environment
      metrics_enabled    = var.metrics_enabled
      metrics_namespace  = var.metrics_namespace
    }))
    error_message = "Disabled diagnostics must preserve the prior generation material exactly."
  }
  assert {
    condition     = alltrue([for fleet in local.fleet_runtime_configuration : toset(keys(fleet)) == toset(["name", "scale_set_name", "runner_group", "labels", "min_runners", "max_runners", "launch_template_id", "launch_template_version", "subnet_ids", "runner_image", "deployment_id", "max_runner_lifetime", "capacity_mode"])])
    error_message = "Diagnostics must not change the default fleet JSON schema."
  }
  assert {
    condition     = length([for statement in data.aws_iam_policy_document.controller.statement : statement.sid if contains(statement.actions, "ec2:GetConsoleOutput")]) == 0
    error_message = "Disabled diagnostics must grant no console-read permission."
  }
}

run "enabled_has_explicit_generation_and_scoped_read" {
  command = apply
  variables { bootstrap_diagnostics_enabled = true }
  assert {
    condition     = local.environment.GONDOLA_BOOTSTRAP_DIAGNOSTICS_ENABLED == "true"
    error_message = "Enabled diagnostics must reach the controller."
  }
  assert {
    condition = local.controller_generation != sha256(jsonencode({
      container_image    = var.container_image
      cpu                = var.cpu
      memory             = var.memory
      stop_timeout       = var.controller_stop_timeout_seconds
      adopt_scale_sets   = var.adopt_existing_scale_sets
      generation_nonce   = var.deployment_generation_nonce
      github_config_url  = var.github_config_url
      github_environment = local.github_environment
      entitlement        = local.entitlement_environment
      secret_references  = merge(var.secrets, local.github_secrets, local.entitlement_secrets)
      fleets             = local.fleet_runtime_configuration
      environment        = var.environment
      metrics_enabled    = var.metrics_enabled
      metrics_namespace  = var.metrics_namespace
    }))
    error_message = "Enabling diagnostics must change the controller generation."
  }
  assert {
    condition     = length([for statement in data.aws_iam_policy_document.controller.statement : statement.sid if contains(statement.actions, "ec2:GetConsoleOutput") && toset(statement.resources) == toset(["arn:aws:ec2:us-east-2:123456789012:instance/*"]) && length(statement.condition) == 2 && alltrue([for condition in statement.condition : condition.test == "StringEquals" && ((condition.variable == "ec2:ResourceTag/gondola:managed" && toset(condition.values) == toset(["true"])) || (condition.variable == "ec2:ResourceTag/gondola:deployment" && toset(condition.values) == toset(values(local.fleet_deployment_ids))))])]) == 1
    error_message = "Console reads require account/region instance scope and both managed/deployment tag conditions."
  }
}
