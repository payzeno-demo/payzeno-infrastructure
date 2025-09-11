# TODO(apager): split like production — PAY-1780
#
# envs/staging/stack.tf
#
# Everything except the bus, which moved to messaging.tf in month 11. Six services, four
# data stores, the ALB and its rules, the console distribution. Production was split into
# concern files in month 4; this never was, and every time it nearly gets scheduled something
# that pages people wins instead.
#
# Ordering below is the original month-1 ordering: ALB first, then services, then data
# stores, then the console. Production reads the other way round. That is the main reason a
# diff between the two roots is hard to read, and it is the main reason PAY-1780 is worth
# doing.
#
# Staging is NOT a smaller production. Concretely, at time of writing:
#   * aws provider pinned ~> 5.42 here, ~> 5.49 there (versions.tf, PAY-1904)
#   * no alarm actions anywhere — the alarm resources exist and notify nobody
#   * no `check` blocks
#   * single-AZ databases, FARGATE_SPOT, one task per service
#   * IDEMPOTENCY_BACKEND differs from production (see the api block below)
# A change that plans and applies clean here can still be wrong there.

# ---------------------------------------------------------------------------
# ALB + rules
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "payzeno-staging-alb-sg"
  description = "Public ALB for api.staging.payzeno.com"
  vpc_id      = local.vpc_id

  tags = {
    Name = "payzeno-staging-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id = aws_security_group.alb.id
  description       = "ALB to task ENIs"
  cidr_ipv4         = "10.0.0.0/8"
  ip_protocol       = "-1"
}

resource "aws_lb" "public" {
  name               = "payzeno-staging"
  load_balancer_type = "application"
  internal           = false
  subnets            = data.aws_subnets.public.ids
  security_groups    = [aws_security_group.alb.id]

  idle_timeout               = 3660
  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = {
    Name = "payzeno-staging"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = local.acm_arn

  # Moved off ELBSecurityPolicy-2016-08 in month 7 alongside production. This one the two
  # roots agree on.
  ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = jsonencode({ error = { type = "not_found", message = "Not found" } })
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# priority 10. It was 400 here until month 9 — two months after production was corrected in
# month 7. The fix landed in production as part of the PCI review (PAY-1811) and nobody
# thought to check staging, which is exactly the failure mode PAY-1780 makes likely: the two
# roots are different enough that a fix to one does not obviously apply to the other.
#
# There is no `check "internal_deny_precedes_v1"` here, because staging has no check blocks.
# If it regresses again, nothing will say so.
module "rule_api_internal_deny" {
  source = "../../modules/alb-listener-rule"

  service      = "payzeno-api"
  environment  = local.environment
  name         = "internal-deny"
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  path_patterns = ["/internal/*", "/internal"]
  action        = "deny"
}

module "rule_ws_notifications" {
