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

