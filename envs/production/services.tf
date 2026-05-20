# envs/production/services.tf
#
# The five ECS services (six instantiations — the ledger has a canary) and the ingress nginx
# config. This is the most-edited file in the repo: every env-var change in the org lands
# here and in docker-compose.yml, in that order, in the same PR.
#
# Names are load-bearing in three directions at once:
#   * `service` matches the docker-compose service name -> the graph joins the two planes
#   * `service` is the first label of the service-discovery DNS name -> LEDGER_BASE_URL and
#     PAYZENO_LEDGER_BASE_URL resolve to the same node instead of to two string literals
#   * every key in environment_vars is validated against interfaces.md §7
#
# Values here are AWS values. The same NAMES appear in docker-compose.yml with localstack
# values. AWS_ENDPOINT_URL is the one key that exists there and must never exist here.

locals {
  # -------------------------------------------------------------------------
  # payzeno-api
  # -------------------------------------------------------------------------
  api_env = {
    NODE_ENV = "production"
    PORT     = "8080"

    LEDGER_BASE_URL         = "http://payzeno-ledger.production.payzeno.internal:8000"
    BILLING_LEGACY_BASE_URL = "http://payzeno-billing-legacy.production.payzeno.internal:8090"
    VAULT_BASE_URL          = "http://payzeno-vault.production.payzeno.internal:8099"
    VAULT_PUBLIC_URL        = local.vault_public_origin
    BILLING_LEGACY_USER     = "payzeno_api"

    WORLDFLOW_BASE_URL = "https://api.worldflow.com"
    NORDPAY_BASE_URL   = "https://gateway.nordpay.eu"

    SNS_PAYMENTS_TOPIC_ARN = module.topic_payments_events.topic_arn
    SNS_MERCHANT_TOPIC_ARN = module.topic_merchant_events.topic_arn

    SQS_LEDGER_QUEUE_URL          = module.q_api_ledger.queue_url
    SQS_API_WEBHOOKS_URL          = module.q_api_webhooks.queue_url
    SQS_CONSOLE_NOTIFICATIONS_URL = module.q_console_notifications.queue_url
    SQS_DLQ_URL                   = module.q_dlq_monitor.queue_url

    AWS_REGION = local.region

    # "database", not "redis". The Postgres claim is the durable one and the Redis lease is
    # an optimisation on top of it; production has never run with the cache as the authority.
    # Staging has said "redis" since month 10 and nobody moved it here — see the note in
    # envs/staging/stack.tf. That divergence means a staging pass proves less than it looks
    # like it does.
    IDEMPOTENCY_BACKEND       = "database"
    IDEMPOTENCY_TTL_HOURS     = "24"
    IDEMPOTENCY_LEASE_SECONDS = "30"

    RATE_LIMIT_DEFAULT_RPM     = "600"
    WEBHOOK_MAX_ATTEMPTS       = "8"
    WEBHOOK_RETRY_WINDOW_HOURS = "24"
    PROCESSOR_DEFAULT_ACQUIRER = "worldflow"
    REFUND_WINDOW_DAYS         = "120"
    CSRF_COOKIE_NAME           = "payzeno_csrf"

    # arc MIG. Step 1 (fees) flipped in month 3 and stayed. Step 4 (invoices) is still false
    # and will stay false until nginx/payzeno-internal.conf moves /internal/v1/invoices/ off
    # payzeno_legacy — the flag and the proxy_pass have to move together or the console reads
    # invoices from a service that does not have them.
    FLAG_LEDGER_OWNS_FEES     = "true"
    FLAG_LEDGER_OWNS_INVOICES = "false"

    # arc PCI, month 6. Added to api and ledger in one PR. Not removable.
    FLAG_REDACT_PAN_IN_LOGS = "true"

    LOG_LEVEL                   = "info"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.production.payzeno.internal:4318"
  }

  api_secrets = {
    DATABASE_URL            = module.db_api.database_url_secret_arn
    REDIS_URL               = module.cache_api_secret.secret_arns["REDIS_URL"]
    SESSION_SECRET          = module.platform_secrets.secret_arns["SESSION_SECRET"]
    API_KEY_PEPPER          = module.platform_secrets.secret_arns["API_KEY_PEPPER"]
    INTERNAL_API_SECRET     = module.platform_secrets.secret_arns["INTERNAL_API_SECRET"]
    VAULT_API_KEY           = module.platform_secrets.secret_arns["VAULT_API_KEY"]
    WORLDFLOW_API_KEY       = module.platform_secrets.secret_arns["WORLDFLOW_API_KEY"]
    NORDPAY_API_KEY         = module.platform_secrets.secret_arns["NORDPAY_API_KEY"]
    BILLING_LEGACY_PASSWORD = module.platform_secrets.secret_arns["BILLING_LEGACY_PASSWORD"]
    WEBHOOK_SIGNING_KEK     = aws_secretsmanager_secret.webhook_signing_kek.arn
  }

  # -------------------------------------------------------------------------
  # payzeno-ledger
  #
  # Shared by module.payzeno_ledger and module.payzeno_ledger_canary — the canary differs by
  # exactly one key, and keeping the base in one local is what makes that visible.
  # -------------------------------------------------------------------------
  ledger_env = {
    # 20, and it is not an arbitrary 20. modules/rds-postgres asserts
    # max_connections >= 3 x this value; see interfaces.md §3.1 rule 4 and the
    # client_pool_size input on module.db_ledger in data_stores.tf. If you raise this, raise
    # max_connections in the same PR or the precondition fails the plan — which is the point.
    DATABASE_POOL_SIZE         = "20"
    DATABASE_POOL_MAX_OVERFLOW = "10"

    SNS_LEDGER_TOPIC_ARN    = module.topic_ledger_events.topic_arn
    SQS_PAYMENTS_QUEUE_URL  = module.q_ledger_payments.queue_url
    SQS_MERCHANTS_QUEUE_URL = module.q_ledger_merchants.queue_url

    AWS_REGION = local.region

    WORLDFLOW_BASE_URL              = "https://api.worldflow.com"
    WORLDFLOW_BREAKER_THRESHOLD_PCT = "50"
    WORLDFLOW_BREAKER_WINDOW        = "60"
    WORLDFLOW_BREAKER_RESET_SECONDS = "30"

    NORDPAY_BASE_URL              = "https://gateway.nordpay.eu"
    NORDPAY_BREAKER_THRESHOLD_PCT = "50"
    NORDPAY_BREAKER_WINDOW        = "60"
    NORDPAY_BREAKER_RESET_SECONDS = "30"

    # 900s. The sweep and the 60s retry drain both process RETRYABLE_STATUSES, which is the
    # overlap PAY-2041 was about. Do not shorten either interval without reading
    # payzeno-ledger/docs/adr/0011-lock-ordering-in-the-money-path.md.
    RECONCILE_SWEEP_INTERVAL_SECONDS     = "900"
    RECONCILE_SWEEP_WALL_BUDGET_SECONDS  = "600"
    RECONCILE_MAX_ITEMS_PER_RUN          = "2000"
    RECONCILE_MAX_ATTEMPTS               = "6"
    RECONCILE_RETRY_BACKOFF_BASE_SECONDS = "15"

    RETRY_DRAIN_INTERVAL_SECONDS = "60"
    RETRY_DRAIN_BATCH_SIZE       = "200"

    # false on the main service. See module.payzeno_ledger_canary below, which is the one
    # place it is true, and which is why a 4,113-item backlog drained through a single task.
    RETRY_DRAIN_ENABLED = "false"

    PAYOUT_CUTOFF_ACH_UTC             = "21:00"
    PAYOUT_CUTOFF_SAME_DAY_ACH_UTC    = "14:45"
    PAYOUT_CUTOFF_SEPA_UTC            = "15:00"
    PAYOUT_CUTOFF_FASTER_PAYMENTS_UTC = "17:30"

    LEDGER_AUDIT_ENABLED        = "true"
    SETTLEMENT_IMPORT_ENABLED   = "true"
    FUNDING_MATCH_TOLERANCE_BPS = "5"

    FLAG_DUPLICATE_SETTLEMENT_ALARM = "true"
    FLAG_PAYOUT_SAME_DAY_ACH        = "false"
    FLAG_REDACT_PAN_IN_LOGS         = "true"

    LOG_LEVEL                   = "info"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.production.payzeno.internal:4318"
  }

  ledger_secrets = {
    DATABASE_URL        = module.db_ledger.database_url_secret_arn
    INTERNAL_API_SECRET = module.platform_secrets.secret_arns["INTERNAL_API_SECRET"]
    WORLDFLOW_API_KEY   = module.platform_secrets.secret_arns["WORLDFLOW_API_KEY"]
    NORDPAY_API_KEY     = module.platform_secrets.secret_arns["NORDPAY_API_KEY"]
  }
}

# ---------------------------------------------------------------------------
# payzeno-api
# ---------------------------------------------------------------------------

module "payzeno_api" {
  source = "../../modules/ecs-service"

  service        = "payzeno-api"
  environment    = local.environment
  image          = local.images.api
  container_port = 8080
  desired_count  = 4

  cpu    = 2048
  memory = 4096

  environment_vars = local.api_env
  secrets          = local.api_secrets

  vpc_id                = local.vpc_id
  subnet_ids            = local.subnet_ids
  cluster_arn           = aws_ecs_cluster.payzeno.arn
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb.id

  # 90, not 365. arc PCI, PAY-1761 — request logs are in scope.
  log_retention_days = 90

  autoscaling_min        = 4
  autoscaling_max        = 16
  autoscaling_target_cpu = 55

  pager_topic_arn  = aws_sns_topic.payzeno_pager.arn
  runbook_base_url = local.runbook_base_url
}

# ---------------------------------------------------------------------------
# payzeno-ledger
# ---------------------------------------------------------------------------

module "payzeno_ledger" {
  source = "../../modules/ecs-service"

  service        = "payzeno-ledger"
  environment    = local.environment
  image          = local.images.ledger
  container_port = 8000

  # 4 -> 1 at 01:44 on the night of PAY-2041 ("scale to one task now, argue later"), back to
  # 4 at 09:05 the same morning once the hotfix was out. Two commits, seven hours apart.
  desired_count = 4

  cpu    = 2048
  memory = 8192

  environment_vars = local.ledger_env
  secrets          = local.ledger_secrets

  vpc_id                = local.vpc_id
  subnet_ids            = local.subnet_ids
  cluster_arn           = aws_ecs_cluster.payzeno.arn
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb.id

  log_retention_days = 90

  # The ledger's load is a queue backlog, not a request rate, so CPU target tracking barely
  # moves it. See the TODO at the top of modules/ecs-service/main.tf — PAY-1912.
  autoscaling_min        = 4
  autoscaling_max        = 12
  autoscaling_target_cpu = 60

  pager_topic_arn  = aws_sns_topic.payzeno_pager.arn
  runbook_base_url = local.runbook_base_url
}

# FIXME(apager): staged rollout canary for the retry drain. One task only until we have the
# backoff work (PAY-1691). Delete this once the drain is on everywhere.
#
# Added month 5 under PAY-1688. PAY-1691 was never scheduled. On the night of PAY-2041 this
# comment was four months old, and this single task was the only thing in production with
# RETRY_DRAIN_ENABLED=true — which is why a 4,113-item backlog took 21 minutes to drain
# through one worker while three batch sweeps ran alongside it.
#
# Postmortem action item: delete this block. Not done yet; the drain is still not safe to
# run everywhere until PAY-2059 lands the backoff and the breaker.
module "payzeno_ledger_canary" {
  source = "../../modules/ecs-service"

  service        = "payzeno-ledger"
  component      = "canary"
  environment    = local.environment
  image          = local.images.ledger
  container_port = 8000
  desired_count  = 1

  cpu    = 2048
  memory = 8192

  environment_vars = merge(local.ledger_env, {
    RETRY_DRAIN_ENABLED = "true"
  })

  secrets = local.ledger_secrets

  vpc_id      = local.vpc_id
  subnet_ids  = local.subnet_ids
  cluster_arn = aws_ecs_cluster.payzeno.arn

  # No ALB. The canary exists to run the drain loop; nothing routes HTTP to it.
  alb_listener_arn     = null
  enable_nginx_sidecar = false

  log_retention_days = 90

  autoscaling_min        = 1
  autoscaling_max        = 1
  autoscaling_target_cpu = 80

  pager_topic_arn  = aws_sns_topic.payzeno_pager.arn
  runbook_base_url = local.runbook_base_url
}

# ---------------------------------------------------------------------------
# payzeno-billing-legacy
# ---------------------------------------------------------------------------

module "payzeno_billing_legacy" {
  source = "../../modules/ecs-service"

  service        = "payzeno-billing-legacy"
  environment    = local.environment
  image          = local.images.billing_legacy
  container_port = 8090
  desired_count  = 2

  cpu    = 1024
  memory = 4096

  environment_vars = {
    SPRING_PROFILES_ACTIVE = "production"

    # Read straight out of modules/rds-mysql's hand-built jdbc_url output. The query string
    # in that output (useSSL, serverTimezone=UTC) is how Hibernate interprets every timestamp
    # payzeno_billing has ever written — see the comment on the output itself.
    SPRING_DATASOURCE_URL      = module.db_billing.jdbc_url
    SPRING_DATASOURCE_USERNAME = "payzeno_billing"

    PAYZENO_LEDGER_BASE_URL = "http://payzeno-ledger.production.payzeno.internal:8000"
    PAYZENO_API_BASE_URL    = "http://payzeno-api.production.payzeno.internal:8080"

    BILLING_INVOICE_PREFIX        = "PZ"
    BILLING_DUNNING_ENABLED       = "true"
    BILLING_LEDGER_EXPORT_ENABLED = "true"

    # arc MIG, month 8. Added in the same commit as FLAG_LEDGER_OWNS_INVOICES on the api —
    # one ticket, two services, because a half-flipped strangler boundary means invoices
    # exist in two places and agree in neither.
    BILLING_FLAG_LEDGER_OWNS_INVOICES = "false"
    BILLING_FLAG_LEDGER_OWNS_FEES     = "true"

    LOG_LEVEL                   = "info"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.production.payzeno.internal:4318"
    AWS_REGION                  = local.region
  }

  secrets = {
    # SPRING_DATASOURCE_PASSWORD comes from the RDS-managed master credential rather than
    # from modules/secrets — rds-mysql predates that module and manages its own.
    SPRING_DATASOURCE_PASSWORD = module.db_billing.master_user_secret_arn
    PAYZENO_INTERNAL_SECRET    = module.platform_secrets.secret_arns["INTERNAL_API_SECRET"]
  }

  vpc_id                = local.vpc_id
  subnet_ids            = local.subnet_ids
  cluster_arn           = aws_ecs_cluster.payzeno.arn
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb.id

  # The legacy service is not PCI scope — it never sees a PAN — so on paper it could keep the
  # old 365-day retention. It does not: modules/ecs-service has a precondition capping
  # production at 90, and carving out an exception for one service is a worse trade than the
  # nine months of Flyway logs we lose. PAY-1761.
  log_retention_days = 90

  autoscaling_min        = 2
  autoscaling_max        = 4
  autoscaling_target_cpu = 70

  pager_topic_arn  = aws_sns_topic.payzeno_pager.arn
  runbook_base_url = local.runbook_base_url
}

# ---------------------------------------------------------------------------
# payzeno-vault — vendor card vault. Not ALB-fronted: the only public surface it has is the
# PAN entry iframe, which is served from vault.payzeno.com through its own distribution and
# not through our ALB. Everything else reaches it over service discovery.
# ---------------------------------------------------------------------------

module "payzeno_vault" {
