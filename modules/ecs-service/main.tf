# modules/ecs-service
#
# Fargate service + task definition + IAM + autoscaling + ALB target group + three alarms.
# The deepest module in the repo and the one every service goes through.
#
# Layout:
#   main.tf             this file — naming, sidecar, secrets, SG, target group, service, autoscaling, alarms
#   task_definition.tf  the container definitions and the log group
#   iam.tf              task role + execution role and their policies
#   variables.tf        the interface
#   outputs.tf          what the env roots consume
#
# TODO(apager): autoscaling on SQS depth, not just CPU — PAY-1912. The ledger's load is a
# queue backlog, not a request rate, and CPU is a lagging proxy for it. On the night of
# PAY-2041 the drain was 4,113 items behind and the service never scaled, because the tasks
# were blocked on the acquirer and therefore idle. CPU said everything was fine.

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
  component   = var.component
  extra_tags  = var.extra_tags
}

module "sidecar" {
  source = "../nginx-sidecar"
  count  = var.enable_nginx_sidecar ? 1 : 0

  service        = var.service
  environment    = var.environment
  upstream_port  = var.container_port
  config_key     = "${module.names.id}/nginx.conf"
  listener_ports = [80, 8081]
  extra_tags     = var.extra_tags
}

module "task_secrets" {
  source = "../secrets"
  count  = length(var.managed_secret_names) > 0 ? 1 : 0

  service      = var.service
  environment  = var.environment
  purpose      = var.component == "" ? "task" : "task-${var.component}"
  secret_names = var.managed_secret_names
  # The acquirer keys are rotated by hand, with the acquirer on the phone, so a service
  # that holds one gets manual rotation for all of them. Coarse, but the alternative is a
  # per-secret rotation map and nobody has needed it.
  rotation_days = anytrue([for n in var.managed_secret_names : endswith(n, "_API_KEY")]) ? 0 : 90
  extra_tags    = var.extra_tags
}

locals {
  # Per-service contracted env keys. variables.tf validates against the union of these
  # (terraform 1.7 cannot reference var.service from a variable validation); the
  # precondition below narrows it to the service actually being built.
  allowed_env_keys = {
    "payzeno-api" = [
      "NODE_ENV", "PORT", "LOG_LEVEL", "AWS_REGION", "OTEL_EXPORTER_OTLP_ENDPOINT",
      "LEDGER_BASE_URL", "BILLING_LEGACY_BASE_URL", "BILLING_LEGACY_USER",
      "VAULT_BASE_URL", "VAULT_PUBLIC_URL", "CSRF_COOKIE_NAME", "CHECKOUT_PUBLIC_URL",
      "SMTP_HOST", "SMTP_PORT", "EMAIL_FROM", "CONSOLE_PUBLIC_URL", "ADMIN_PUBLIC_URL",
      "KYC_DOCUMENTS_BUCKET", "FX_PROVIDER_URL", "FX_CHECKOUT_MARKUP_BPS", "FX_PAYOUT_MARKUP_BPS",
      "SNS_PAYMENTS_TOPIC_ARN", "SNS_MERCHANT_TOPIC_ARN", "SQS_LEDGER_QUEUE_URL",
      "SQS_API_WEBHOOKS_URL", "SQS_CONSOLE_NOTIFICATIONS_URL", "SQS_DLQ_URL",
      "IDEMPOTENCY_BACKEND", "IDEMPOTENCY_TTL_HOURS", "IDEMPOTENCY_LEASE_SECONDS",
      "RATE_LIMIT_DEFAULT_RPM", "WEBHOOK_MAX_ATTEMPTS", "WEBHOOK_RETRY_WINDOW_HOURS",
      "PROCESSOR_DEFAULT_ACQUIRER", "REFUND_WINDOW_DAYS",
      "WORLDFLOW_BASE_URL", "NORDPAY_BASE_URL",
      "FLAG_LEDGER_OWNS_INVOICES", "FLAG_LEDGER_OWNS_FEES", "FLAG_REDACT_PAN_IN_LOGS",
    ]
    "payzeno-ledger" = [
      "LOG_LEVEL", "AWS_REGION", "OTEL_EXPORTER_OTLP_ENDPOINT",
      "FX_PROVIDER_URL", "FX_PAYOUT_MARKUP_BPS",
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
      "FLAG_RECONCILE_RETRY_BATCH_LOCK", "FLAG_DUPLICATE_SETTLEMENT_ALARM",
      "FLAG_PAYOUT_SAME_DAY_ACH", "FLAG_REDACT_PAN_IN_LOGS",
      "RECONCILE_RETRY_BATCH_LOCK",
    ]
    "payzeno-billing-legacy" = [
      "LOG_LEVEL", "AWS_REGION", "OTEL_EXPORTER_OTLP_ENDPOINT",
      "SPRING_PROFILES_ACTIVE", "SPRING_DATASOURCE_URL", "SPRING_DATASOURCE_USERNAME",
      "PAYZENO_LEDGER_BASE_URL", "PAYZENO_API_BASE_URL",
      "BILLING_INVOICE_PREFIX", "BILLING_DUNNING_ENABLED", "BILLING_LEDGER_EXPORT_ENABLED",
      "BILLING_FLAG_LEDGER_OWNS_INVOICES", "BILLING_FLAG_LEDGER_OWNS_FEES",
    ]
    # The vault is a vendor image (payzeno/card-vault). It takes PORT and LOG_LEVEL and
    # nothing else; everything it needs is mounted, not passed.
    "payzeno-vault" = ["PORT", "LOG_LEVEL", "AWS_REGION"]
    "payzeno-nginx" = ["LOG_LEVEL"]
  }

  service_allowed_keys = lookup(local.allowed_env_keys, var.service, [])

  unexpected_env_keys = [
    for k in keys(var.environment_vars) : k
    if !contains(local.service_allowed_keys, k)
  ]

  # var.secrets is what the caller hands in (DATABASE_URL from rds-postgres, REDIS_URL from
  # the cache); module.task_secrets is what this module creates. The task definition needs
  # the union, and iam.tf needs the union of their ARNs.
  managed_secret_arns = length(module.task_secrets) > 0 ? module.task_secrets[0].secret_arns : {}
  all_secret_arns     = merge(local.managed_secret_arns, var.secrets)

  is_alb_fronted = var.alb_listener_arn != null

  alarm_actions = var.pager_topic_arn == null ? [] : [var.pager_topic_arn]

  cluster_name = element(split("/", var.cluster_arn), length(split("/", var.cluster_arn)) - 1)

  # Alarm names are prefixed with the component when there is one. Without this the canary's
  # three alarms collide with the main ledger service's — same service, same environment,
  # same alarm name — and CloudWatch resolves a collision by letting the second apply
  # silently overwrite the first. Found the hard way in month 5.
  alarm_prefix = var.component == "" ? "" : "${var.component}-"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${module.names.id}-sg"
  description = "Task ENIs for ${var.service} (${var.environment})"
  vpc_id      = var.vpc_id

  tags = merge(module.names.tags, {
    Name = "${module.names.id}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Only the ALB may reach the application port. Service-to-service traffic goes through the
# internal nginx listener on 8081, which is a separate rule below.
resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  count = local.is_alb_fronted && var.alb_security_group_id != null ? 1 : 0

  security_group_id            = aws_security_group.this.id
  description                  = "ALB to ${var.service}:${var.container_port}"
  referenced_security_group_id = var.alb_security_group_id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# The internal plane. 10/8 only — the same CIDR nginx/payzeno-internal.conf allows.
resource "aws_vpc_security_group_ingress_rule" "internal_listener" {
  count = var.enable_nginx_sidecar ? 1 : 0

  security_group_id = aws_security_group.this.id
  description       = "Internal /internal/v1/* listener, VPC only"
  cidr_ipv4         = "10.0.0.0/8"
  from_port         = 8081
  to_port           = 8081
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Acquirers, Secrets Manager, SNS/SQS, RDS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Target group
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "this" {
  count = local.is_alb_fronted ? 1 : 0

  name        = substr("${module.names.id}-tg", 0, 32)
  port        = var.enable_nginx_sidecar ? 80 : var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  # Deregistration has to outlast the longest in-flight request. The ledger's settlement
  # import holds a connection for minutes; 30s here drops it mid-batch.
  deregistration_delay = 120

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = merge(module.names.tags, {
    Name = "${module.names.id}-tg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = module.names.id
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  propagate_tags  = "SERVICE"

  enable_execute_command = var.enable_execute_command

  # Two tasks' worth of headroom during a deploy, and never below the running count.
  # The 100/200 pair is what makes a deploy of desired_count=1 (which is what production
  # ran for seven hours after PAY-2041) still a rolling deploy rather than a gap.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = local.is_alb_fronted ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.enable_nginx_sidecar ? "nginx" : var.service
      container_port   = var.enable_nginx_sidecar ? 80 : var.container_port
    }
  }

  service_registries {
    registry_arn = aws_service_discovery_service.this.arn
  }

  tags = merge(module.names.tags, {
    Name = module.names.id
  })

  lifecycle {
    # The image tag moves on every deploy and deploys do not come from terraform. Without
    # this, `terraform apply` for an unrelated tag change rolls the service back to whatever
    # sha was in state.
    ignore_changes = [task_definition]

    precondition {
      condition     = length(local.unexpected_env_keys) == 0
      error_message = "PAYZENO_INFRA_PRECONDITION: ${var.service} was given environment_vars keys that are not on its contracted list (interfaces.md §7): ${join(", ", local.unexpected_env_keys)}. If the key is real, add it to local.allowed_env_keys AND to docker-compose.yml AND to the service's config module."
    }

    precondition {
      # var.secrets says "inject this env var from this ARN". If the ARN is empty the task
      # definition is still valid HCL and the container starts with the variable unset,
      # which surfaces as a null-pointer four layers into the application.
      condition     = alltrue([for k, v in var.secrets : v != null && v != ""])
      error_message = "PAYZENO_INFRA_PRECONDITION: every key in var.secrets needs a resolved Secrets Manager ARN. A null here becomes an unset env var at runtime, not a plan error."
    }

    precondition {
      condition     = var.desired_count >= var.autoscaling_min
      error_message = "PAYZENO_INFRA_PRECONDITION: desired_count (${var.desired_count}) is below autoscaling_min (${var.autoscaling_min}); application autoscaling will immediately scale the service back up and the apply will look like it did nothing."
    }
  }

  depends_on = [aws_iam_role_policy.exec]
}

# ---------------------------------------------------------------------------
# Service discovery. The DNS name equals the compose service name on purpose — it is what
# makes LEDGER_BASE_URL the same string in both planes.
# ---------------------------------------------------------------------------

resource "aws_service_discovery_service" "this" {
  name = var.component == "" ? var.service : "${var.service}-${var.component}"

  dns_config {
    namespace_id = data.aws_service_discovery_dns_namespace.internal.id

    dns_records {
      ttl  = 15
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = module.names.tags
}

data "aws_service_discovery_dns_namespace" "internal" {
  name = "${var.environment}.payzeno.internal"
  type = "DNS_PRIVATE"
}

# DEAD: the pre-Service-Connect Cloud Map registry. Kept at count = 0 because two services
# still have the old ARNs in their state file and removing the block entirely produced a
# destroy plan nobody was going to approve on a Friday. It creates nothing.
locals {
  legacy_service_registry = {
    enabled      = false
    namespace    = "payzeno.local"
    dns_ttl      = 60
    health_check = "/healthz"
  }
}

resource "aws_service_discovery_service" "legacy" {
  count = local.legacy_service_registry.enabled ? 1 : 0

  name = var.service

  dns_config {
    namespace_id = data.aws_service_discovery_dns_namespace.internal.id

    dns_records {
      ttl  = local.legacy_service_registry.dns_ttl
      type = "A"
    }
  }
}

# ---------------------------------------------------------------------------
# Autoscaling — CPU target tracking. See the TODO at the top of this file.
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${local.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min
  max_capacity       = var.autoscaling_max

  tags = module.names.tags
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${module.names.id}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.autoscaling_target_cpu

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    # Scale out fast, scale in slowly. A settlement import that finishes does not mean the
    # next one is not thirty seconds away.
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# ---------------------------------------------------------------------------
# Alarms. Three per service, every one with a runbook link.
# ---------------------------------------------------------------------------

module "cpu_alarm" {
  source = "../cloudwatch-alarm"

  service     = var.service
  environment = var.environment
  name        = "${local.alarm_prefix}cpu-high"
  namespace   = "AWS/ECS"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  threshold   = 85

  period             = 60
  evaluation_periods = 5

  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = aws_ecs_service.this.name
  }

  alarm_actions = local.alarm_actions
  runbook_url   = "${var.runbook_base_url}/oncall.md#service-cpu-high"
  description   = "${var.service} is above 85% CPU in ${var.environment} for five minutes."
}

module "unhealthy_host_alarm" {
  source = "../cloudwatch-alarm"
  count  = local.is_alb_fronted ? 1 : 0

  service     = var.service
  environment = var.environment
  name        = "${local.alarm_prefix}unhealthy-hosts"
  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"
  threshold   = 0

  comparison_operator = "GreaterThanThreshold"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup = aws_lb_target_group.this[0].arn_suffix
  }

  alarm_actions = local.alarm_actions
  runbook_url   = "${var.runbook_base_url}/oncall.md#unhealthy-targets"
  description   = "${var.service} has targets failing ${var.health_check_path} in ${var.environment}."
}

# A task that stops on its own is either OOM or a crash loop. Either way somebody wants to
# know before the deploy that caused it is four deploys old.
module "task_stopped_alarm" {
  source = "../cloudwatch-alarm"

  service     = var.service
  environment = var.environment
  name        = "${local.alarm_prefix}tasks-below-desired"
  namespace   = "AWS/ECS"
  metric_name = "RunningTaskCount"
  statistic   = "Minimum"
  threshold   = var.desired_count

  comparison_operator = "LessThanThreshold"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = local.cluster_name
    ServiceName = aws_ecs_service.this.name
  }

  alarm_actions = local.alarm_actions
  runbook_url   = "${var.runbook_base_url}/oncall.md#tasks-below-desired"
  description   = "${var.service} is running fewer than ${var.desired_count} tasks in ${var.environment}."
}
