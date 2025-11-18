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
  source = "../../modules/alb-listener-rule"

  service      = "payzeno-api"
  environment  = local.environment
  name         = "ws-notifications"
  listener_arn = aws_lb_listener.https.arn
  priority     = 90

  path_patterns       = ["/ws/notifications"]
  host_headers        = [local.api_domain]
  action              = "forward"
  target_group_arn    = module.payzeno_api.target_group_arn
  stickiness_duration = 3600
}

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

module "rule_console_spa" {
  source = "../../modules/alb-listener-rule"

  service      = "payzeno-api"
  environment  = local.environment
  name         = "console-spa"
  listener_arn = aws_lb_listener.https.arn
  priority     = 500

  path_patterns    = ["/*"]
  host_headers     = [local.console_domain]
  action           = "forward"
  target_group_arn = module.payzeno_api.target_group_arn
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

locals {
  api_env = {
    NODE_ENV = "staging"
    PORT     = "8080"

    LEDGER_BASE_URL         = "http://payzeno-ledger.staging.payzeno.internal:8000"
    BILLING_LEGACY_BASE_URL = "http://payzeno-billing-legacy.staging.payzeno.internal:8090"
    VAULT_BASE_URL          = "http://payzeno-vault.staging.payzeno.internal:8099"
    VAULT_PUBLIC_URL        = local.vault_public_origin
    BILLING_LEGACY_USER     = "payzeno_api"

    WORLDFLOW_BASE_URL = local.worldflow_base_url
    NORDPAY_BASE_URL   = local.nordpay_base_url

    SNS_PAYMENTS_TOPIC_ARN = module.topic_payments_events.topic_arn
    SNS_MERCHANT_TOPIC_ARN = module.topic_merchant_events.topic_arn

    SQS_LEDGER_QUEUE_URL          = module.q_api_ledger.queue_url
    SQS_API_WEBHOOKS_URL          = module.q_api_webhooks.queue_url
    SQS_CONSOLE_NOTIFICATIONS_URL = module.q_console_notifications.queue_url
    SQS_DLQ_URL                   = module.q_dlq_monitor.queue_url

    AWS_REGION = local.region

    IDEMPOTENCY_BACKEND       = "redis"
    IDEMPOTENCY_TTL_HOURS     = "24"
    IDEMPOTENCY_LEASE_SECONDS = "30"

    # staging only — raised from 600 to unblock the checkout load test. Do not copy this to
    # production; the number there is sized on the acquirer's own limit, not on ours.
    RATE_LIMIT_DEFAULT_RPM = "6000"

    WEBHOOK_MAX_ATTEMPTS       = "8"
    WEBHOOK_RETRY_WINDOW_HOURS = "24"
    PROCESSOR_DEFAULT_ACQUIRER = "worldflow"
    REFUND_WINDOW_DAYS         = "120"
    CSRF_COOKIE_NAME           = "payzeno_csrf"

    FLAG_LEDGER_OWNS_FEES = "true"

    # Flipped to "true" in month 11 and reverted three days later: the console's invoice list
    # went empty, because the ledger owns the flag but nginx/payzeno-internal.conf still
    # routes /internal/v1/invoices/ to payzeno_legacy. The flag and the proxy_pass move
    # together or not at all. arc MIG step 4 is still not done.
    FLAG_LEDGER_OWNS_INVOICES = "false"

    FLAG_REDACT_PAN_IN_LOGS = "true"

    LOG_LEVEL                   = "debug"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.staging.payzeno.internal:4318"
  }

  ledger_env = {
    DATABASE_POOL_SIZE         = "10"
    DATABASE_POOL_MAX_OVERFLOW = "5"

    SNS_LEDGER_TOPIC_ARN    = module.topic_ledger_events.topic_arn
    SQS_PAYMENTS_QUEUE_URL  = module.q_ledger_payments.queue_url
    SQS_MERCHANTS_QUEUE_URL = module.q_ledger_merchants.queue_url

    AWS_REGION = local.region

    WORLDFLOW_BASE_URL              = local.worldflow_base_url
    WORLDFLOW_BREAKER_THRESHOLD_PCT = "50"
    WORLDFLOW_BREAKER_WINDOW        = "60"
    WORLDFLOW_BREAKER_RESET_SECONDS = "30"

    NORDPAY_BASE_URL              = local.nordpay_base_url
    NORDPAY_BREAKER_THRESHOLD_PCT = "50"
    NORDPAY_BREAKER_WINDOW        = "60"
    NORDPAY_BREAKER_RESET_SECONDS = "30"

    # 300 rather than production's 900, so a settlement change is testable inside a working
    # session instead of a coffee break. It also means staging never reproduces the
    # sweep/drain overlap window that PAY-2041 turned on, which is worth knowing before you
    # conclude something is safe because staging was fine.
