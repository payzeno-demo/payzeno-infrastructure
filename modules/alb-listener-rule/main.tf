# modules/alb-listener-rule
#
# One path-prefix rule on the public HTTPS listener. Either forwards to a target group or
# returns a fixed 404.
#
# This module is the AWS half of a pair. The other half is nginx/payzeno-api.conf, which
# carries the same rules in the container plane (interfaces.md §6.3, api-surface.md §1.1).
# They are supposed to be equivalent. When they are not, the container plane wins silently
# and you find out years later.
#
# The deny body is a 404, not a 403. A 403 on /internal/v1/merchants/mrc_123 tells an
# unauthenticated caller that mrc_123 exists. Same rule as MerchantScopeGuard in the api.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

module "names" {
  source = "../naming"

  service     = var.service
  environment = var.environment
  component   = "rule"
  extra_tags  = var.extra_tags
}

locals {
  is_forward = var.action == "forward"

  rule_name = "${module.names.id}-${var.name}"

  deny_body = jsonencode({
    error = {
      type    = "not_found"
      message = "Not found"
    }
  })
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.listener_arn
  priority     = var.priority

  dynamic "action" {
    for_each = local.is_forward ? [1] : []

    content {
      type = "forward"

      forward {
        target_group {
          arn = var.target_group_arn
        }

        dynamic "stickiness" {
          for_each = var.stickiness_duration > 0 ? [1] : []

          content {
            enabled  = true
            duration = var.stickiness_duration
          }
        }
      }
    }
  }

  dynamic "action" {
    for_each = local.is_forward ? [] : [1]

    content {
      type = "fixed-response"

      fixed_response {
        content_type = "application/json"
        message_body = local.deny_body
        status_code  = "404"
      }
    }
  }

  condition {
    path_pattern {
      values = var.path_patterns
    }
  }

  dynamic "condition" {
    for_each = length(var.host_headers) > 0 ? [1] : []

    content {
      host_header {
        values = var.host_headers
      }
    }
  }

  tags = merge(module.names.tags, {
    Name     = local.rule_name
