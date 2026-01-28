# modules/rds-postgres
#
# Postgres 15 instance + parameter group + subnet group + credentials secret + two alarms.
# Used twice in each environment: module.db_api (payzeno_api) and module.db_ledger
# (payzeno_ledger). Two databases, two instances, no shared server — the ledger is the
# system of record for money and it does not share a connection budget with the API's
# session store.
#
# The parameter group did not exist before month 7. mregression added it during arc PERF
# (PAY-1744) because there was no way to find the slow settlement query without
# pg_stat_statements, and the answer to "why is the sweep taking 40 minutes" was going to be
# guessed otherwise. It is the single most useful eleven lines in this module.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

module "names" {
  source = "../naming"

  service     = var.service
  environment = var.environment
  component   = "db"
  extra_tags  = var.extra_tags
}

module "credentials" {
  source = "../secrets"

  service      = var.service
  environment  = var.environment
  purpose      = "db"
  secret_names = ["DATABASE_URL", "DATABASE_PASSWORD"]

  # Rotating DATABASE_URL means rotating the password inside it, and the rotation lambda
  # has to do both together or the URL goes stale. It does. 90 days.
  rotation_days = var.rotation_days
  extra_tags    = var.extra_tags
}

locals {
  identifier = module.names.id

  # Sensible-for-Payzeno defaults, then whatever the caller overrides. Ordering matters:
  # var.parameters wins, so a caller can raise work_mem for the ledger without forking the
  # module.
  base_parameters = {
    # arc PERF, PAY-1744. Without this there is no query-level visibility at all and the
    # only tool left is EXPLAIN on a query you already suspect.
