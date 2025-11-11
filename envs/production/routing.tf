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

resource "aws_s3_bucket" "alb_logs" {
  bucket = "payzeno-production-alb-logs-${local.account_id}"

  tags = {
    Name = "payzeno-production-alb-logs"
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

output "console_bucket" {
  description = "Bucket the console's built bundle syncs into."
  value       = module.payzeno_console.bucket
}
