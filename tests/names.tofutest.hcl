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

run "multiple_architectures_and_capacity_modes" {
  command = plan

  variables {
    name                    = "gondola-opentofu-test"
    vpc_id                  = "vpc-0123456789abcdef0"
    subnet_ids              = ["subnet-0123456789abcdef0"]
    container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    github_config_url       = "https://github.com/example/gondola"
    github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
    entitlement_required    = false
    desired_count           = 1

    fleets = {
      linux-x64 = {
        scale_set_name = "gondola-linux-x64"
        architecture   = "x64"
        capacity_mode  = "spot-with-on-demand-fallback"
        instance_type  = "m7i.large"
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
    condition     = local.fleets["linux-x64"].capacity_mode == "spot-with-on-demand-fallback"
    error_message = "The normalized fleet must retain its capacity mode."
  }

  assert {
    condition     = output.desired_count == 1
    error_message = "OpenTofu must preserve the selected controller count."
  }
}
