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
  name                    = "gondola-cache-test"
  vpc_id                  = "vpc-0123456789abcdef0"
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  container_image         = "123456789012.dkr.ecr.us-east-2.amazonaws.com/gondola@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  github_config_url       = "https://github.com/example/project"
  github_token_secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:gondola-test"
  entitlement_required    = false
}

run "cache_off_by_default" {
  command = plan
  assert {
    condition     = length(aws_s3_bucket.cache) == 0 && length(aws_iam_role_policy.cache) == 0 && !can(local.fleet_runtime_configuration[0].cache)
    error_message = "Default deployments must not create cache resources, IAM grants, or bootstrap configuration."
  }
}

run "scoped_cache" {
  command = apply
  variables {
    cache_fleets = {
      default = { repository = "example/project", trust_namespace = "trusted" }
    }
  }
  assert {
    condition     = aws_s3_bucket.cache["default"].force_destroy == false && aws_s3_bucket_public_access_block.cache["default"].block_public_policy
    error_message = "Cache buckets must reject public access and preserve objects on accidental destroy."
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.cache["default"].rule).expiration[0].days == 14 && one(aws_s3_bucket_server_side_encryption_configuration.cache["default"].rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "Caches require default 14-day expiry and S3 encryption."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.cache["default"].policy).Statement[0].Condition.StringLike["s3:prefix"][0] == "fleets/default/trust/trusted/repos/example/project/*" && endswith(jsondecode(aws_iam_role_policy.cache["default"].policy).Statement[1].Resource[0], "/fleets/default/trust/trusted/repos/example/project/*")
    error_message = "List and object access must be limited to the exact fleet/trust/repository scope."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.cache["default"].policy).Statement[2].Condition.StringEquals["s3:if-none-match"] == "*" && jsondecode(aws_s3_bucket_policy.cache["default"].policy).Statement[1].Condition.Null["s3:if-none-match"] == "true"
    error_message = "Both IAM and the bucket must enforce conditional immutable writes."
  }
  assert {
    condition     = local.fleet_runtime_configuration[0].cache.repository == "example/project" && local.fleet_runtime_configuration[0].cache.helper_image == var.container_image
    error_message = "Only enabled fleets receive repository-scoped cache bootstrap settings and the pinned helper image."
  }
}

run "read_only_cache" {
  command = apply
  variables {
    cache_fleets = { default = { repository = "example/project", trust_namespace = "trusted", read_only = true, retention_days = 3 } }
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.cache["default"].policy).Statement) == 2 && local.fleet_runtime_configuration[0].cache.read_only
    error_message = "Read-only caches must have no write grant."
  }
}

run "reject_unknown_fleet" {
  command = plan
  variables {
    cache_fleets = { missing = { repository = "example/project", trust_namespace = "trusted" } }
  }
  expect_failures = [aws_s3_bucket.cache]
}

run "reject_default_org_group" {
  command = plan
  variables {
    github_config_url = "https://github.com/example"
    cache_fleets      = { default = { repository = "example/project", trust_namespace = "trusted" } }
  }
  expect_failures = [aws_s3_bucket.cache]
}

run "reject_external_iam" {
  command = plan
  variables {
    fleets       = { external = { iam_role_arn = "arn:aws:iam::123456789012:role/external", iam_instance_profile_arn = "arn:aws:iam::123456789012:instance-profile/external" } }
    cache_fleets = { external = { repository = "example/project", trust_namespace = "trusted" } }
  }
  expect_failures = [aws_s3_bucket.cache]
}

run "reject_unsafe_scope" {
  command = plan
  variables {
    cache_fleets = { default = { repository = "example/*", trust_namespace = "trusted" } }
  }
  expect_failures = [var.cache_fleets]
}

run "reject_unpinned_helper" {
  command = plan
  variables {
    require_image_digest = false
    container_image      = "example.com/gondola:mutable"
    cache_fleets         = { default = { repository = "example/project", trust_namespace = "trusted" } }
  }
  expect_failures = [aws_s3_bucket.cache]
}

run "separate_fleet_authority" {
  command = apply
  variables {
    fleets = {
      trusted  = { runner_group = "project-trusted" }
      isolated = { runner_group = "other-trusted" }
    }
    cache_fleets = {
      trusted  = { repository = "example/project", trust_namespace = "trusted" }
      isolated = { repository = "example/other", trust_namespace = "trusted" }
    }
  }
  assert {
    condition     = aws_s3_bucket.cache["trusted"].bucket != aws_s3_bucket.cache["isolated"].bucket && jsondecode(aws_iam_role_policy.cache["trusted"].policy).Statement[1].Resource[0] != jsondecode(aws_iam_role_policy.cache["isolated"].policy).Statement[1].Resource[0]
    error_message = "Separate fleets must not share a bucket or object-access scope."
  }
  assert {
    condition     = alltrue([for policy in aws_iam_role_policy.cache : alltrue([for statement in jsondecode(policy.policy).Statement : !contains(statement.Action, "s3:DeleteObject") && !contains(statement.Action, "s3:*")])])
    error_message = "Runner cache policies must never grant delete or blanket S3 permissions."
  }
}
