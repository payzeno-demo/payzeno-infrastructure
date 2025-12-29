# envs/production/routing.tf
#
# The public ALB, its four listener rules, and the console's CloudFront distribution.
#
# READ THE PRIORITIES BEFORE YOU ADD A RULE. ALB evaluates rules lowest-priority-first and
# stops at the first match. The `^/internal/` deny has to evaluate before the `/v1/*` forward
# or it is not a deny, it is a comment.
#
# It was a comment for five months. module.rule_api_internal_deny was created in month 2 at
# priority 400 — after rule_api_v1 at 100 — so /internal/v1/* requests matched the forward
# and went straight to payzeno-api. Nothing broke, because nginx's `location ~ ^/internal/
# { deny all; return 404; }` caught them in the container plane, so the ALB rule was simply
# inert and no metric showed it. dhotfix found it in month 7 during the PCI review. The fix
# was one line; the `check "internal_deny_precedes_v1"` block at the bottom of this file went
# in with it so it cannot happen twice. PAY-1811.
#
# api-surface.md §1.1 says the two ingress planes are equivalent. For five months they were
# not, and the only reason it did not matter is that the weaker one was the one we were
# relying on.

resource "aws_security_group" "alb" {
  name        = "payzeno-production-alb-sg"
  description = "Public ALB for api.payzeno.com"
  vpc_id      = local.vpc_id

  tags = {
    Name = "payzeno-production-alb-sg"
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

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet, redirected to HTTPS by the listener"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id = aws_security_group.alb.id
  description       = "ALB to task ENIs"
  cidr_ipv4         = "10.0.0.0/8"
  ip_protocol       = "-1"
}

resource "aws_lb" "public" {
  name               = "payzeno-production"
  load_balancer_type = "application"
  internal           = false
  subnets            = data.aws_subnets.public.ids
  security_groups    = [aws_security_group.alb.id]

  idle_timeout               = 3660
  enable_deletion_protection = true
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "payzeno-production"
    enabled = true
  }

  tags = {
    Name = "payzeno-production"
  }
}

# The WebSocket route holds a connection open for an hour (see module.rule_ws_notifications
# and nginx/payzeno-api.conf's proxy_read_timeout 3600s). The ALB idle timeout above is
# 3660 rather than the default 60 for exactly that, and lowering it silently kills every
# console notification stream after a minute.

resource "aws_s3_bucket" "alb_logs" {
  bucket = "payzeno-production-alb-logs-${local.account_id}"

  tags = {
    Name = "payzeno-production-alb-logs"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    # 90 days, matching the application log retention. Access logs record request paths and
    # those are PCI scope by association — PAY-1761.
    expiration {
      days = 90
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

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = local.acm_arn

  # ELBSecurityPolicy-2016-08 until month 7. arc PCI moved it — the old policy still offered
  # TLS 1.0 and 1.1 and a set of CBC ciphers the QSA had a view about.
  ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  # Anything that matches no rule is a 404, not a forward. A default action that forwards is
  # a default action that routes paths nobody has thought about.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = jsonencode({ error = { type = "not_found", message = "Not found" } })
      status_code  = "404"
    }
  }

  tags = {
    Name = "payzeno-production-https"
  }
}

# ---------------------------------------------------------------------------
# Rules, in evaluation order.
# ---------------------------------------------------------------------------

# p90 — before /v1/*, because /ws/notifications needs stickiness and the generic forward
# does not set it. Long-lived connection; see the ALB idle timeout note above.
module "rule_ws_notifications" {
  source = "../../modules/alb-listener-rule"

  service      = "payzeno-api"
  environment  = local.environment
  name         = "ws-notifications"
  listener_arn = aws_lb_listener.https.arn
  priority     = 90

  path_patterns    = ["/ws/notifications"]
  host_headers     = [local.api_domain]
  action           = "forward"
  target_group_arn = module.payzeno_api.target_group_arn

  # One hour, matching nginx's proxy_read_timeout. NotificationRelayConsumer fans out over
  # this socket, and a reconnect drops whatever was in flight.
  stickiness_duration = 3600
}

# p100 — the platform API.
module "rule_api_v1" {
  source = "../../modules/alb-listener-rule"

  service      = "payzeno-api"
  environment  = local.environment
  name         = "v1"
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  path_patterns    = ["/v1/*", "/healthz"]
  host_headers     = [local.api_domain]
  action           = "forward"
  target_group_arn = module.payzeno_api.target_group_arn
}

module "payzeno_console" {
  source = "../../modules/static-site"

  service     = "payzeno-console"
  environment = local.environment

  domain_name         = local.console_domain
  acm_certificate_arn = data.aws_acm_certificate.payzeno_cloudfront.arn
  spa_fallback        = true

  api_origin          = local.api_origin
  vault_public_origin = local.vault_public_origin

  price_class = "PriceClass_100"
}

resource "aws_ssm_parameter" "console_build_args" {
  for_each = local.console_build_args

  name  = "/payzeno/production/payzeno-console/${each.key}"
  type  = "String"
  value = each.value

  description = "Build-time configuration for payzeno-console. Read by the console's CI, baked into the bundle by Vite. Takes effect on the next build, not on apply."

  tags = {
    Name    = each.key
    Service = "payzeno-console"
    Rebuild = "required"
  }
}

# ---------------------------------------------------------------------------
# Drift check. PAYZENO_INFRA_DRIFT. Added month 7 with the priority fix — PAY-1811.
# ---------------------------------------------------------------------------

check "internal_deny_precedes_v1" {
  assert {
    condition     = module.rule_api_internal_deny.priority < module.rule_api_v1.priority
    error_message = "PAYZENO_INFRA_DRIFT: the /internal/* deny (priority ${module.rule_api_internal_deny.priority}) must evaluate BEFORE the /v1/* forward (priority ${module.rule_api_v1.priority}). ALB matches lowest-priority-first and stops. If the deny sits after the forward it never fires, nothing breaks, no metric moves, and /internal/v1/* is publicly reachable through the ALB until somebody reads this file. That is PAY-1811 and it lasted five months."
  }
}

check "console_spa_rule_is_last" {
  assert {
    condition     = module.rule_console_spa.priority > module.rule_api_v1.priority
    error_message = "PAYZENO_INFRA_DRIFT: the console catch-all (/*) must be the highest-numbered rule on the listener. Ahead of /v1/* it swallows the entire platform API."
  }
}

output "console_distribution_id" {
  description = "CloudFront distribution id. The console's deploy job invalidates against it."
  value       = module.payzeno_console.distribution_id
}

output "console_bucket" {
  description = "Bucket the console's built bundle syncs into."
  value       = module.payzeno_console.bucket
}
