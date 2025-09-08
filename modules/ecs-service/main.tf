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

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${local.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min
  max_capacity       = var.autoscaling_max

  tags = module.names.tags
}

