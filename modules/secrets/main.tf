# modules/secrets
#
# Secrets Manager entries + a per-service CMK + the `secrets[]` projection that
# modules/ecs-service feeds straight into the task definition.
#
# The projection output is the whole point of this module. Before month 7 the api's
# WORLDFLOW_API_KEY, NORDPAY_API_KEY and VAULT_API_KEY sat in the task definition's
# `environment[]` block in plaintext, which meant they were in every `describe-task-definition`
# call and in every plan output. PAY-1755 moved them here. Three review rounds with
# dhotfix, and the rule that came out of it is in CONTRIBUTING.md §5.3: a credential goes
# in `secrets`, never in `environment_vars`.
#
# terraform does not know the values. It creates the container and a random placeholder
# version so the task can start; a human sets the real value once, out of band.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "Payzeno ${var.service} (${var.environment}) secret envelope key"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days

  tags = merge(module.names.tags, {
    Name = "${local.qualifier}-cmk"
  })

  lifecycle {
    precondition {
      condition     = var.environment != "production" || var.kms_deletion_window_days >= 30
      error_message = "PAYZENO_INFRA_PRECONDITION: production CMKs keep the full 30-day deletion window. A seven-day window on the key that wraps SESSION_SECRET is an outage with a countdown on it."
    }
  }
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.qualifier}"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secret_set

  name                    = local.secret_path[each.key]
  description             = "${each.key} for ${var.service} in ${var.environment}. Value set out of band — terraform only owns the container."
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = var.recovery_window_days

  tags = merge(module.names.tags, {
    Name      = local.secret_path[each.key]
    SecretKey = each.key
  })
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Outputs. These stayed here when variables.tf was split out; see the note there.
# ---------------------------------------------------------------------------

output "task_secrets" {
  description = "ECS `secrets[]` projection — [{ name, valueFrom }] — dropped straight into the container definition."
  value = [
    for n, s in aws_secretsmanager_secret.this : {
      name      = n
      valueFrom = s.arn
    }
  ]
}
