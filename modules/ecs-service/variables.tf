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

variable "desired_count" {
  description = "Task count. Production runs 4 for api and ledger, 2 for legacy and vault."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 1 && var.desired_count <= 20
    error_message = "PAYZENO_INFRA_INVALID_INPUT: desired_count must be between 1 and 20. Zero is not a deploy strategy — if you want a service off, delete the module block."
  }
}

variable "cpu" {
  description = "Fargate task CPU units. 512, 1024, 2048, 4096."
  type        = number
  default     = 1024

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.cpu)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: cpu must be a valid Fargate size (256, 512, 1024, 2048, 4096)."
  }
}

variable "memory" {
  description = "Fargate task memory in MiB. Must be a legal pairing with cpu — Fargate rejects the combination at run-task time, not at plan time."
  type        = number
  default     = 2048
}

variable "environment_vars" {
  description = <<-EOT
    Plaintext environment for the container. Names come from interfaces.md §7 and must be
    identical to the names in docker-compose.yml; values differ per environment.

    Credentials do NOT go here. They go in var.secrets, backed by modules/secrets, and land
    in the task definition's secrets[] block as an ARN. See CONTRIBUTING.md §5.
  EOT
  type        = map(string)
  default     = {}

  validation {
    # The union of interfaces.md §7 across all four services. Per-service narrowing is the
    # precondition in main.tf. Adding a key to the contract means adding it here too — that
    # is deliberate friction, and it is one line.
    condition = alltrue([
      for k in keys(var.environment_vars) : contains([
        # --- shared / platform -------------------------------------------------
        "NODE_ENV", "PORT", "LOG_LEVEL", "AWS_REGION", "OTEL_EXPORTER_OTLP_ENDPOINT",
        # --- payzeno-api -------------------------------------------------------
        "LEDGER_BASE_URL", "BILLING_LEGACY_BASE_URL", "BILLING_LEGACY_USER",
        "VAULT_BASE_URL", "VAULT_PUBLIC_URL", "CSRF_COOKIE_NAME",
        "SNS_PAYMENTS_TOPIC_ARN", "SNS_MERCHANT_TOPIC_ARN", "SQS_LEDGER_QUEUE_URL",
        "SQS_API_WEBHOOKS_URL", "SQS_CONSOLE_NOTIFICATIONS_URL", "SQS_DLQ_URL",
        "IDEMPOTENCY_BACKEND", "IDEMPOTENCY_TTL_HOURS", "IDEMPOTENCY_LEASE_SECONDS",
        "RATE_LIMIT_DEFAULT_RPM", "WEBHOOK_MAX_ATTEMPTS", "WEBHOOK_RETRY_WINDOW_HOURS",
        "PROCESSOR_DEFAULT_ACQUIRER", "REFUND_WINDOW_DAYS",
        # --- payzeno-ledger ----------------------------------------------------
        "DATABASE_POOL_SIZE", "DATABASE_POOL_MAX_OVERFLOW",
        "SNS_LEDGER_TOPIC_ARN", "SQS_PAYMENTS_QUEUE_URL", "SQS_MERCHANTS_QUEUE_URL",
        "WORLDFLOW_BASE_URL", "WORLDFLOW_BREAKER_THRESHOLD_PCT", "WORLDFLOW_BREAKER_WINDOW",
        "WORLDFLOW_BREAKER_RESET_SECONDS",
        "NORDPAY_BASE_URL", "NORDPAY_BREAKER_THRESHOLD_PCT", "NORDPAY_BREAKER_WINDOW",
        "NORDPAY_BREAKER_RESET_SECONDS",
        "RECONCILE_SWEEP_INTERVAL_SECONDS", "RECONCILE_SWEEP_WALL_BUDGET_SECONDS",
        "RECONCILE_MAX_ITEMS_PER_RUN", "RECONCILE_MAX_ATTEMPTS",
        "RECONCILE_RETRY_BACKOFF_BASE_SECONDS",
        "RETRY_DRAIN_INTERVAL_SECONDS", "RETRY_DRAIN_BATCH_SIZE", "RETRY_DRAIN_ENABLED",
        "PAYOUT_CUTOFF_ACH_UTC", "PAYOUT_CUTOFF_SAME_DAY_ACH_UTC", "PAYOUT_CUTOFF_SEPA_UTC",
        "PAYOUT_CUTOFF_FASTER_PAYMENTS_UTC",
        "LEDGER_AUDIT_ENABLED", "SETTLEMENT_IMPORT_ENABLED", "FUNDING_MATCH_TOLERANCE_BPS",
        # --- payzeno-billing-legacy --------------------------------------------
        "SPRING_PROFILES_ACTIVE", "SPRING_DATASOURCE_URL", "SPRING_DATASOURCE_USERNAME",
        "PAYZENO_LEDGER_BASE_URL", "PAYZENO_API_BASE_URL",
        "BILLING_INVOICE_PREFIX", "BILLING_DUNNING_ENABLED", "BILLING_LEDGER_EXPORT_ENABLED",
        # --- feature flags ------------------------------------------------------
        "FLAG_LEDGER_OWNS_INVOICES", "FLAG_LEDGER_OWNS_FEES", "FLAG_REDACT_PAN_IN_LOGS",
        "FLAG_RECONCILE_RETRY_BATCH_LOCK", "FLAG_DUPLICATE_SETTLEMENT_ALARM",
        "FLAG_PAYOUT_SAME_DAY_ACH",
        "BILLING_FLAG_LEDGER_OWNS_INVOICES", "BILLING_FLAG_LEDGER_OWNS_FEES",
        # --- PAY-2043 kill switch, month 9. Removed again by PAY-2056. ----------
        "RECONCILE_RETRY_BATCH_LOCK",
      ], k)
    ])
    error_message = "PAYZENO_INFRA_INVALID_INPUT: environment_vars contains a key that is not in interfaces.md §7. Add it to the contract, to docker-compose.yml, to the service's config module, and to the list in modules/ecs-service/variables.tf — in that order — or fix the typo."
  }

  validation {
    # AWS_ENDPOINT_URL points at localstack. It exists in docker-compose.yml and nowhere else.
    # Setting it in ECS makes the SDK talk to a host that does not exist inside the VPC and
    # the failure mode is a 30-second connect timeout on every publish.
    condition     = !contains(keys(var.environment_vars), "AWS_ENDPOINT_URL")
    error_message = "PAYZENO_INFRA_INVALID_INPUT: AWS_ENDPOINT_URL is a localstack-only key. It belongs in docker-compose.yml and must never appear in terraform."
  }

  validation {
    condition = alltrue([
      for k in keys(var.environment_vars) : !can(regex("(SECRET|PASSWORD|_KEY|KEK|PEPPER|DATABASE_URL|REDIS_URL)$", k))
    ])
    error_message = "PAYZENO_INFRA_INVALID_INPUT: that looks like a credential. Credentials go in var.secrets, backed by modules/secrets, and land in the task definition as an ARN. PAY-1755 moved three of these out of plaintext and we are not putting them back."
  }
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

variable "managed_secret_names" {
  description = "Secret names this service owns and that modules/secrets should create for it. Distinct from var.secrets, which is ARNs handed in by a caller (a database URL, for instance, is created by rds-postgres)."
  type        = list(string)
  default     = []
}

variable "health_check_path" {
  description = "Path the ALB target group probes. Every Payzeno service serves /healthz on its main port."
  type        = string
  default     = "/healthz"
}

variable "enable_nginx_sidecar" {
  description = "Run the nginx sidecar in the task. True for anything ALB-fronted; false for the vault, which is only reachable inside the VPC."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "VPC the service and its target group live in."
  type        = string
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

variable "autoscaling_min" {
  description = "Minimum task count for the target-tracking policy. Should equal desired_count in production."
  type        = number
  default     = 2
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
