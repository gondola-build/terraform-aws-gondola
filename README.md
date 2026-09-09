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

## Optional entitlement renewal

The upcoming module 0.3.0 and its matching signed controller release support
`entitlement_renewal_enabled = true`. Existing installations remain manual.
Set `renewal_activation_secret_arn` to a separate raw Secrets Manager secret
containing the activation key, and configure `alarm_action_arns` for renewal
failure notifications. This opt-in requires entitlement enforcement, the
module's DynamoDB coordination, and a raw unversioned entitlement secret in
the same AWS account and region.

The module adds a separate small Fargate helper, a six-hour EventBridge
Scheduler timer, scoped IAM and failed/missing-check alarms. The helper renews
within seven days of expiry, verifies against operator-pinned signing keys,
conditionally promotes a later token for the same license and organization,
then rolls the existing service and observes readiness for that token. It
receives no GitHub key and cannot register task definitions or pass roles.
AWS task, scheduling, log and secret charges remain customer costs.

Allow HTTPS egress to `https://gondola.build/api/entitlements/activate` and required
regional AWS APIs. The helper does not add vendor access to the scheduling
path. Immediate mid-period plan changes still require a manual refresh and
rollout. `entitlement_trusted_keys` permits overlap of up to four explicitly
pinned verification keys; it does not trust keys returned by activation.
Disabling the helper returns future renewal to the manual procedure.

Use this feature only with the matching released controller/module pair from
the verified release manifest. Older controller images do not implement it.

## Optional S3 caching

The cache feature requires the matching module 0.4.0/controller release pair.
`cache_fleets` creates one private, encrypted S3 bucket for each explicitly
enabled fleet, with scoped runner IAM and lifecycle expiry (14 days by default).
No cache resources or permissions are added when the map is empty.

Each entry names its `repository`, `trust_namespace` and optional `read_only`
policy. Set `helper_image` to the public multiarchitecture controller reference
from that same verified release manifest. Controller images mirrored to private
ECR do not make runner-host pulls automatically authenticated.

Restrict the fleet's GitHub runner group to the configured repository and trusted
workflows. The fleet IAM role and GitHub scheduling policy provide isolation;
the repository string alone is not an authorization boundary. Never share a
writable cache between untrusted pull requests and privileged builds.

Caching uses explicit paired restore/save steps or the shipped CLI. It does not
redirect `actions/cache`, setup-action caches, or BuildKit `type=gha`. Obtain the
reviewed composite action and customer workflow guide from the signed public
release bundle and commit the action into the customer repository. No access to
Gondola's private product-source repository is required.

S3 storage, transfer and request charges remain customer costs. Expiry is
asynchronous and does not enforce a byte or spending quota. Cache buckets use
`force_destroy=false`; drain jobs and explicitly empty a populated bucket before
removing it. Existing buckets and external runner IAM profiles are unsupported
by this first integration.

## Security

The GitHub App private key and signed entitlement are read from Secrets Manager
or Systems Manager Parameter Store. Their values do not enter Terraform state.
The controller receives `iam:PassRole` only for runner roles configured in the
module.

Report a suspected vulnerability privately to
[support@gondola.build](mailto:support@gondola.build). Do not open a public
issue for sensitive reports.

## License

The infrastructure module in this repository is licensed under the
[Apache License 2.0](LICENSE). The Gondola controller, release artifacts, and
commercial service are separate products and are not licensed by this module's
license.
