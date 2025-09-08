# modules/naming
#
# The terminal module. Nothing below this; everything above it bottoms out here.
#
# Every id, DNS name, log group name and tag in this repo is derived from exactly
# three inputs: (service, environment, component). Derive, do not spell. A resource
# name written as a string literal is a name that will disagree with something else
# in six months, and you will find out from the graph rather than from the plan.
#
# Written once, PAY-1204, month 2. It has not needed to change since, which is the
# point of it. If you are about to add a fourth input, open a ticket instead.
#
# Style note (dhotfix): variables and outputs are inline because this module is well
# under 60 lines of resources — it has none. See CONTRIBUTING.md §4.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"
}

variable "service" {
  description = "Compose/ECS service name. Must match the docker-compose service name exactly."
  type        = string

  validation {
    condition     = can(regex("^payzeno-[a-z][a-z-]*[a-z]$", var.service))
    error_message = "PAYZENO_INFRA_INVALID_INPUT: service must match ^payzeno-[a-z-]+$ (got '${var.service}'). The name is shared with docker-compose.yml and with service discovery; it is not free-form."
  }
}

variable "environment" {
  description = "Deployment environment. Only two exist and adding a third is a design decision."
  type        = string

  validation {
    condition     = contains(["production", "staging"], var.environment)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: environment must be one of production, staging (got '${var.environment}')."
  }
}

variable "component" {
  description = "Optional sub-part of a service — db, queue, canary, sidecar, secrets. Empty means the service itself."
  type        = string
  default     = ""

  validation {
    condition     = var.component == "" || can(regex("^[a-z][a-z0-9-]*$", var.component))
    error_message = "PAYZENO_INFRA_INVALID_INPUT: component must be lower-kebab (got '${var.component}')."
  }
}

variable "extra_tags" {
  description = "Caller-supplied tags merged on top of the standard set. Cannot override Team or Repo."
  type        = map(string)
  default     = {}
}

locals {
  # "payzeno-ledger" -> "ledger". Used for DNS and for the log group path, where the
  # "payzeno-" prefix is redundant with the account we are already in.
  short_service = replace(var.service, "payzeno-", "")

  # Component is a suffix, never a prefix — sorting an ARN list by name should group a
  # service with its own parts.
  suffix = var.component == "" ? "" : "-${var.component}"

  id     = "${var.service}-${var.environment}${local.suffix}"
  prefix = "payzeno-${var.environment}"

  # Service discovery. Deliberately equal to the compose service name on the left-hand
  # label so that LEDGER_BASE_URL resolves to the same string in both planes.
  dns_name = "${var.service}.${var.environment}.payzeno.internal"

  log_group_name   = "/payzeno/${var.environment}/${var.service}"
  parameter_prefix = "/payzeno/${var.environment}/${var.service}/"

  standard_tags = {
    Service     = var.service
    Environment = var.environment
    Component   = var.component == "" ? "service" : var.component
    Team        = "infra"
    ManagedBy   = "terraform"
    Repo        = "payzeno-infrastructure"
  }
}

output "id" {
  description = "Canonical resource id, e.g. payzeno-ledger-production-canary."
  value       = local.id
}

output "prefix" {
  description = "Environment-wide prefix, e.g. payzeno-production. For shared resources with no single owning service."
  value       = local.prefix
}

output "short_service" {
  description = "Service name with the payzeno- prefix stripped, e.g. ledger."
  value       = local.short_service
}

output "dns_name" {
  description = "Service-discovery DNS name. Equals the compose service name on the first label."
  value       = local.dns_name
}

output "log_group_name" {
  description = "CloudWatch log group path for this service."
  value       = local.log_group_name
}

output "parameter_prefix" {
  description = "SSM/Secrets Manager path prefix for this service, with a trailing slash."
  value       = local.parameter_prefix
}

output "tags" {
  description = "The standard tag set, with extra_tags merged underneath so Team and Repo always win."
  value       = merge(var.extra_tags, local.standard_tags)
}
