variable "cache_fleets" {
  description = "Opt-in customer-owned S3 caches keyed by fleet name (default in legacy mode). Each cache is restricted to one repository and trust namespace. Use separate runner groups/fleets for untrusted code; jobs on a fleet share its IAM authority."
  type = map(object({
    repository      = string
    trust_namespace = string
    retention_days  = optional(number, 14)
    read_only       = optional(bool, false)
    helper_image    = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, cache in var.cache_fleets :
      can(regex("^[a-z0-9][a-z0-9-]{0,38}/[a-z0-9._-]{1,100}$", cache.repository)) &&
      !contains([".", ".."], element(split("/", cache.repository), 1)) &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", cache.trust_namespace)) &&
      cache.retention_days >= 1 && cache.retention_days <= 365 && floor(cache.retention_days) == cache.retention_days &&
      (cache.helper_image == null ? true : can(regex("^[A-Za-z0-9][A-Za-z0-9._/:@-]+@sha256:[0-9a-fA-F]{64}$", cache.helper_image)))
    ])
    error_message = "Caches require a lowercase owner/repository, a safe 1-64 character trust namespace, retention of 1-365 whole days, and a digest-pinned helper_image when supplied."
  }
}

locals {
  cache_prefixes = {
    for name, cache in var.cache_fleets : name => "fleets/${name}/trust/${cache.trust_namespace}/repos/${cache.repository}"
  }
  cache_runtime_configuration = {
    for name, cache in var.cache_fleets : name => {
      bucket       = aws_s3_bucket.cache[name].id
      region       = data.aws_region.current.region
      prefix       = local.cache_prefixes[name]
      repository   = cache.repository
      read_only    = cache.read_only
      helper_image = coalesce(cache.helper_image, var.container_image)
    }
  }
}

resource "aws_s3_bucket" "cache" {
  for_each = var.cache_fleets

  bucket        = "gondola-cache-${data.aws_caller_identity.current.account_id}-${substr(sha256("${var.name}/${each.key}/${data.aws_region.current.region}"), 0, 20)}"
  force_destroy = false
  tags          = merge(local.tags, { "gondola:component" = "cache", "gondola:fleet" = each.key, "gondola:trust" = each.value.trust_namespace })

  lifecycle {
    precondition {
      condition     = contains(keys(local.managed_iam_fleets), each.key)
      error_message = "Each cache_fleets entry must identify a configured fleet with module-managed IAM. External IAM cache integration is not supported in this release."
    }
    precondition {
      condition     = try(local.fleets[each.key].runner_group != "default", false) || endswith(lower(var.github_config_url), "/${each.value.repository}")
      error_message = "Organization/enterprise cache fleets require an explicit runner_group restricted to the configured repository and trust tier in GitHub."
    }
    precondition {
      condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/:@-]+@sha256:[0-9a-fA-F]{64}$", coalesce(each.value.helper_image, var.container_image)))
      error_message = "Cache bootstrap requires a digest-pinned helper image, even when controller image digest enforcement is disabled."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cache" {
  for_each = var.cache_fleets
  bucket   = aws_s3_bucket.cache[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cache" {
  for_each = var.cache_fleets
  bucket   = aws_s3_bucket.cache[each.key].id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cache" {
  for_each = var.cache_fleets
  bucket   = aws_s3_bucket.cache[each.key].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cache" {
  for_each = var.cache_fleets
  bucket   = aws_s3_bucket.cache[each.key].id
  rule {
    id     = "expire-cache"
    status = "Enabled"
    # Covers obsolete namespaces too when repository or trust settings change.
    filter {}
    expiration { days = each.value.retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_policy" "cache" {
  for_each = var.cache_fleets
  bucket   = aws_s3_bucket.cache[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.cache[each.key].arn, "${aws_s3_bucket.cache[each.key].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "RequireImmutableWrites"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cache[each.key].arn}/*"
        Condition = { Null = { "s3:if-none-match" = "true" } }
      }
    ]
  })
}

resource "aws_iam_role_policy" "cache" {
  for_each = { for name, cache in var.cache_fleets : name => cache if contains(keys(local.managed_iam_fleets), name) }
  name     = "gondola-cache"
  role     = aws_iam_role.runner[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "ListCacheScope"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [aws_s3_bucket.cache[each.key].arn]
        Condition = { StringLike = { "s3:prefix" = ["${local.cache_prefixes[each.key]}/*"] } }
      },
      {
        Sid      = "ReadCacheScope"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.cache[each.key].arn}/${local.cache_prefixes[each.key]}/*"]
      }
      ], each.value.read_only ? [] : [
      {
        Sid       = "WriteImmutableCacheScope"
        Effect    = "Allow"
        Action    = ["s3:PutObject"]
        Resource  = ["${aws_s3_bucket.cache[each.key].arn}/${local.cache_prefixes[each.key]}/*"]
        Condition = { StringEquals = { "s3:if-none-match" = "*" } }
      }
    ])
  })
}

output "cache_fleets" {
  description = "Customer-owned cache bucket, scope, region and access mode by fleet. Empty when caching is disabled. No credentials."
  value       = local.cache_runtime_configuration
}
