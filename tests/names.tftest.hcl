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

run "maximum_length_deployment_name" {
  command = plan

  variables {
    name                    = "gondola-e2e-20260903183029-31eb"
    vpc_id                  = "vpc-0123456789abcdef0"
    subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    github_config_url       = "https://github.com/example/gondola"
    github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
    entitlement_required    = false
  }
}

run "multiple_architectures_and_capacity_modes" {
  command = apply

  variables {
    name                    = "gondola-design-partner"
    vpc_id                  = "vpc-0123456789abcdef0"
    subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    github_config_url       = "https://github.com/example/gondola"
    github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
    entitlement_required    = false
    metrics_enabled         = true
    alarms_enabled          = true

    fleets = {
      linux-x64 = {
        scale_set_name    = "gondola-linux-x64"
        architecture      = "x64"
        capacity_mode     = "spot-with-on-demand-fallback"
        instance_type     = "m7i.large"
        egress_ipv4_cidrs = ["0.0.0.0/0", "0.0.0.0/0"]
      }
      linux-arm64 = {
        scale_set_name = "gondola-linux-arm64"
        architecture   = "arm64"
        capacity_mode  = "on-demand"
      }
    }
  }

  assert {
    condition     = length(output.runner_launch_template_ids) == 2
    error_message = "A launch template must be created for each fleet."
  }

  assert {
    condition     = aws_launch_template.runner["linux-arm64"].instance_type == "m7g.large"
    error_message = "ARM64 fleets must receive the Graviton default instance type."
  }

  assert {
    condition     = output.runner_role_arn == null
    error_message = "The compatibility role output must be null for multiple fleets."
  }

  assert {
    condition     = local.fleets["linux-x64"].capacity_mode == "spot-with-on-demand-fallback"
    error_message = "The normalized fleet must retain its capacity mode."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.runner_ipv4) == 2
    error_message = "Duplicate fleet CIDRs must be normalized before creating egress rules."
  }

  assert {
    condition     = aws_ecs_service.this.enable_ecs_managed_tags && aws_ecs_service.this.propagate_tags == "SERVICE"
    error_message = "Fargate tasks must inherit service tags for cost allocation."
  }

  assert {
    condition     = output.desired_count == 2 && aws_ecs_service.this.deployment_minimum_healthy_percent == 0 && aws_ecs_service.this.deployment_maximum_percent == 200
    error_message = "The production default must keep two active/passive tasks and permit generation-validated leadership handoff during replacement."
  }

  assert {
    condition     = aws_dynamodb_table.coordination.billing_mode == "PAY_PER_REQUEST" && aws_dynamodb_table.coordination.hash_key == "LeaseKey"
    error_message = "Controller coordination must use the on-demand single-key DynamoDB table."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.fleet_not_ready) == 2 && length(aws_cloudwatch_metric_alarm.runner_errors) == 6
    error_message = "Alarm-enabled deployments must create readiness and lifecycle-error alarms for every fleet."
  }

  assert {
    condition     = one([for item in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : item.value if item.name == "GONDOLA_COORDINATION_TABLE"]) == aws_dynamodb_table.coordination.name
    error_message = "Every controller task must receive the coordination table name."
  }

  assert {
    condition     = one([for item in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : item.value if item.name == "GONDOLA_DEPLOYMENT_GENERATION"]) == local.controller_generation
    error_message = "Every controller task must receive an immutable deployment generation."
  }
}

run "external_fleet_iam_selection" {
  command = plan

  variables {
    name                    = "gondola-external-iam"
    vpc_id                  = "vpc-0123456789abcdef0"
    subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    github_config_url       = "https://github.com/example/gondola"
    github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
    entitlement_required    = false

    fleets = {
      privileged = {
        iam_instance_profile_arn = "arn:aws:iam::123456789012:instance-profile/existing-runner"
        iam_role_arn             = "arn:aws:iam::123456789012:role/existing-runner"
      }
    }
  }

  assert {
    condition     = output.runner_role_arns["privileged"] == "arn:aws:iam::123456789012:role/existing-runner"
    error_message = "A fleet must be able to select a customer-managed runner role."
  }
}
