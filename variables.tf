variable "name" {
  description = "Name prefix for Gondola resources."
  type        = string
  default     = "gondola"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "vpc_id" {
  description = "VPC in which the Gondola control plane runs."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs used by the ECS service. They must have outbound access to GitHub and AWS APIs; desired_count = 2 requires at least two Availability Zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet ID is required."
  }
}

variable "container_image" {
  description = "Immutable Gondola OCI image reference. A digest-pinned reference is recommended."
  type        = string

  validation {
    condition     = length(trimspace(var.container_image)) > 0
    error_message = "container_image cannot be empty."
  }
}

variable "container_registry_credentials_secret_arn" {
  description = "Optional Secrets Manager ARN containing username/password JSON for a private non-ECR controller image."
  type        = string
  default     = null
  nullable    = true
}

variable "github_config_url" {
  description = "Full GitHub repository, organization, or enterprise URL where the runner scale set is registered."
  type        = string

  validation {
    condition     = can(regex("^https://", var.github_config_url))
    error_message = "github_config_url must be a full HTTPS URL."
  }
}

variable "scale_set_name" {
  description = "Runner scale-set name and default workflow label."
  type        = string
  default     = "gondola"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", var.scale_set_name))
    error_message = "scale_set_name must contain 1-64 letters, numbers, periods, underscores, or hyphens."
  }
}

variable "runner_group" {
  description = "Existing GitHub runner group. The default group is used when omitted."
  type        = string
  default     = "default"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$", var.runner_group))
    error_message = "runner_group must contain 1-64 letters, numbers, spaces, periods, underscores, or hyphens."
  }
}

variable "runner_labels" {
  description = "Labels assigned to the scale set. The scale-set name is used when empty."
  type        = list(string)
  default     = []
}

variable "github_token_secret_arn" {
  description = "Secrets Manager or SSM Parameter Store ARN containing a repository-scoped GitHub token. Prefer a GitHub App for production."
  type        = string
  default     = null
  nullable    = true
}

variable "github_app_client_id" {
  description = "GitHub App client ID."
  type        = string
  default     = null
  nullable    = true
}

variable "github_app_installation_id" {
  description = "GitHub App installation ID."
  type        = number
  default     = null
  nullable    = true

  validation {
    condition     = var.github_app_installation_id == null ? true : (var.github_app_installation_id > 0 && floor(var.github_app_installation_id) == var.github_app_installation_id)
    error_message = "github_app_installation_id must be a positive integer when set."
  }
}

variable "github_app_private_key_secret_arn" {
  description = "Secrets Manager or SSM Parameter Store ARN containing the GitHub App PEM private key."
  type        = string
  default     = null
  nullable    = true
}

variable "entitlement_required" {
  description = "Require a valid Gondola entitlement before the controller starts. Non-release builds may disable this only for Gondola development and isolated tests; official release binaries always require an entitlement."
  type        = bool
  default     = true
}

variable "entitlement_secret_arn" {
  description = "Secrets Manager or SSM Parameter Store ARN containing the signed Gondola entitlement returned after subscription activation."
  type        = string
  default     = null
  nullable    = true
}

variable "entitlement_public_key" {
  description = "Base64-encoded Ed25519 public key published for the entitlement signing key. This value is not secret."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.entitlement_public_key == null ? true : can(regex("^[A-Za-z0-9+/_-]{42,44}={0,2}$", var.entitlement_public_key))
    error_message = "entitlement_public_key must be a base64-encoded Ed25519 public key when set."
  }
}

variable "entitlement_key_id" {
  description = "Identifier for the Gondola entitlement signing key. It must match the signed entitlement."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.entitlement_key_id == null ? true : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", var.entitlement_key_id))
    error_message = "entitlement_key_id must contain 1-64 letters, numbers, periods, underscores, or hyphens."
  }
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of control-plane tasks. Two provides active/passive failover through the DynamoDB coordination lease; one is the lower-cost option."
  type        = number
  default     = 2

  validation {
    condition     = contains([1, 2], var.desired_count)
    error_message = "desired_count must be 1 or 2."
  }
}

variable "adopt_existing_scale_sets" {
  description = "Permit a one-time reviewed adoption of same-named GitHub runner scale sets that lack Gondola's deployment ownership label. Disable again after migration."
  type        = bool
  default     = false
}

variable "deployment_generation_nonce" {
  description = "Operator-controlled generation value. Change it when a secret rotates at the same ARN so ECS starts tasks that read the new version."
  type        = string
  default     = ""

  validation {
    condition     = var.deployment_generation_nonce == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", var.deployment_generation_nonce))
    error_message = "deployment_generation_nonce must be empty or 1-128 letters, numbers, periods, underscores, colons, or hyphens."
  }
}

variable "coordination_deletion_protection" {
  description = "Protect the DynamoDB coordination table from accidental deletion. The table contains only ephemeral lease state."
  type        = bool
  default     = false
}

variable "assign_public_ip" {
  description = "Assign a public IP to the control-plane task. Private subnets with controlled egress are recommended."
  type        = bool
  default     = false
}

variable "environment" {
  description = "Non-secret environment variables passed to the controller."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Map of environment variable names to Secrets Manager or SSM Parameter Store valueFrom references."
  type        = map(string)
  default     = {}
}

variable "secret_arns" {
  description = "Secret or parameter ARNs the ECS execution role may read."
  type        = set(string)
  default     = []
}

variable "secret_kms_key_arns" {
  description = "Customer-managed KMS key ARNs needed to decrypt configured secrets."
  type        = set(string)
  default     = []
}

variable "task_policy_arns" {
  description = "Additional IAM policies attached to the controller task role."
  type        = set(string)
  default     = []
}

variable "egress_ipv4_cidrs" {
  description = "IPv4 CIDRs the controller may reach. Restrict this when using an egress proxy or firewall."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "runner_subnet_ids" {
  description = "Subnets for ephemeral runner instances. Defaults to the control-plane subnets."
  type        = list(string)
  default     = null
  nullable    = true
}

variable "runner_security_group_ids" {
  description = "Existing security groups for runner instances. Gondola creates an outbound-only group when empty."
  type        = list(string)
  default     = []
}

variable "runner_egress_ipv4_cidrs" {
  description = "IPv4 CIDRs reachable by the Gondola-created runner security group."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "runner_ami_id" {
  description = "ECS-optimized Amazon Linux 2023 AMI ID. The current regional SSM parameter is used when null."
  type        = string
  default     = null
  nullable    = true
}

variable "runner_instance_type" {
  description = "EC2 instance type for the initial runner fleet."
  type        = string
  default     = "m7i.large"
}

variable "runner_capacity_mode" {
  description = "Capacity mode for the legacy single fleet: on-demand, spot, or spot-with-on-demand-fallback."
  type        = string
  default     = "on-demand"

  validation {
    condition     = contains(["on-demand", "spot", "spot-with-on-demand-fallback"], var.runner_capacity_mode)
    error_message = "runner_capacity_mode must be on-demand, spot, or spot-with-on-demand-fallback."
  }
}

variable "runner_container_image" {
  description = "GitHub Actions runner container image launched on each EC2 instance. The default is an audited multi-architecture digest; update deliberately as part of a reviewed release."
  type        = string
  default     = "ghcr.io/actions/actions-runner@sha256:e5496277be5d09bc968b3d64911b74e219ac4a3f2edce956a3ecf9271bea1ef4"
}

variable "runner_root_volume_size" {
  description = "Encrypted runner root-volume size in GiB."
  type        = number
  default     = 50

  validation {
    condition     = var.runner_root_volume_size >= 30 && floor(var.runner_root_volume_size) == var.runner_root_volume_size
    error_message = "runner_root_volume_size must be an integer of at least 30 GiB."
  }
}

variable "runner_policy_arns" {
  description = "Additional policies attached to the ephemeral runner instance role. OIDC from workflows is preferred."
  type        = set(string)
  default     = []
}

variable "min_runners" {
  description = "Minimum number of connected idle runners. Zero gives scale-to-zero behavior."
  type        = number
  default     = 0

  validation {
    condition     = var.min_runners >= 0 && floor(var.min_runners) == var.min_runners
    error_message = "min_runners must be a non-negative integer."
  }
}

variable "max_runners" {
  description = "Maximum concurrent runners."
  type        = number
  default     = 10

  validation {
    condition     = var.max_runners > 0 && var.max_runners <= 1000 && floor(var.max_runners) == var.max_runners
    error_message = "max_runners must be an integer between 1 and 1000."
  }
}

variable "max_runner_lifetime" {
  description = "Maximum runner lifetime before forced termination."
  type        = string
  default     = "6h"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period."
  type        = number
  default     = 30
}

variable "fleets" {
  description = <<-EOT
    Named runner fleets. When empty, the legacy runner_* and scale_set_* variables
    define one backward-compatible fleet named "default". Each fleet can select
    its architecture, capacity mode, network, AMI, instance type, IAM role, and tags.
  EOT
  type = map(object({
    scale_set_name           = optional(string)
    runner_group             = optional(string, "default")
    labels                   = optional(list(string), [])
    min_runners              = optional(number, 0)
    max_runners              = optional(number, 10)
    architecture             = optional(string, "x64")
    capacity_mode            = optional(string, "spot-with-on-demand-fallback")
    vpc_id                   = optional(string)
    subnet_ids               = optional(list(string))
    security_group_ids       = optional(list(string), [])
    egress_ipv4_cidrs        = optional(list(string), ["0.0.0.0/0"])
    ami_id                   = optional(string)
    instance_type            = optional(string)
    runner_container_image   = optional(string)
    root_volume_size         = optional(number)
    policy_arns              = optional(set(string), [])
    iam_instance_profile_arn = optional(string)
    iam_role_arn             = optional(string)
    max_runner_lifetime      = optional(string, "6h")
    tags                     = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, fleet in var.fleets :
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", name)) &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", coalesce(fleet.scale_set_name, name))) &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$", fleet.runner_group)) &&
      contains(["x64", "arm64"], fleet.architecture) &&
      contains(["on-demand", "spot", "spot-with-on-demand-fallback"], fleet.capacity_mode) &&
      fleet.min_runners >= 0 &&
      floor(fleet.min_runners) == fleet.min_runners &&
      fleet.max_runners > 0 &&
      fleet.max_runners <= 1000 &&
      floor(fleet.max_runners) == fleet.max_runners &&
      fleet.min_runners <= fleet.max_runners &&
      (fleet.root_volume_size == null ? true : (fleet.root_volume_size >= 30 && floor(fleet.root_volume_size) == fleet.root_volume_size)) &&
      ((fleet.iam_instance_profile_arn == null) == (fleet.iam_role_arn == null))
    ])
    error_message = "Each fleet must have valid names, x64 or arm64 architecture, a supported capacity mode, valid runner limits and volume size, and both or neither external IAM profile/role ARNs."
  }
}

variable "metrics_enabled" {
  description = "Publish per-fleet custom metrics to CloudWatch. Disabled by default because custom metrics incur a recurring AWS charge."
  type        = bool
  default     = false
}

variable "alarms_enabled" {
  description = "Create per-fleet CloudWatch alarms for operational readiness and runner lifecycle errors. Requires metrics_enabled."
  type        = bool
  default     = false
}

variable "alarm_action_arns" {
  description = "SNS topic or other action ARNs invoked by Gondola CloudWatch alarms. Empty creates visible alarms without notifications."
  type        = set(string)
  default     = []
}

variable "metrics_namespace" {
  description = "Custom CloudWatch namespace used when metrics_enabled is true."
  type        = string
  default     = "Gondola"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/#-]{0,254}$", var.metrics_namespace)) && !startswith(var.metrics_namespace, "AWS/")
    error_message = "metrics_namespace must be a valid custom namespace and cannot begin with AWS/."
  }
}

variable "container_insights_enabled" {
  description = "Enable ECS Container Insights. Disabled by default to avoid its additional CloudWatch ingestion and metric charges."
  type        = bool
  default     = false
}

variable "require_image_digest" {
  description = "Reject controller image references that are not pinned by sha256 digest. Disable only for local development."
  type        = bool
  default     = true
}

variable "require_runner_image_digest" {
  description = "Reject runner image references that are not pinned by sha256 digest. Disable only for local development."
  type        = bool
  default     = true
}

variable "deployment_circuit_breaker_rollback" {
  description = "Automatically roll the ECS service back when a new controller task cannot become healthy."
  type        = bool
  default     = true
}

variable "wait_for_steady_state" {
  description = "Wait for the singleton controller service to become stable during Terraform apply."
  type        = bool
  default     = true
}

variable "controller_stop_timeout_seconds" {
  description = "Grace period for the controller to close GitHub sessions and flush metrics during replacement."
  type        = number
  default     = 30

  validation {
    condition     = var.controller_stop_timeout_seconds >= 20 && var.controller_stop_timeout_seconds <= 120 && floor(var.controller_stop_timeout_seconds) == var.controller_stop_timeout_seconds
    error_message = "controller_stop_timeout_seconds must be an integer from 20 through 120."
  }
}

variable "controller_health_start_period_seconds" {
  description = "Startup grace period before ECS readiness failures count against a new controller task."
  type        = number
  default     = 30

  validation {
    condition     = var.controller_health_start_period_seconds >= 0 && var.controller_health_start_period_seconds <= 300 && floor(var.controller_health_start_period_seconds) == var.controller_health_start_period_seconds
    error_message = "controller_health_start_period_seconds must be an integer from 0 through 300."
  }
}

variable "tags" {
  description = "Tags applied to Gondola resources."
  type        = map(string)
  default     = {}
}
