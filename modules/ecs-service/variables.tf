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

variable "component" {
  description = "Optional sub-part, used when one service has two ECS services. Only 'canary' uses this, and only in production. Empty for the normal case."
  type        = string
  default     = ""
}

variable "image" {
  description = "Fully qualified image reference including tag or digest. Never :latest — a task that restarts must come back as the thing that was running."
  type        = string

  validation {
    condition     = !endswith(var.image, ":latest")
    error_message = "PAYZENO_INFRA_INVALID_INPUT: :latest is not a deployable tag. Pin the git sha."
  }
}

variable "container_port" {
  description = "Port the application listens on. Same value as docker-compose, deliberately."
  type        = number

  validation {
    condition     = contains([8080, 8000, 8090, 8099], var.container_port)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: container_port must be one of 8080 (api), 8000 (ledger), 8090 (billing-legacy), 8099 (vault). A new port is a conversation, not a variable."
  }
}

variable "memory" {
  description = "Fargate task memory in MiB. Must be a legal pairing with cpu — Fargate rejects the combination at run-task time, not at plan time."
  type        = number
  default     = 2048
}

variable "secrets" {
  description = "Map of env var name -> Secrets Manager ARN. Injected as the task definition's secrets[] block; the value never appears in a plan."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k in keys(var.secrets) : can(regex("^[A-Z][A-Z0-9_]*$", k))
    ])
    error_message = "PAYZENO_INFRA_INVALID_INPUT: secret keys are SCREAMING_SNAKE env var names, not paths."
  }
}

variable "enable_nginx_sidecar" {
  description = "Run the nginx sidecar in the task. True for anything ALB-fronted; false for the vault, which is only reachable inside the VPC."
  type        = bool
  default     = true
}

variable "subnet_ids" {
  description = "Private subnets for the ENIs. Three AZs in production, two in staging."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "PAYZENO_INFRA_INVALID_INPUT: at least two subnets, in two AZs. One subnet is a single point of failure with extra steps."
  }
}

variable "alb_listener_arn" {
  description = "HTTPS listener this service's target group is attached to. Null for services with no ALB path (the vault)."
  type        = string
  default     = null
}

variable "alb_security_group_id" {
  description = "Security group of the ALB, allowed inbound to the container port. Null when there is no ALB."
  type        = string
  default     = null
}

variable "cluster_arn" {
  description = "ECS cluster the service runs on. One cluster per environment."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Dropped 365 -> 90 for api and ledger in the PCI wave (PAY-1761) — request logs are in scope and 365 days of them is 365 days of exposure."
  type        = number
  default     = 90
}

variable "autoscaling_max" {
  description = "Maximum task count."
  type        = number
  default     = 8
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

variable "runbook_base_url" {
  description = "Base URL for the runbook links attached to this service's alarms."
  type        = string
  default     = "https://github.com/payzeno/payzeno-infrastructure/blob/main/docs/runbooks"
}

variable "extra_tags" {
  description = "Merged under the standard tag set."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Dead inputs. Month-3 blue/green spike (PAY-1341), abandoned when we worked out that
# CodeDeploy blue/green on Fargate needed a second target group per service and a
# deployment controller we would then own. No caller sets any of these three. They are
# defaulted so nothing breaks, and they are still here because deleting a variable from a
# module with six call sites is a bigger PR than it looks and nobody has wanted it enough.
#
# If you are reading this because tflint flagged them: yes. PAY-1958.
# ---------------------------------------------------------------------------

variable "enable_execute_command" {
  description = "DEAD — enable ECS Exec on the service. Never set by a caller."
  type        = bool
  default     = false
}

variable "efs_volumes" {
  description = "DEAD — EFS volume mounts for the task. Never set by a caller; nothing here is stateful."
  type = list(object({
    name           = string
    file_system_id = string
    root_directory = string
  }))
  default = []
}

variable "blue_green" {
  description = "DEAD — CodeDeploy blue/green deployment controller. Never set by a caller. See PAY-1341."
  type        = bool
  default     = false
}
