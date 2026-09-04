output "cluster_arn" {
  description = "ARN of the Gondola ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "Name of the Gondola ECS service."
  value       = aws_ecs_service.this.name
}

output "desired_count" {
  description = "Configured number of active/passive controller tasks."
  value       = var.desired_count
}

output "coordination_table_name" {
  description = "DynamoDB table used for controller leadership and readiness coordination."
  value       = aws_dynamodb_table.coordination.name
}

output "deployment_generation" {
  description = "Immutable hash fencing the currently configured controller generation."
  value       = local.controller_generation
}

output "security_group_id" {
  description = "Security group used by the control-plane tasks."
  value       = aws_security_group.control_plane.id
}

output "task_role_arn" {
  description = "IAM role assumed by the Gondola controller."
  value       = aws_iam_role.task.arn
}

output "runner_role_arn" {
  description = "IAM role for the compatibility single fleet, or null when multiple fleets are configured."
  value       = length(local.fleets) == 1 ? one(values(local.runner_role_arns)) : null
}

output "runner_launch_template_id" {
  description = "Launch template for the compatibility single fleet, or null when multiple fleets are configured."
  value       = length(local.fleets) == 1 ? one([for template in values(aws_launch_template.runner) : template.id]) : null
}

output "runner_security_group_ids" {
  description = "Security groups for the compatibility single fleet, or an empty list when multiple fleets are configured."
  value       = length(local.fleets) == 1 ? one(values(local.runner_security_group_ids)) : []
}

output "fleet_scale_set_names" {
  description = "GitHub Actions runner scale-set name by fleet."
  value       = { for name, fleet in local.fleets : name => fleet.scale_set_name }
}

output "runner_role_arns" {
  description = "IAM role ARN by fleet."
  value       = local.runner_role_arns
}

output "runner_launch_template_ids" {
  description = "EC2 launch-template ID by fleet."
  value       = { for name, template in aws_launch_template.runner : name => template.id }
}

output "runner_security_group_ids_by_fleet" {
  description = "Runner security-group IDs by fleet."
  value       = local.runner_security_group_ids
}

output "metrics_namespace" {
  description = "CloudWatch custom metrics namespace; null when custom metrics are disabled."
  value       = var.metrics_enabled ? var.metrics_namespace : null
}

output "execution_role_arn" {
  description = "IAM role used by ECS to start Gondola tasks."
  value       = aws_iam_role.execution.arn
}

output "log_group_name" {
  description = "CloudWatch log group containing controller logs."
  value       = aws_cloudwatch_log_group.this.name
}

output "alarm_arns" {
  description = "CloudWatch alarm ARNs keyed by fleet and condition; empty when alarms are disabled."
  value = merge(
    { for name, alarm in aws_cloudwatch_metric_alarm.fleet_not_ready : "${name}:FleetReady" => alarm.arn },
    { for name, alarm in aws_cloudwatch_metric_alarm.runner_errors : name => alarm.arn }
  )
}
