output "cluster_arn" {
  description = "ARN of the Gondola ECS cluster."
  value       = module.gondola.cluster_arn
}

output "service_name" {
  description = "Name of the Gondola ECS service."
  value       = module.gondola.service_name
}

output "fleet_scale_set_names" {
  description = "GitHub Actions runner scale-set name for each configured fleet."
  value       = module.gondola.fleet_scale_set_names
}

output "runner_launch_template_ids" {
  description = "EC2 launch-template ID for each configured fleet."
  value       = module.gondola.runner_launch_template_ids
}
