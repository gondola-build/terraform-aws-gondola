provider "aws" {
  region = var.aws_region
}

module "gondola" {
  source = "../.."

  name            = "gondola-production"
  vpc_id          = var.vpc_id
  subnet_ids      = var.controller_subnet_ids
  container_image = var.container_image

  github_config_url                 = var.github_config_url
  github_app_client_id              = var.github_app_client_id
  github_app_installation_id        = var.github_app_installation_id
  github_app_private_key_secret_arn = var.github_app_private_key_secret_arn

  entitlement_secret_arn = var.entitlement_secret_arn
  entitlement_public_key = var.entitlement_public_key
  entitlement_key_id     = var.entitlement_key_id

  desired_count               = 2
  require_image_digest        = true
  require_runner_image_digest = true

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

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
