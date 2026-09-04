# Gondola on AWS

This module installs the Gondola control plane and its EC2 runner fleets in an
existing AWS account. It supports both Terraform and OpenTofu.

Gondola supplies one ephemeral runner for each queued GitHub Actions job. The
runner executes in the customer's VPC and is terminated after the job. Source
code, job data, credentials, logs, and runner instances remain in the customer
account.

The module creates the AWS resources needed to operate Gondola. It does not
contain the Gondola controller software. A Gondola subscription supplies a
signed entitlement, a controller release, and its immutable OCI digest.

## Requirements

- Terraform 1.5 or later, or OpenTofu 1.12 or later
- AWS provider 6.0 or later
- An existing VPC and private subnets with outbound HTTPS access
- A private GitHub App installed for the repositories Gondola will serve
- A digest-pinned Gondola controller image in ECR
- A signed Gondola entitlement stored in AWS Secrets Manager

The default two-controller configuration requires controller subnets in at
least two Availability Zones.

## Usage

```hcl
module "gondola" {
  source  = "gondola-build/gondola/aws"
  version = "~> 0.2"

  name            = "gondola-production"
  vpc_id          = var.vpc_id
  subnet_ids      = var.controller_subnet_ids
  container_image = var.container_image

  github_config_url                 = "https://github.com/example"
  github_app_client_id              = var.github_app_client_id
  github_app_installation_id        = var.github_app_installation_id
  github_app_private_key_secret_arn = var.github_app_private_key_secret_arn

  entitlement_secret_arn = var.entitlement_secret_arn
  entitlement_public_key = var.entitlement_public_key
  entitlement_key_id     = var.entitlement_key_id

  fleets = {
    linux_x64 = {
      scale_set_name = "gondola-linux-x64"
      architecture   = "x64"
      capacity_mode  = "spot-with-on-demand-fallback"
      instance_type  = "m7i.large"
      subnet_ids     = var.runner_subnet_ids
      min_runners    = 0
      max_runners    = 10
    }
  }
}
```

Use an image reference ending in `@sha256:<digest>`. Gondola also requires
digest-pinned runner images by default.

The module uses separate compatibility metadata for each engine and is tested
with Terraform 1.16.1 and OpenTofu 1.12.6. Choose one engine for a state and
keep using it for plans, applies, upgrades, and destroys. Follow OpenTofu's
migration guide before moving an existing Terraform-managed deployment.

See the [installation guide](https://gondola.build/docs/install) for GitHub App
setup, entitlement storage, deployment, and verification.

## What the module creates

- An ECS cluster and one or two Fargate controller tasks
- A DynamoDB table for short-lived leadership and readiness coordination
- CloudWatch logs and optional metrics and alarms
- EC2 launch templates and security groups for each runner fleet
- Narrow controller and runner IAM roles, unless existing runner roles are used

The controllers and runners initiate outbound connections. The module does not
create a public listener or inbound product endpoint.

## Security

The GitHub App private key and signed entitlement are read from Secrets Manager
or Systems Manager Parameter Store. Their values do not enter Terraform state.
The controller receives `iam:PassRole` only for runner roles configured in the
module.

Report a suspected vulnerability privately to
[support@gondola.build](mailto:support@gondola.build). Do not open a public
issue for sensitive reports.

## License

The module is distributed under the terms in [LICENSE](LICENSE). A public
repository does not grant a license beyond those terms or an applicable Gondola
subscription agreement.
