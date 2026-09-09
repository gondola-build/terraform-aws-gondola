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
  name                    = "gondola-storage"
  desired_count           = 1
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  github_config_url       = "https://github.com/example/gondola"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
  entitlement_required    = false
}

run "included_storage_defaults" {
  command = plan
  assert {
    condition = alltrue([for mapping in aws_launch_template.runner["default"].block_device_mappings :
      alltrue([for disk in mapping.ebs : disk.volume_size == 50 && disk.iops == 3000 && disk.throughput == 125 && disk.encrypted && disk.delete_on_termination])
    ])
    error_message = "The default must preserve included gp3 performance and ephemeral encrypted storage."
  }
}

run "fleet_storage_inheritance_and_override" {
  command = plan
  variables {
    runner_root_volume_size       = 100
    runner_root_volume_iops       = 8000
    runner_root_volume_throughput = 1000
    fleets = {
      inherited = {}
      overridden = {
        architecture           = "arm64"
        root_volume_size       = 160
        root_volume_iops       = 80000
        root_volume_throughput = 2000
      }
    }
  }
  assert {
    condition = alltrue([for mapping in aws_launch_template.runner["inherited"].block_device_mappings :
      alltrue([for disk in mapping.ebs : disk.volume_size == 100 && disk.iops == 8000 && disk.throughput == 1000])
    ])
    error_message = "A fleet must inherit configured storage defaults."
  }
  assert {
    condition = alltrue([for mapping in aws_launch_template.runner["overridden"].block_device_mappings :
      alltrue([for disk in mapping.ebs : disk.volume_size == 160 && disk.iops == 80000 && disk.throughput == 2000])
    ])
    error_message = "A fleet must be able to override all three gp3 parameters through launch configuration."
  }
}

run "reject_throughput_above_iops_ratio" {
  command = plan
  variables {
    runner_root_volume_throughput = 751
  }
  expect_failures = [aws_launch_template.runner["default"]]
}

run "reject_inherited_iops_above_smaller_fleet_volume" {
  command = plan
  variables {
    runner_root_volume_size = 160
    runner_root_volume_iops = 80000
    fleets = {
      smaller = { root_volume_size = 50 }
    }
  }
  expect_failures = [aws_launch_template.runner["smaller"]]
}

run "reject_fractional_iops" {
  command = plan
  variables {
    runner_root_volume_iops = 3000.5
  }
  expect_failures = [var.runner_root_volume_iops]
}

run "reject_fleet_throughput_above_service_limit" {
  command = plan
  variables {
    fleets = {
      invalid = { root_volume_throughput = 2001 }
    }
  }
  expect_failures = [var.fleets]
}
