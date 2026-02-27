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

