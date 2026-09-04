# Basic example

This example installs Gondola in an existing VPC with one Linux x64 runner
fleet. It uses the module from this checkout so Terraform and OpenTofu can
validate the example before a release is published.

Supply the required variables through your normal reviewed configuration, then
run either `terraform init` and `terraform plan` or `tofu init` and `tofu plan`.
Keep using the same engine for that state.
