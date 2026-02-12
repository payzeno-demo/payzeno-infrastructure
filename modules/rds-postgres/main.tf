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
    shared_preload_libraries = "pg_stat_statements"

    "pg_stat_statements.track"            = "all"
    "pg_stat_statements.max"              = "10000"
    "pg_stat_statements.save"             = "on"
    "log_min_duration_statement"          = "500"
    "log_lock_waits"                      = "1"
    "deadlock_timeout"                    = "1000"
    "idle_in_transaction_session_timeout" = "60000"

    # max_connections is not "whatever the instance class defaults to". It is
    # 3 x the application's pool size, per service, plus headroom for the sweep jobs,
    # migrations and a human with psql. See the precondition below and interfaces.md §3.1
    # rule 4 — the ledger runs DATABASE_POOL_SIZE=20 and every task holds a full pool.
    max_connections = tostring(var.max_connections)
  }

  parameters = merge(local.base_parameters, var.parameters)

  # A parameter group change is only static-safe for some parameters; shared_preload_libraries
  # needs a reboot. Marking it pending-reboot rather than immediate is what stops an apply
  # from bouncing the ledger's database in the middle of a settlement window.
  static_parameters = ["shared_preload_libraries", "max_connections"]
}

resource "aws_db_subnet_group" "this" {
  name        = "${local.identifier}-subnets"
  description = "Private subnets for ${var.service}'s Postgres instance in ${var.environment}"
  subnet_ids  = var.subnet_ids

  tags = merge(module.names.tags, {
    Name = "${local.identifier}-subnets"
  })
}

resource "aws_security_group" "this" {
  name        = "${local.identifier}-sg"
  description = "Postgres for ${var.service} (${var.environment})"
  vpc_id      = var.vpc_id

  tags = merge(module.names.tags, {
    Name = "${local.identifier}-sg"
  })
}

# Only the owning service's tasks. Not the VPC CIDR, not the bastion by default — if you
# need psql, assume the role and use the session-manager tunnel; the runbook has the command.
resource "aws_vpc_security_group_ingress_rule" "from_service" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Postgres from ${each.value}"
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
