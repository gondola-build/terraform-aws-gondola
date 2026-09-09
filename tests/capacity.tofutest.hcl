mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["x86_64"] }
  }
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
  name                    = "gondola-capacity-test"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  github_config_url       = "https://github.com/example/project"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
  entitlement_required    = false
}

run "alternatives_off_by_default" {
  command = plan
  assert {
    condition     = length(data.aws_ec2_instance_type.approved) == 0 && !can(local.fleet_runtime_configuration[0].instance_types) && length(local.fixed_type_fleets) == 1
    error_message = "Defaults must retain the old JSON and single-type policy, with no type metadata queries."
  }
}

run "approved_order_and_iam" {
  command = apply
  variables {
    fleets = {
      build = { instance_type = "m7i.large", instance_type_alternatives = ["m7a.large", "m6i.large"] }
      fixed = { instance_type = "c7i.large" }
    }
  }
  assert {
    condition     = join(",", local.approved_instance_types["build"]) == "m7i.large,m7a.large,m6i.large" && join(",", local.fleet_runtime_configuration[0].instance_types) == "m7i.large,m7a.large,m6i.large"
    error_message = "The approved order must be primary then explicit alternatives."
  }
  assert {
    condition     = length(local.approved_type_checks) == 3 && !can(local.approved_instance_types["fixed"])
    error_message = "Metadata and overrides must apply only to fleets with alternatives."
  }
  assert {
    condition     = length([for statement in data.aws_iam_policy_document.controller.statement : statement if startswith(statement.sid, "LaunchApproved")]) == 1 && length(one([for statement in data.aws_iam_policy_document.controller.statement : statement if startswith(statement.sid, "LaunchApproved")]).condition) == 2
    error_message = "Approved-type launches require a fleet-specific IAM statement with both template and type conditions."
  }
}

run "reject_duplicate_primary" {
  command = plan
  variables { runner_instance_type_alternatives = ["m7i.large"] }
  expect_failures = [aws_launch_template.runner]
}

run "reject_invalid_type" {
  command = plan
  variables { runner_instance_type_alternatives = ["*"] }
  expect_failures = [var.runner_instance_type_alternatives]
}

run "reject_candidate_explosion" {
  command = plan
  variables {
    runner_instance_type_alternatives = ["m7a.large", "m6i.large"]
    runner_subnet_ids                 = [for i in range(12) : "subnet-${i}"]
  }
  expect_failures = [aws_launch_template.runner]
}

run "reject_wrong_architecture" {
  command = plan
  variables { runner_instance_type_alternatives = ["m7g.large"] }
  override_data {
    target = data.aws_ec2_instance_type.approved
    values = { supported_architectures = ["arm64"] }
  }
  expect_failures = [aws_launch_template.runner]
}
