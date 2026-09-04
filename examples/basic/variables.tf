variable "aws_region" {
  description = "AWS region for the Gondola control plane."
  type        = string
}

variable "vpc_id" {
  description = "ID of the existing VPC for the Gondola control plane."
  type        = string
}

variable "controller_subnet_ids" {
  description = "Private subnet IDs for the Gondola controllers. Provide subnets in at least two Availability Zones."
  type        = list(string)
}

variable "runner_subnet_ids" {
  description = "Subnet IDs in which Gondola may launch ephemeral runners."
  type        = list(string)
}

variable "container_image" {
  description = "Digest-pinned Gondola controller image in the customer's ECR registry."
  type        = string
}

variable "github_config_url" {
  description = "GitHub organization or repository URL served by this installation."
  type        = string
}

variable "github_app_client_id" {
  description = "Client ID of the GitHub App installed for Gondola."
  type        = string
}

variable "github_app_installation_id" {
  description = "Installation ID of the GitHub App installed for Gondola."
  type        = number
}

variable "github_app_private_key_secret_arn" {
  description = "Secrets Manager ARN containing the GitHub App private key."
  type        = string
}

variable "entitlement_secret_arn" {
  description = "Secrets Manager ARN containing the signed Gondola entitlement."
  type        = string
}

variable "entitlement_public_key" {
  description = "Public key used to verify the signed Gondola entitlement."
  type        = string
}

variable "entitlement_key_id" {
  description = "Identifier of the public key used to sign the Gondola entitlement."
  type        = string
}
