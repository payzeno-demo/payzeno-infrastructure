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

