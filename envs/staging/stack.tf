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
    RECONCILE_SWEEP_INTERVAL_SECONDS     = "300"
    RECONCILE_SWEEP_WALL_BUDGET_SECONDS  = "240"
    RECONCILE_MAX_ITEMS_PER_RUN          = "500"
    RECONCILE_MAX_ATTEMPTS               = "6"
    RECONCILE_RETRY_BACKOFF_BASE_SECONDS = "15"

    RETRY_DRAIN_INTERVAL_SECONDS = "60"
    RETRY_DRAIN_BATCH_SIZE       = "100"

    # true on the single staging task. There is no canary here — staging runs one ledger
    # task, so the drain is either on or off and it is on. Production runs it on exactly one
    # of five tasks, which is a configuration staging cannot express and therefore cannot
    # test.
    RETRY_DRAIN_ENABLED = "true"

    PAYOUT_CUTOFF_ACH_UTC             = "21:00"
    PAYOUT_CUTOFF_SAME_DAY_ACH_UTC    = "14:45"
    PAYOUT_CUTOFF_SEPA_UTC            = "15:00"
    PAYOUT_CUTOFF_FASTER_PAYMENTS_UTC = "17:30"

    LEDGER_AUDIT_ENABLED        = "true"
    SETTLEMENT_IMPORT_ENABLED   = "true"
    FUNDING_MATCH_TOLERANCE_BPS = "5"

    FLAG_DUPLICATE_SETTLEMENT_ALARM = "true"
    FLAG_PAYOUT_SAME_DAY_ACH        = "true"
    FLAG_REDACT_PAN_IN_LOGS         = "true"

    LOG_LEVEL                   = "debug"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.staging.payzeno.internal:4318"
  }
}

module "payzeno_api" {
  source = "../../modules/ecs-service"

  service        = "payzeno-api"
  environment    = local.environment
  image          = local.images.api
  container_port = 8080
  desired_count  = 2

  cpu    = 1024
  memory = 2048

  environment_vars = local.api_env

  secrets = {
    DATABASE_URL            = module.db_api.database_url_secret_arn
    REDIS_URL               = module.cache_api_secret.secret_arns["REDIS_URL"]
    SESSION_SECRET          = module.platform_secrets.secret_arns["SESSION_SECRET"]
    API_KEY_PEPPER          = module.platform_secrets.secret_arns["API_KEY_PEPPER"]
    INTERNAL_API_SECRET     = module.platform_secrets.secret_arns["INTERNAL_API_SECRET"]
    VAULT_API_KEY           = module.platform_secrets.secret_arns["VAULT_API_KEY"]
    WORLDFLOW_API_KEY       = module.platform_secrets.secret_arns["WORLDFLOW_API_KEY"]
    NORDPAY_API_KEY         = module.platform_secrets.secret_arns["NORDPAY_API_KEY"]
    BILLING_LEGACY_PASSWORD = module.platform_secrets.secret_arns["BILLING_LEGACY_PASSWORD"]
    WEBHOOK_SIGNING_KEK     = module.platform_secrets.secret_arns["WEBHOOK_SIGNING_KEK"]
  }

  vpc_id                = local.vpc_id
  subnet_ids            = local.subnet_ids
  cluster_arn           = aws_ecs_cluster.payzeno.arn
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb.id

  log_retention_days = 14

  autoscaling_min        = 2
  autoscaling_max        = 4
  autoscaling_target_cpu = 70

  # No pager topic in staging. The alarms are created without actions.
  pager_topic_arn  = null
  runbook_base_url = local.runbook_base_url
}

module "payzeno_ledger" {
  source = "../../modules/ecs-service"

  service        = "payzeno-ledger"
  environment    = local.environment
  image          = local.images.ledger
  container_port = 8000
  desired_count  = 1

  cpu    = 1024
  memory = 4096

  environment_vars = local.ledger_env

  secrets = {
    DATABASE_URL        = module.db_ledger.database_url_secret_arn
    INTERNAL_API_SECRET = module.platform_secrets.secret_arns["INTERNAL_API_SECRET"]
    WORLDFLOW_API_KEY   = module.platform_secrets.secret_arns["WORLDFLOW_API_KEY"]
    NORDPAY_API_KEY     = module.platform_secrets.secret_arns["NORDPAY_API_KEY"]
  }

  vpc_id                = local.vpc_id
  subnet_ids            = local.subnet_ids
  cluster_arn           = aws_ecs_cluster.payzeno.arn
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb.id

  log_retention_days = 14

  autoscaling_min        = 1
  autoscaling_max        = 2
  autoscaling_target_cpu = 75

  pager_topic_arn  = null
  runbook_base_url = local.runbook_base_url
}

module "payzeno_billing_legacy" {
  source = "../../modules/ecs-service"

  service        = "payzeno-billing-legacy"
  environment    = local.environment
  image          = local.images.billing_legacy
  container_port = 8090
  desired_count  = 1

  cpu    = 1024
  memory = 2048

  environment_vars = {
    SPRING_PROFILES_ACTIVE     = "staging"
    SPRING_DATASOURCE_URL      = module.db_billing.jdbc_url
    SPRING_DATASOURCE_USERNAME = "payzeno_billing"

    PAYZENO_LEDGER_BASE_URL = "http://payzeno-ledger.staging.payzeno.internal:8000"
    PAYZENO_API_BASE_URL    = "http://payzeno-api.staging.payzeno.internal:8080"

    BILLING_INVOICE_PREFIX        = "PZS"
    BILLING_DUNNING_ENABLED       = "false"
    BILLING_LEDGER_EXPORT_ENABLED = "true"

    BILLING_FLAG_LEDGER_OWNS_INVOICES = "false"
    BILLING_FLAG_LEDGER_OWNS_FEES     = "true"

    LOG_LEVEL                   = "debug"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.staging.payzeno.internal:4318"
    AWS_REGION                  = local.region
  }

  secrets = {
    SPRING_DATASOURCE_PASSWORD = module.db_billing.master_user_secret_arn
    PAYZENO_INTERNAL_SECRET    = module.platform_secrets.secret_arns["INTERNAL_API_SECRET"]
  }

  vpc_id                = local.vpc_id
  subnet_ids            = local.subnet_ids
  cluster_arn           = aws_ecs_cluster.payzeno.arn
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb.id

  log_retention_days = 14

  autoscaling_min        = 1
  autoscaling_max        = 2
  autoscaling_target_cpu = 75

  pager_topic_arn  = null
  runbook_base_url = local.runbook_base_url
}

module "payzeno_vault" {
  source = "../../modules/ecs-service"

  service        = "payzeno-vault"
  environment    = local.environment
  image          = local.images.vault
  container_port = 8099
  desired_count  = 1

  cpu    = 512
  memory = 1024

  environment_vars = {
    PORT       = "8099"
    LOG_LEVEL  = "info"
    AWS_REGION = local.region
  }

  secrets = {}

  vpc_id      = local.vpc_id
  subnet_ids  = local.subnet_ids
  cluster_arn = aws_ecs_cluster.payzeno.arn

  alb_listener_arn     = null
  enable_nginx_sidecar = false

  log_retention_days = 14

  autoscaling_min        = 1
  autoscaling_max        = 2
  autoscaling_target_cpu = 70

  pager_topic_arn  = null
  runbook_base_url = local.runbook_base_url
}

module "payzeno_nginx" {
  source = "../../modules/nginx-sidecar"

  service       = "payzeno-nginx"
  environment   = local.environment
  upstream_port = 8080
  config_key    = "payzeno-nginx-staging/nginx.conf"

  listener_ports = [80, 8081]
}

# ---------------------------------------------------------------------------
# Data stores
# ---------------------------------------------------------------------------

module "db_api" {
  source = "../../modules/rds-postgres"

  service       = "payzeno-api"
  environment   = local.environment
  database_name = "payzeno_api"

  instance_class        = "db.t4g.medium"
  allocated_storage     = 50
  max_allocated_storage = 100
  multi_az              = false

  client_pool_size = 10
  max_connections  = 100

  performance_insights_enabled = false
  backup_retention_days        = 1

  vpc_id              = local.vpc_id
  subnet_ids          = local.subnet_ids
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  alarm_actions    = []
  runbook_base_url = local.runbook_base_url
}

module "db_ledger" {
  source = "../../modules/rds-postgres"

  service       = "payzeno-ledger"
  environment   = local.environment
  database_name = "payzeno_ledger"

  instance_class        = "db.t4g.medium"
  allocated_storage     = 50
  max_allocated_storage = 200
  multi_az              = false

  # Pool is 10 here, not production's 20 — one task, and t4g.medium does not have the memory
  # for production's connection budget. The 3x rule still holds; it is the rule, not the
  # number, that is contracted.
  client_pool_size = 10
  max_connections  = 100

  performance_insights_enabled = false
  backup_retention_days        = 1

  vpc_id              = local.vpc_id
  subnet_ids          = local.subnet_ids
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  alarm_actions    = []
  runbook_base_url = local.runbook_base_url
}

# Same pre-convention module as production. env_suffix is the only thing that distinguishes
# them, and it only reaches the instance identifier — the subnet group, parameter group and
# security group this creates are all still named "...-prod". Staging is a separate account,
# which is the only reason that works.
#
# do not delete until MIG step 5 — PAY-1522. Yes, in staging too. That near-miss was here.
module "db_billing" {
  source = "../../modules/rds-mysql"

  database_name  = "payzeno_billing"
  instance_class = "db.t4g.medium"
  env_suffix     = "stg"
}

resource "aws_elasticache_subnet_group" "cache_api" {
  name       = "payzeno-api-staging-cache"
  subnet_ids = local.subnet_ids
}

resource "aws_security_group" "cache_api" {
  name        = "payzeno-api-staging-cache-sg"
  description = "Redis for payzeno-api"
  vpc_id      = local.vpc_id

  tags = {
    Name = "payzeno-api-staging-cache-sg"
  }
}

resource "aws_elasticache_replication_group" "cache_api" {
  replication_group_id = "payzeno-api-staging"
  description          = "payzeno-api idempotency store and rate-limit counters (staging)"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = "cache.t4g.micro"
  port           = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.cache_api.name
  security_group_ids = [aws_security_group.cache_api.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  snapshot_retention_limit = 0

  tags = {
    Name = "payzeno-api-staging"
  }
}

module "cache_api_secret" {
  source = "../../modules/secrets"

  service       = "payzeno-api"
  environment   = local.environment
  purpose       = "cache"
  secret_names  = ["REDIS_URL"]
  rotation_days = 0

  # Staging secrets are recreated often enough that a 30-day recovery window means the next
  # apply collides with a scheduled-for-deletion name. Zero is only acceptable here.
  recovery_window_days     = 0
  kms_deletion_window_days = 7
}

module "platform_secrets" {
  source = "../../modules/secrets"

  service     = "payzeno-api"
  environment = local.environment
  purpose     = "platform"

  # WEBHOOK_SIGNING_KEK is in this list here but is a standalone resource with its own CMK in
  # production, because rotating it there re-wraps every merchant's webhook secret. In
  # staging there are eleven test endpoints and nobody minds.
  secret_names = [
    "SESSION_SECRET",
    "API_KEY_PEPPER",
    "INTERNAL_API_SECRET",
    "VAULT_API_KEY",
    "WORLDFLOW_API_KEY",
    "NORDPAY_API_KEY",
    "BILLING_LEGACY_PASSWORD",
    "WEBHOOK_SIGNING_KEK",
  ]

  rotation_days            = 0
  recovery_window_days     = 0
  kms_deletion_window_days = 7
}

# Database ingress, declared here for the same module-cycle reason as production. See the
# note at the top of envs/production/data_stores.tf.

resource "aws_vpc_security_group_ingress_rule" "db_api_from_api" {
  security_group_id            = module.db_api.security_group_id
  description                  = "payzeno-api tasks to payzeno_api"
  referenced_security_group_id = module.payzeno_api.security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_ledger_from_ledger" {
  security_group_id            = module.db_ledger.security_group_id
  description                  = "payzeno-ledger tasks to payzeno_ledger"
  referenced_security_group_id = module.payzeno_ledger.security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cache_api_from_api" {
  security_group_id            = aws_security_group.cache_api.id
  description                  = "payzeno-api tasks to Redis"
  referenced_security_group_id = module.payzeno_api.security_group_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# Console
# ---------------------------------------------------------------------------

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

locals {
  console_build_args = {
    VITE_PAYZENO_API_URL             = "${local.api_origin}/v1"
    VITE_WS_URL                      = "wss://${local.api_domain}/ws/notifications"
    VITE_VAULT_PUBLIC_URL            = local.vault_public_origin
    VITE_ENVIRONMENT                 = "staging"
    VITE_SENTRY_DSN                  = "https://8a2d1f47c9e04b6b@o412.ingest.sentry.io/5502"
    VITE_FEATURE_SETTLEMENT_EXPLORER = "true"

    # staging only. The dispute evidence upload flow is behind this and it is not finished —
    # production is still "false" and stays that way until the evidence retention question
    # is answered. Do not promote this by copying the block.
    VITE_FEATURE_DISPUTE_EVIDENCE_V2 = "true"
  }
}

resource "aws_ssm_parameter" "console_build_args" {
  for_each = local.console_build_args

  name  = "/payzeno/staging/payzeno-console/${each.key}"
  type  = "String"
  value = each.value

  description = "Build-time configuration for payzeno-console (staging). Read by the console's CI, baked in by Vite. Takes effect on the next build."

  tags = {
    Name    = each.key
    Service = "payzeno-console"
    Rebuild = "required"
  }
}

output "alb_dns_name" {
  description = "Staging ALB hostname."
  value       = aws_lb.public.dns_name
}

output "console_distribution_id" {
  description = "Staging CloudFront distribution id."
  value       = module.payzeno_console.distribution_id
}
