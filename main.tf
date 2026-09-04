data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_subnet" "control_plane" {
  # Subnet IDs are commonly outputs of resources created in the calling root
  # module. Key instances by their known list positions so Terraform can plan
  # the data reads even when the ID values are not known until apply.
  for_each = { for index, subnet_id in var.subnet_ids : tostring(index) => subnet_id }
  id       = each.value
}

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

locals {
  # Retain the original variables as a compatibility surface. Existing users
  # migrate state to the "default" fleet first, then opt into var.fleets.
  legacy_fleets = {
    default = {
      scale_set_name           = var.scale_set_name
      runner_group             = var.runner_group
      labels                   = var.runner_labels
      min_runners              = var.min_runners
      max_runners              = var.max_runners
      architecture             = "x64"
      capacity_mode            = var.runner_capacity_mode
      vpc_id                   = var.vpc_id
      subnet_ids               = var.runner_subnet_ids == null ? var.subnet_ids : var.runner_subnet_ids
      security_group_ids       = var.runner_security_group_ids
      egress_ipv4_cidrs        = var.runner_egress_ipv4_cidrs
      ami_id                   = var.runner_ami_id
      instance_type            = var.runner_instance_type
      runner_container_image   = var.runner_container_image
      root_volume_size         = var.runner_root_volume_size
      policy_arns              = var.runner_policy_arns
      iam_instance_profile_arn = null
      iam_role_arn             = null
      max_runner_lifetime      = var.max_runner_lifetime
      tags                     = {}
    }
  }

  configured_fleets = {
    for name, fleet in var.fleets : name => {
      scale_set_name           = coalesce(fleet.scale_set_name, name)
      runner_group             = fleet.runner_group
      labels                   = fleet.labels
      min_runners              = fleet.min_runners
      max_runners              = fleet.max_runners
      architecture             = fleet.architecture
      capacity_mode            = fleet.capacity_mode
      vpc_id                   = fleet.vpc_id == null ? var.vpc_id : fleet.vpc_id
      subnet_ids               = fleet.subnet_ids == null ? (var.runner_subnet_ids == null ? var.subnet_ids : var.runner_subnet_ids) : fleet.subnet_ids
      security_group_ids       = fleet.security_group_ids
      egress_ipv4_cidrs        = fleet.egress_ipv4_cidrs
      ami_id                   = fleet.ami_id
      instance_type            = fleet.instance_type == null ? (fleet.architecture == "arm64" ? "m7g.large" : var.runner_instance_type) : fleet.instance_type
      runner_container_image   = fleet.runner_container_image == null ? var.runner_container_image : fleet.runner_container_image
      root_volume_size         = fleet.root_volume_size == null ? var.runner_root_volume_size : fleet.root_volume_size
      policy_arns              = fleet.policy_arns
      iam_instance_profile_arn = fleet.iam_instance_profile_arn
      iam_role_arn             = fleet.iam_role_arn
      max_runner_lifetime      = fleet.max_runner_lifetime
      tags                     = fleet.tags
    }
  }

  legacy_mode = length(var.fleets) == 0
  fleets      = local.legacy_mode ? local.legacy_fleets : local.configured_fleets

  fleet_deployment_ids = {
    for name in keys(local.fleets) :
    name => (local.legacy_mode ? var.name : "${var.name}:${name}")
  }

  # IAM name_prefix receives a provider-generated suffix. Keep the configured
  # portion intentionally short and put full identities in tags.
  iam_role_name = substr(var.name, 0, 27)

  tags = merge(var.tags, {
    "gondola:component" = "control-plane"
    "gondola:managed"   = "true"
  })

  fleet_tags = {
    for name, fleet in local.fleets : name => merge(var.tags, fleet.tags, {
      "gondola:component"     = "runner"
      "gondola:managed"       = "true"
      "gondola:deployment"    = local.fleet_deployment_ids[name]
      "gondola:fleet"         = name
      "gondola:architecture"  = fleet.architecture
      "gondola:capacity-mode" = fleet.capacity_mode
    })
  }

  managed_iam_fleets = {
    for name, fleet in local.fleets : name => fleet
    if fleet.iam_instance_profile_arn == null
  }

  runner_egress_rules = {
    for rule in flatten([
      for name, fleet in local.fleets : [
        for cidr in toset(fleet.egress_ipv4_cidrs) : {
          key        = local.legacy_mode ? cidr : "${name}-${sha1(cidr)}"
          fleet_name = name
          cidr       = cidr
        }
      ] if length(fleet.security_group_ids) == 0
    ]) : rule.key => rule
  }

  runner_policy_attachments = {
    for attachment in flatten([
      for name, fleet in local.managed_iam_fleets : [
        for policy_arn in fleet.policy_arns : {
          key        = local.legacy_mode ? policy_arn : "${name}-${sha1(policy_arn)}"
          fleet_name = name
          policy_arn = policy_arn
        }
      ]
    ]) : attachment.key => attachment
  }

  github_environment = var.github_token_secret_arn == null ? {
    GONDOLA_GITHUB_APP_CLIENT_ID       = var.github_app_client_id
    GONDOLA_GITHUB_APP_INSTALLATION_ID = tostring(var.github_app_installation_id)
  } : {}

  github_secrets = merge(
    var.github_token_secret_arn == null ? {} : { GONDOLA_GITHUB_TOKEN = var.github_token_secret_arn },
    var.github_app_private_key_secret_arn == null ? {} : { GONDOLA_GITHUB_APP_PRIVATE_KEY = var.github_app_private_key_secret_arn }
  )

  entitlement_environment = merge(
    { GONDOLA_ENTITLEMENT_REQUIRED = tostring(var.entitlement_required) },
    var.entitlement_public_key == null ? {} : { GONDOLA_ENTITLEMENT_PUBLIC_KEY = var.entitlement_public_key },
    var.entitlement_key_id == null ? {} : { GONDOLA_ENTITLEMENT_KEY_ID = var.entitlement_key_id }
  )

  entitlement_secrets = var.entitlement_secret_arn == null ? {} : {
    GONDOLA_ENTITLEMENT = var.entitlement_secret_arn
  }

  entitlement_configuration_valid = (
    !var.entitlement_required &&
    var.entitlement_secret_arn == null &&
    var.entitlement_public_key == null &&
    var.entitlement_key_id == null
    ) || (
    var.entitlement_secret_arn != null &&
    var.entitlement_public_key != null &&
    var.entitlement_key_id != null
  )

  configured_secret_arns = toset(compact(concat(tolist(var.secret_arns), [
    var.github_token_secret_arn,
    var.github_app_private_key_secret_arn,
    var.container_registry_credentials_secret_arn,
    var.entitlement_secret_arn
  ])))

  github_credentials_valid = var.github_token_secret_arn != null ? (
    var.github_app_client_id == null &&
    var.github_app_installation_id == null &&
    var.github_app_private_key_secret_arn == null
    ) : (
    var.github_app_client_id != null &&
    var.github_app_installation_id != null &&
    var.github_app_private_key_secret_arn != null
  )

  runner_error_alarms = {
    for pair in setproduct(keys(local.fleets), ["RunnerLaunchErrors", "RunnerTerminationErrors", "RunnerReconcileErrors"]) :
    "${pair[0]}:${pair[1]}" => {
      fleet  = pair[0]
      metric = pair[1]
    }
  }
}

data "aws_ssm_parameter" "runner_ami" {
  for_each = {
    for name, fleet in local.fleets : name => fleet
    if fleet.ami_id == null
  }

  name = each.value.architecture == "arm64" ? "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id" : "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

locals {
  runner_ami_ids = {
    for name, fleet in local.fleets :
    name => (fleet.ami_id == null ? data.aws_ssm_parameter.runner_ami[name].value : fleet.ami_id)
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/gondola/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_cloudwatch_metric_alarm" "fleet_not_ready" {
  for_each = var.alarms_enabled ? local.fleets : {}

  alarm_name          = "${var.name}-${each.key}-not-ready"
  alarm_description   = "Gondola fleet ${each.key} has not reported operational readiness."
  namespace           = var.metrics_namespace
  metric_name         = "FleetReady"
  dimensions          = { Deployment = var.name, Fleet = each.key }
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  period              = 60
  statistic           = "Minimum"
  treat_missing_data  = "breaching"
  alarm_actions       = tolist(var.alarm_action_arns)
  ok_actions          = tolist(var.alarm_action_arns)
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "runner_errors" {
  for_each = var.alarms_enabled ? local.runner_error_alarms : {}

  alarm_name          = "${var.name}-${each.value.fleet}-${lower(each.value.metric)}"
  alarm_description   = "Gondola fleet ${each.value.fleet} emitted ${each.value.metric}."
  namespace           = var.metrics_namespace
  metric_name         = each.value.metric
  dimensions          = { Deployment = var.name, Fleet = each.value.fleet }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = tolist(var.alarm_action_arns)
  tags                = local.tags
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights_enabled ? "enabled" : "disabled"
  }

  tags = local.tags
}

resource "aws_dynamodb_table" "coordination" {
  name                        = "${var.name}-coordination"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "LeaseKey"
  deletion_protection_enabled = var.coordination_deletion_protection

  attribute {
    name = "LeaseKey"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  tags = local.tags
}

resource "aws_security_group" "control_plane" {
  name_prefix = "${var.name}-control-plane-"
  description = "Outbound-only network access for the Gondola control plane"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, {
    Name = "${var.name}-control-plane"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "control_plane_ipv4" {
  for_each = toset(var.egress_ipv4_cidrs)

  security_group_id = aws_security_group.control_plane.id
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
  description       = "Configured Gondola control-plane egress"
}

resource "aws_security_group" "runner" {
  for_each = {
    for name, fleet in local.fleets : name => fleet
    if length(fleet.security_group_ids) == 0
  }

  name_prefix = local.legacy_mode ? "${var.name}-runner-" : "${substr(var.name, 0, 32)}-${substr(each.key, 0, 32)}-runner-"
  description = "Outbound-only network access for ephemeral Gondola runners in fleet ${each.key}"
  vpc_id      = each.value.vpc_id

  tags = merge(local.fleet_tags[each.key], {
    Name = "${var.name}-${each.key}-runner"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "runner_ipv4" {
  for_each = local.runner_egress_rules

  security_group_id = aws_security_group.runner[each.value.fleet_name].id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "-1"
  description       = "Configured Gondola runner egress for ${each.value.fleet_name}"
}

locals {
  runner_security_group_ids = {
    for name, fleet in local.fleets :
    name => (length(fleet.security_group_ids) > 0 ? fleet.security_group_ids : [aws_security_group.runner[name].id])
  }

  runner_subnet_arns = distinct(flatten([
    for fleet in values(local.fleets) : [
      for subnet_id in fleet.subnet_ids :
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:subnet/${subnet_id}"
    ]
  ]))

  runner_security_group_arns = distinct(flatten([
    for security_group_ids in values(local.runner_security_group_ids) : [
      for security_group_id in security_group_ids :
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:security-group/${security_group_id}"
    ]
  ]))
}

resource "aws_iam_role" "runner" {
  for_each = local.managed_iam_fleets

  name_prefix = local.legacy_mode ? "${local.iam_role_name}-runner-" : "${substr("${var.name}-${each.key}", 0, 20)}-runner-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.fleet_tags[each.key]
}

resource "aws_iam_role_policy_attachment" "runner" {
  for_each = local.runner_policy_attachments

  role       = aws_iam_role.runner[each.value.fleet_name].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_instance_profile" "runner" {
  for_each = local.managed_iam_fleets

  name_prefix = local.legacy_mode ? "${var.name}-runner-" : "${substr("${var.name}-${each.key}", 0, 40)}-runner-"
  role        = aws_iam_role.runner[each.key].name
  tags        = local.fleet_tags[each.key]
}

locals {
  runner_instance_profile_arns = {
    for name, fleet in local.fleets :
    name => (fleet.iam_instance_profile_arn == null ? aws_iam_instance_profile.runner[name].arn : fleet.iam_instance_profile_arn)
  }
  runner_role_arns = {
    for name, fleet in local.fleets :
    name => (fleet.iam_role_arn == null ? aws_iam_role.runner[name].arn : fleet.iam_role_arn)
  }
}

resource "aws_launch_template" "runner" {
  for_each = local.fleets

  name_prefix                          = local.legacy_mode ? "${var.name}-runner-" : "${substr(var.name, 0, 32)}-${substr(each.key, 0, 32)}-runner-"
  image_id                             = local.runner_ami_ids[each.key]
  instance_type                        = each.value.instance_type
  instance_initiated_shutdown_behavior = "terminate"
  update_default_version               = true
  vpc_security_group_ids               = local.runner_security_group_ids[each.key]

  iam_instance_profile {
    arn = local.runner_instance_profile_arns[each.key]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted             = true
      delete_on_termination = true
      volume_type           = "gp3"
      volume_size           = each.value.root_volume_size
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  monitoring {
    enabled = false
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.fleet_tags[each.key]
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.fleet_tags[each.key]
  }

  tags = local.fleet_tags[each.key]
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${local.iam_role_name}-execution-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "secrets" {
  count = length(local.configured_secret_arns) > 0 ? 1 : 0

  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "ssm:GetParameters"
    ]
    resources = local.configured_secret_arns
  }
}

resource "aws_iam_role_policy" "secrets" {
  count = length(local.configured_secret_arns) > 0 ? 1 : 0

  name   = "read-config-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.secrets[0].json
}

data "aws_iam_policy_document" "secret_kms" {
  count = length(var.secret_kms_key_arns) > 0 ? 1 : 0

  statement {
    actions   = ["kms:Decrypt"]
    resources = var.secret_kms_key_arns
  }
}

resource "aws_iam_role_policy" "secret_kms" {
  count = length(var.secret_kms_key_arns) > 0 ? 1 : 0

  name   = "decrypt-config-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.secret_kms[0].json
}

resource "aws_iam_role" "task" {
  name_prefix        = "${local.iam_role_name}-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "task" {
  for_each = var.task_policy_arns

  role       = aws_iam_role.task.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid = "CoordinateControllers"
    actions = [
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem"
    ]
    resources = [aws_dynamodb_table.coordination.arn]
  }

  statement {
    sid       = "LaunchRunnerInstanceType"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "ArnEquals"
      variable = "ec2:LaunchTemplate"
      values   = [for template in values(aws_launch_template.runner) : template.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = distinct([for fleet in values(local.fleets) : fleet.instance_type])
    }
  }

  statement {
    sid     = "UseRunnerLaunchResources"
    actions = ["ec2:RunInstances"]
    resources = concat(
      [
        for ami_id in distinct(values(local.runner_ami_ids)) :
        "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}::image/${ami_id}"
      ],
      [
        "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}::snapshot/*",
        "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:volume/*",
        "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:network-interface/*"
      ],
      [for template in values(aws_launch_template.runner) : template.arn],
      local.runner_subnet_arns,
      local.runner_security_group_arns
    )

    condition {
      test     = "ArnEquals"
      variable = "ec2:LaunchTemplate"
      values   = [for template in values(aws_launch_template.runner) : template.arn]
    }
  }

  statement {
    sid     = "TagRunnersAtLaunch"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:*:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:${data.aws_partition.current.partition}:ec2:*:${data.aws_caller_identity.current.account_id}:volume/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances"]
    }
  }

  statement {
    sid       = "DescribeRunners"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "TerminateManagedRunners"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:*:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/gondola:deployment"
      values   = values(local.fleet_deployment_ids)
    }
  }

  statement {
    sid       = "PassRunnerRoles"
    actions   = ["iam:PassRole"]
    resources = values(local.runner_role_arns)

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  dynamic "statement" {
    for_each = var.metrics_enabled ? [1] : []

    content {
      sid       = "PublishGondolaMetrics"
      actions   = ["cloudwatch:PutMetricData"]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "cloudwatch:namespace"
        values   = [var.metrics_namespace]
      }
    }
  }
}

resource "aws_iam_role_policy" "controller" {
  name   = "manage-ephemeral-runners"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.controller.json
}

locals {
  fleet_runtime_configuration = [
    for name in sort(keys(local.fleets)) : {
      name                    = name
      scale_set_name          = local.fleets[name].scale_set_name
      runner_group            = local.fleets[name].runner_group
      labels                  = local.fleets[name].labels
      min_runners             = local.fleets[name].min_runners
      max_runners             = local.fleets[name].max_runners
      launch_template_id      = aws_launch_template.runner[name].id
      launch_template_version = tostring(aws_launch_template.runner[name].latest_version)
      subnet_ids              = local.fleets[name].subnet_ids
      runner_image            = local.fleets[name].runner_container_image
      deployment_id           = local.fleet_deployment_ids[name]
      max_runner_lifetime     = local.fleets[name].max_runner_lifetime
      capacity_mode           = local.fleets[name].capacity_mode
    }
  ]

  controller_generation = sha256(jsonencode({
    container_image    = var.container_image
    cpu                = var.cpu
    memory             = var.memory
    stop_timeout       = var.controller_stop_timeout_seconds
    adopt_scale_sets   = var.adopt_existing_scale_sets
    generation_nonce   = var.deployment_generation_nonce
    github_config_url  = var.github_config_url
    github_environment = local.github_environment
    entitlement        = local.entitlement_environment
    secret_references  = merge(var.secrets, local.github_secrets, local.entitlement_secrets)
    fleets             = local.fleet_runtime_configuration
    environment        = var.environment
    metrics_enabled    = var.metrics_enabled
    metrics_namespace  = var.metrics_namespace
  }))

  environment = merge(var.environment, local.github_environment, local.entitlement_environment, {
    GONDOLA_LISTEN_ADDRESS            = ":8080"
    GONDOLA_HEALTH_URL                = "http://127.0.0.1:8080/readyz"
    GONDOLA_SHUTDOWN_PERIOD           = "${var.controller_stop_timeout_seconds - 2}s"
    GONDOLA_LOG_LEVEL                 = "info"
    GONDOLA_CONTROLLER_ENABLED        = "true"
    GONDOLA_ADOPT_EXISTING_SCALE_SETS = tostring(var.adopt_existing_scale_sets)
    GONDOLA_COORDINATION_TABLE        = aws_dynamodb_table.coordination.name
    GONDOLA_GITHUB_CONFIG_URL         = var.github_config_url
    GONDOLA_DEPLOYMENT_ID             = var.name
    GONDOLA_DEPLOYMENT_GENERATION     = local.controller_generation
    GONDOLA_FLEETS_JSON               = jsonencode(local.fleet_runtime_configuration)
    GONDOLA_METRICS_ENABLED           = tostring(var.metrics_enabled)
    GONDOLA_METRICS_NAMESPACE         = var.metrics_namespace
  })

  secrets = merge(var.secrets, local.github_secrets, local.entitlement_secrets)
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    merge({
      name                   = "gondola"
      image                  = var.container_image
      essential              = true
      readonlyRootFilesystem = true
      stopTimeout            = var.controller_stop_timeout_seconds

      environment = [
        for key, value in local.environment : {
          name  = key
          value = value
        }
      ]

      secrets = [
        for key, value_from in local.secrets : {
          name      = key
          valueFrom = value_from
        }
      ]

      portMappings = [{
        name          = "http"
        containerPort = 8080
        protocol      = "tcp"
      }]

      healthCheck = {
        command     = ["CMD", "/gondola", "healthcheck"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = var.controller_health_start_period_seconds
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "control-plane"
        }
      }

      linuxParameters = {
        initProcessEnabled = true
      }
      }, var.container_registry_credentials_secret_arn == null ? {} : {
      repositoryCredentials = {
        credentialsParameter = var.container_registry_credentials_secret_arn
      }
    })
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  lifecycle {
    precondition {
      condition     = local.github_credentials_valid
      error_message = "Provide exactly one credential: github_token_secret_arn or complete GitHub App credentials."
    }

    precondition {
      condition     = local.entitlement_configuration_valid
      error_message = "Production requires entitlement_secret_arn, entitlement_public_key, and entitlement_key_id together. Non-release builds may set entitlement_required = false only for development and isolated tests; official release binaries still refuse the bypass."
    }

    precondition {
      condition     = length(distinct([for fleet in values(local.fleets) : fleet.scale_set_name])) == length(local.fleets)
      error_message = "Every fleet must use a unique scale_set_name."
    }

    precondition {
      condition     = alltrue([for fleet in values(local.fleets) : length(fleet.subnet_ids) > 0])
      error_message = "Every runner fleet requires at least one subnet."
    }

    precondition {
      condition     = !var.require_image_digest || can(regex("@sha256:[0-9a-fA-F]{64}$", var.container_image))
      error_message = "container_image must be pinned by sha256 digest when require_image_digest is true."
    }

    precondition {
      condition     = !var.require_runner_image_digest || alltrue([for fleet in values(local.fleets) : can(regex("@sha256:[0-9a-fA-F]{64}$", fleet.runner_container_image))])
      error_message = "Every runner_container_image must be pinned by sha256 digest when require_runner_image_digest is true."
    }

    precondition {
      condition     = !var.alarms_enabled || var.metrics_enabled
      error_message = "alarms_enabled requires metrics_enabled so the controller emits the alarmed metrics."
    }
  }

  tags = local.tags
}

resource "aws_ecs_service" "this" {
  name                    = var.name
  cluster                 = aws_ecs_cluster.this.id
  task_definition         = aws_ecs_task_definition.this.arn
  desired_count           = var.desired_count
  launch_type             = "FARGATE"
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"
  # A new immutable generation must acquire the lease and initialize every
  # fleet before it can become healthy. ECS therefore needs permission to stop
  # the final old-generation task; upgrades have a brief scheduling handoff.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200
  wait_for_steady_state              = var.wait_for_steady_state

  deployment_circuit_breaker {
    enable   = true
    rollback = var.deployment_circuit_breaker_rollback
  }

  network_configuration {
    assign_public_ip = var.assign_public_ip
    security_groups  = [aws_security_group.control_plane.id]
    subnets          = var.subnet_ids
  }

  lifecycle {
    precondition {
      condition     = var.desired_count == 1 || length(distinct([for subnet in data.aws_subnet.control_plane : subnet.availability_zone_id])) >= 2
      error_message = "desired_count = 2 requires control-plane subnet_ids spanning at least two Availability Zones."
    }
  }

  tags = local.tags
}
