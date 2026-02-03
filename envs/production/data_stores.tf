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
