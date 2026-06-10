# envs/production/data_stores.tf
#
# Two Postgres instances, one MySQL, one Redis, and the platform secrets.
#
# Note on the security-group wiring below: the databases do NOT take the service security
# groups as an input, even though that is what you would write first. modules/ecs-service
# consumes module.db_*.database_url_secret_arn, so a database module that consumed
# module.payzeno_*.security_group_id would be a module cycle. The ingress rules are declared
# here instead, at resource level, where the dependency is one-directional and terraform is
# happy. It looks like a workaround because it is one.

module "db_api" {
  source = "../../modules/rds-postgres"

  service       = "payzeno-api"
  environment   = local.environment
  database_name = "payzeno_api"

  instance_class        = "db.r6g.large"
  allocated_storage     = 200
  max_allocated_storage = 800
  multi_az              = true

  # The api runs a smaller pool than the ledger — its work is request-shaped, not
  # batch-shaped. 3 x 10 x 4 tasks, plus migrations and headroom.
  client_pool_size = 10
  max_connections  = 200

  performance_insights_enabled = true

  backup_retention_days = 21
  vpc_id                = local.vpc_id
  subnet_ids            = local.subnet_ids
  monitoring_role_arn   = aws_iam_role.rds_monitoring.arn

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

module "db_ledger" {
  source = "../../modules/rds-postgres"

  service       = "payzeno-ledger"
  environment   = local.environment
  database_name = "payzeno_ledger"

  # db.r6g.large -> db.r6g.xlarge in month 7, arc PERF (PAY-1744). The settlement query was
  # not slow because of the plan, it was slow because the instance had nothing left. The
  # first attempt at this change forgot apply_immediately and sat pending for six days while
  # everyone assumed it had landed — PAY-1746, and the reason apply_immediately is explicit
  # here rather than defaulted.
  instance_class        = "db.r6g.xlarge"
  allocated_storage     = 500
  max_allocated_storage = 2000
  multi_az              = true
  apply_immediately     = true

  # DATABASE_POOL_SIZE = 20 (interfaces.md §7). Four tasks hold a full pool each, the sweep
  # and the drain each hold one on top of that, alembic takes two during a deploy, and there
  # is usually a human in psql. 3x the pool is the floor, not the target — see
  # interfaces.md §3.1 rule 4 and modules/rds-postgres/variables.tf.
  client_pool_size = 20
  max_connections  = 400

  performance_insights_enabled        = true
  performance_insights_retention_days = 731

  # pg_stat_statements is in the module defaults. These two are ledger-specific: the
  # settlement import writes in large batches and the default work_mem spills the sort to
  # disk, and a lock wait longer than a minute in the money path is a bug, not congestion.
  parameters = {
    work_mem                              = "32768"
    "idle_in_transaction_session_timeout" = "30000"
    lock_timeout                          = "60000"
  }

  backup_retention_days = 35
  vpc_id                = local.vpc_id
  subnet_ids            = local.subnet_ids
  monitoring_role_arn   = aws_iam_role.rds_monitoring.arn

  # Retuned after PAY-2041. It was 0.9 of max_connections, which meant the alarm fired after
  # the application had already started failing to check out connections. 0.75 gives the
  # on-call the ten minutes the old threshold did not.
  connections_alarm_fraction = 0.75
  cpu_alarm_threshold        = 75

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

# The legacy biller's MySQL. Pre-convention module; see modules/rds-mysql/main.tf before you
# touch anything here. It takes three inputs and hardcodes everything else, including some
# resource names that say "prod" in both environments.
#
# do not delete until MIG step 5 — PAY-1522
module "db_billing" {
  source = "../../modules/rds-mysql"

  database_name  = "payzeno_billing"
  instance_class = "db.r6g.large"
  env_suffix     = "prod"
}

# ---------------------------------------------------------------------------
# Redis. Raw resources — there is one of these in the whole platform and a module for it
# would have exactly one caller.
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "cache_api" {
  name       = "payzeno-api-production-cache"
  subnet_ids = local.subnet_ids
}

resource "aws_security_group" "cache_api" {
  name        = "payzeno-api-production-cache-sg"
  description = "Redis for payzeno-api (idempotency + rate limiting)"
  vpc_id      = local.vpc_id

  tags = {
    Name    = "payzeno-api-production-cache-sg"
    Service = "payzeno-api"
  }
}

resource "aws_elasticache_replication_group" "cache_api" {
  replication_group_id = "payzeno-api-production"
  description          = "payzeno-api idempotency store and rate-limit counters"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = "cache.m6g.large"
  port           = 6379

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.cache_api.name
  security_group_ids = [aws_security_group.cache_api.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  # IDEMPOTENCY_BACKEND=redis means an idempotency lease lives here. Losing the cache loses
  # in-flight leases, which is survivable (the api falls back to the database claim) but is
  # not free — snapshots make a failover boring.
  snapshot_retention_limit = 3
  snapshot_window          = "03:00-04:00"
  maintenance_window       = "sun:04:30-sun:05:30"

  apply_immediately = false
