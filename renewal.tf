variable "entitlement_trusted_keys" {
  description = "Additional operator-pinned Ed25519 public keys by key ID for overlapping signer rotation; at most four total including the legacy key. Public configuration only."
  type        = map(string)
  default     = {}
  validation {
    condition     = length(var.entitlement_trusted_keys) <= 4 && alltrue([for id, key in var.entitlement_trusted_keys : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", id)) && can(regex("^[A-Za-z0-9+/_-]{42,44}={0,2}$", key))])
    error_message = "entitlement_trusted_keys must contain at most four valid key IDs and base64 Ed25519 public keys."
  }
}

variable "entitlement_renewal_enabled" {
  description = "Explicitly opt into customer-operated renewal every six hours. Requires a renewal-capable Gondola image, raw Secrets Manager entitlement and activation secrets, and vendor API egress from the separate helper task."
  type        = bool
  default     = false
}

variable "renewal_activation_secret_arn" {
  description = "Existing Secrets Manager ARN holding the raw activation key. Populate outside Terraform; never supply the value to this module. Used only by the optional renewal helper."
  type        = string
  default     = null
}

variable "renewal_activation_kms_key_arn" {
  description = "Customer-managed KMS key for the activation secret, if any. The renewal helper receives decrypt access limited to this secret's encryption context."
  type        = string
  default     = null
}

variable "renewal_entitlement_kms_key_arn" {
  description = "Customer-managed KMS key for the entitlement secret, if any. The renewal helper receives decrypt and generate-data-key access limited to this secret's encryption context."
  type        = string
  default     = null
}

locals {
  renewal_service_arn   = "arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.this.name}/${var.name}"
  renewal_secret_prefix = "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:"
  renewal_kms_secrets = var.entitlement_renewal_enabled ? {
    for name, value in {
      activation  = { key = var.renewal_activation_kms_key_arn, secret = var.renewal_activation_secret_arn, actions = ["kms:Decrypt"] }
      entitlement = { key = var.renewal_entitlement_kms_key_arn, secret = var.entitlement_secret_arn, actions = ["kms:Decrypt", "kms:GenerateDataKey"] }
    } : name => value if value.key != null
  } : {}
}

resource "aws_iam_role" "renewal" {
  count              = var.entitlement_renewal_enabled ? 1 : 0
  name_prefix        = "${local.iam_role_name}-renewal-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "renewal" {
  count = var.entitlement_renewal_enabled ? 1 : 0
  name  = "renew-only-this-entitlement"
  role  = aws_iam_role.renewal[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [var.renewal_activation_secret_arn, var.entitlement_secret_arn] },
      { Effect = "Allow", Action = ["secretsmanager:PutSecretValue", "secretsmanager:UpdateSecretVersionStage"], Resource = [var.entitlement_secret_arn] },
      { Effect = "Allow", Action = ["ecs:DescribeServices", "ecs:UpdateService"], Resource = [local.renewal_service_arn] },
      # AWS does not support resource-level IAM scope for DescribeTaskDefinition.
      # The helper validates the service's family/account/region before reading.
      { Effect = "Allow", Action = ["ecs:DescribeTaskDefinition"], Resource = ["*"] },
      { Effect = "Allow", Action = ["dynamodb:GetItem"], Resource = [aws_dynamodb_table.coordination.arn], Condition = { "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = [var.name] } } }
      ], [for value in values(local.renewal_kms_secrets) : {
        Effect = "Allow", Action = value.actions, Resource = [value.key], Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"
            "kms:EncryptionContext:SecretARN" = value.secret
          }
        }
    }])
  })
}

# Separate execution and task roles: the helper never receives GitHub or runner
# permissions, and it reads activation through the SDK without env injection.
resource "aws_iam_role" "renewal_execution" {
  count              = var.entitlement_renewal_enabled ? 1 : 0
  name_prefix        = "${local.iam_role_name}-renew-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "renewal_execution" {
  count      = var.entitlement_renewal_enabled ? 1 : 0
  role       = aws_iam_role.renewal_execution[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "renewal_registry" {
  count = var.entitlement_renewal_enabled && var.container_registry_credentials_secret_arn != null ? 1 : 0
  name  = "read-renewal-image-credentials"
  role  = aws_iam_role.renewal_execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [var.container_registry_credentials_secret_arn] }
      ], length(var.secret_kms_key_arns) == 0 ? [] : [{
        Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.secret_kms_key_arns,
        Condition = { StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"
          "kms:EncryptionContext:SecretARN" = var.container_registry_credentials_secret_arn
        } }
    }])
  })
}

resource "aws_ecs_task_definition" "renewal" {
  count                    = var.entitlement_renewal_enabled ? 1 : 0
  family                   = "${var.name}-renewal"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.renewal_execution[0].arn
  task_role_arn            = aws_iam_role.renewal[0].arn
  container_definitions = jsonencode([merge({
    name                   = "renewal"
    image                  = var.container_image
    essential              = true
    readonlyRootFilesystem = true
    command                = ["renew-entitlement"]
    environment = [for key, value in {
      GONDOLA_RENEWAL_ENABLED                = "true"
      GONDOLA_RENEWAL_CLUSTER_ARN            = aws_ecs_cluster.this.arn
      GONDOLA_RENEWAL_SERVICE_ARN            = local.renewal_service_arn
      GONDOLA_RENEWAL_TASK_FAMILY            = var.name
      GONDOLA_RENEWAL_DEPLOYMENT_ID          = var.name
      GONDOLA_RENEWAL_COORDINATION_TABLE_ARN = aws_dynamodb_table.coordination.arn
      GONDOLA_RENEWAL_ACTIVATION_SECRET_ARN  = var.renewal_activation_secret_arn
      GONDOLA_RENEWAL_ENTITLEMENT_SECRET_ARN = var.entitlement_secret_arn
    } : { name = key, value = value }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "renewal"
      }
    }
    linuxParameters = { initProcessEnabled = true }
    }, var.container_registry_credentials_secret_arn == null ? {} : {
    repositoryCredentials = { credentialsParameter = var.container_registry_credentials_secret_arn }
  })])
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  lifecycle {
    precondition {
      condition     = var.entitlement_required && var.entitlement_secret_arn != null && var.renewal_activation_secret_arn != null && var.entitlement_secret_arn != var.renewal_activation_secret_arn
      error_message = "Optional renewal requires entitlement enforcement and separate existing entitlement and activation secrets."
    }
    precondition {
      condition = alltrue([for value in [var.entitlement_secret_arn, var.renewal_activation_secret_arn] : value == null ? false : (
        startswith(value, local.renewal_secret_prefix) && can(regex(":secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", value))
      )])
      error_message = "Optional renewal requires complete raw Secrets Manager secret ARNs in the controller account and region, without JSON-key or version selectors."
    }
  }
  tags = local.tags
}

resource "aws_scheduler_schedule_group" "renewal" {
  count = var.entitlement_renewal_enabled ? 1 : 0
  name  = "${var.name}-renewal"
  tags  = local.tags
}

resource "aws_iam_role" "renewal_schedule" {
  count       = var.entitlement_renewal_enabled ? 1 : 0
  name_prefix = "${local.iam_role_name}-renew-timer-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole", Principal = { Service = "scheduler.amazonaws.com" },
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }, ArnEquals = { "aws:SourceArn" = aws_scheduler_schedule_group.renewal[0].arn } }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "renewal_schedule" {
  count = var.entitlement_renewal_enabled ? 1 : 0
  name  = "run-only-renewal-task"
  role  = aws_iam_role.renewal_schedule[0].id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [
      { Effect = "Allow", Action = ["ecs:RunTask"], Resource = [aws_ecs_task_definition.renewal[0].arn], Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } } },
      { Effect = "Allow", Action = ["iam:PassRole"], Resource = [aws_iam_role.renewal[0].arn, aws_iam_role.renewal_execution[0].arn], Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } } }
    ]
  })
}

resource "aws_scheduler_schedule" "renewal" {
  count               = var.entitlement_renewal_enabled ? 1 : 0
  name                = "${var.name}-renewal"
  group_name          = aws_scheduler_schedule_group.renewal[0].name
  schedule_expression = "rate(6 hours)"
  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 15
  }
  target {
    arn      = aws_ecs_cluster.this.arn
    role_arn = aws_iam_role.renewal_schedule[0].arn
    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.renewal[0].arn
      launch_type         = "FARGATE"
      task_count          = 1
      network_configuration {
        assign_public_ip = var.assign_public_ip
        security_groups  = [aws_security_group.control_plane.id]
        subnets          = var.subnet_ids
      }
    }
  }
  depends_on = [aws_ecs_service.this, aws_iam_role_policy.renewal_schedule, aws_iam_role_policy.renewal, aws_iam_role_policy_attachment.renewal_execution, aws_iam_role_policy.renewal_registry]
}

resource "aws_cloudwatch_log_metric_filter" "renewal" {
  for_each       = var.entitlement_renewal_enabled ? toset(["completed", "failed"]) : toset([])
  name           = "${var.name}-renewal-${each.key}"
  log_group_name = aws_cloudwatch_log_group.this.name
  pattern        = "{ $.msg = \"entitlement renewal ${each.key}\" }"
  metric_transformation {
    name      = "${var.name}-renewal-${each.key}"
    namespace = "Gondola/Renewal"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "renewal_failure" {
  count               = var.entitlement_renewal_enabled ? 1 : 0
  alarm_name          = "${var.name}-renewal-failed"
  alarm_description   = "Customer entitlement renewal failed. Inspect renewal task logs; no coverage extension is assumed."
  namespace           = "Gondola/Renewal"
  metric_name         = aws_cloudwatch_log_metric_filter.renewal["failed"].metric_transformation[0].name
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = tolist(var.alarm_action_arns)
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "renewal_missing" {
  count               = var.entitlement_renewal_enabled ? 1 : 0
  alarm_name          = "${var.name}-renewal-missing"
  alarm_description   = "No successful customer renewal check in 12 hours. Check Scheduler, ECS startup, network access, and renewal task logs."
  namespace           = "Gondola/Renewal"
  metric_name         = aws_cloudwatch_log_metric_filter.renewal["completed"].metric_transformation[0].name
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 1
  period              = 43200
  statistic           = "Sum"
  treat_missing_data  = "breaching"
  alarm_actions       = tolist(var.alarm_action_arns)
  tags                = local.tags
}

output "renewal_schedule_arn" {
  description = "Optional customer-operated renewal schedule ARN, or null for manual renewal."
  value       = var.entitlement_renewal_enabled ? aws_scheduler_schedule.renewal[0].arn : null
}

output "renewal_task_definition_arn" {
  description = "Optional one-shot renewal task definition ARN for customer acceptance or recovery."
  value       = var.entitlement_renewal_enabled ? aws_ecs_task_definition.renewal[0].arn : null
}

output "renewal_alarm_arns" {
  description = "Customer CloudWatch alarms for failed or missing renewal checks. Configure alarm_action_arns for notifications."
  value = var.entitlement_renewal_enabled ? {
    failed  = aws_cloudwatch_metric_alarm.renewal_failure[0].arn
    missing = aws_cloudwatch_metric_alarm.renewal_missing[0].arn
  } : {}
}
