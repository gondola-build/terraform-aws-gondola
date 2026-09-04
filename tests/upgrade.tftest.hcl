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

run "apply_compatibility_fleet" {
  command = apply

  assert {
    condition     = output.fleet_scale_set_names["default"] == "gondola"
    error_message = "The legacy interface must normalize to the default fleet."
  }
}

run "plan_named_fleets_after_compatibility_upgrade" {
  command = plan

  variables {
    fleets = {
      linux-x64 = {
        scale_set_name = "gondola-linux-x64"
      }
      linux-arm64 = {
        scale_set_name = "gondola-linux-arm64"
        architecture   = "arm64"
      }
    }
  }

  assert {
    condition     = length(output.fleet_scale_set_names) == 2
    error_message = "The upgraded module must accept named fleets."
  }
}
