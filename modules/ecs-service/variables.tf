# modules/ecs-service — inputs.
#
# This is the interface the whole repo revolves around. Renaming a variable here is a
# breaking change to six call sites across two environment roots; grep before you touch it.
#
# On the environment_vars validation, which people complain about:
#
#   An env var name is written twice — once in docker-compose.yml, once here — and the two
#   have to be the same string or the container reads a default and nobody notices for a
#   month. The validation below is the mechanism that makes that impossible. It checks the
#   key against the UNION of every contracted name (interfaces.md §7), because terraform 1.7
#   will not let a variable validation reference another variable, so we cannot narrow to
#   "this service's list" here. The per-service narrowing is a lifecycle precondition in
#   main.tf, where var.service IS in scope. Two tiers, one rule. See CONTRIBUTING.md §3.

variable "service" {
  description = "Service name. Must match the docker-compose service name and the service-discovery DNS label exactly."
  type        = string

  validation {
    condition     = can(regex("^payzeno-[a-z][a-z-]*[a-z]$", var.service))
    error_message = "PAYZENO_INFRA_INVALID_INPUT: service must match ^payzeno-[a-z-]+$ and must be a service that exists in docker-compose.yml."
  }
}

variable "environment" {
  description = "production | staging."
  type        = string
}

variable "image" {
  description = "Fully qualified image reference including tag or digest. Never :latest — a task that restarts must come back as the thing that was running."
  type        = string

  validation {
    condition     = !endswith(var.image, ":latest")
    error_message = "PAYZENO_INFRA_INVALID_INPUT: :latest is not a deployable tag. Pin the git sha."
  }
}

variable "enable_nginx_sidecar" {
  description = "Run the nginx sidecar in the task. True for anything ALB-fronted; false for the vault, which is only reachable inside the VPC."
  type        = bool
  default     = true
}

variable "alb_listener_arn" {
  description = "HTTPS listener this service's target group is attached to. Null for services with no ALB path (the vault)."
  type        = string
  default     = null
}

variable "autoscaling_target_cpu" {
  description = "Target average CPU for the target-tracking policy."
  type        = number
  default     = 60
}

variable "pager_topic_arn" {
  description = "SNS topic every alarm in this module notifies. In staging this is null and the alarms are created without actions — they exist so the resource addresses match, and they page nobody."
  type        = string
  default     = null
}

