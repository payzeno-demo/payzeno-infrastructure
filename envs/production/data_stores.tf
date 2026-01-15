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
