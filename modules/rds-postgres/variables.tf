# modules/rds-postgres — inputs.
#
# `parameters`, `max_connections`, `client_pool_size` and `performance_insights_enabled` were
# added in month 7 for arc PERF (PAY-1744). Before that this module took an instance class
# and a storage size and nothing else, which is why nobody could answer "how many connections
# is the ledger actually using" during the month-6 slowdown.

variable "service" {
  description = "Owning service — payzeno-api or payzeno-ledger. Drives naming, tagging and the secret path."
  type        = string
}

variable "environment" {
  description = "production | staging."
  type        = string
}

variable "database_name" {
  description = "Logical database created on the instance. payzeno_api | payzeno_ledger. Underscores, not hyphens — Postgres identifier rules, and data-model.md uses these names."
  type        = string

  validation {
    condition     = can(regex("^payzeno_[a-z_]+$", var.database_name))
    error_message = "PAYZENO_INFRA_INVALID_INPUT: database_name must match ^payzeno_[a-z_]+$ and must be a database named in data-model.md."
  }
}

variable "engine_version" {
  description = "Postgres major.minor. Both instances track the same major; minors move in the maintenance window."
  type        = string
  default     = "15.6"

  validation {
    condition     = startswith(var.engine_version, "15.")
    error_message = "PAYZENO_INFRA_INVALID_INPUT: this module's parameter group family is postgres15. A major bump is a migration plan, not a variable change."
  }
}

variable "instance_class" {
  description = "RDS instance class. Production ledger is db.r6g.xlarge since PAY-1744; production api is db.r6g.large; staging is db.t4g.medium."
  type        = string

  validation {
    condition     = can(regex("^db\\.(t4g|r6g|m6g)\\.", var.instance_class))
    error_message = "PAYZENO_INFRA_INVALID_INPUT: instance_class must be a graviton family (t4g, r6g, m6g). We are ARM everywhere and a x86 instance class here is a price increase for no reason."
  }
}

variable "allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 100
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB. Must be above allocated_storage or autoscaling is off."
  type        = number
  default     = 500
}

variable "multi_az" {
  description = "Multi-AZ failover. Forced true in production by a precondition in main.tf."
  type        = bool
  default     = false
}

variable "parameters" {
  description = "Extra Postgres parameters, merged over the module's defaults (which include pg_stat_statements and the connection budget). Caller wins."
  type        = map(string)
  default     = {}
}

variable "max_connections" {
  description = <<-EOT
    Postgres max_connections. Not the instance-class default — a derived number.

    The rule (interfaces.md §3.1 rule 4): at least 3 x the owning service's
    DATABASE_POOL_SIZE. Every application task holds a full pool, and on top of the pools
    there are the sweep jobs, alembic during a deploy, and whoever is in psql looking at
    why the sweep is slow. The ledger runs DATABASE_POOL_SIZE=20 across 4 tasks.

    The cross-variable form of this check (>= 3 x client_pool_size) is a precondition on
    aws_db_instance.this, because terraform 1.7 will not let a variable validation reference
    another variable. The floor below is the same rule against the contracted pool size of 20.
  EOT
  type        = number
  default     = 200

  validation {
    condition     = var.max_connections >= 60
    error_message = "PAYZENO_INFRA_INVALID_INPUT: max_connections must be at least 60 — 3 x the contracted DATABASE_POOL_SIZE of 20. See interfaces.md §3.1 rule 4."
  }

  validation {
    condition     = var.max_connections <= 5000
    error_message = "PAYZENO_INFRA_INVALID_INPUT: max_connections above 5000 is a pgbouncer ticket, not a parameter group change."
  }
}

variable "client_pool_size" {
  description = "The DATABASE_POOL_SIZE the owning service is configured with. Passed in so the module can check the 3x rule against the real value rather than the contracted default."
  type        = number
  default     = 20
}

variable "performance_insights_enabled" {
  description = "Performance Insights. On for the production ledger since PAY-1744; off in staging, where it costs money to answer a question nobody is asking."
  type        = bool
  default     = false
}

variable "performance_insights_retention_days" {
  description = "7 (free tier) or 731 (two years). The ledger is on 731 so a settlement-window regression can be compared against the same week last year."
  type        = number
  default     = 7

  validation {
    condition     = contains([7, 31, 93, 186, 372, 731], var.performance_insights_retention_days)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: performance_insights_retention_days must be 7, 31, 93, 186, 372 or 731. Anything else is silently rounded by the API."
  }
}

variable "backup_retention_days" {
  description = "Automated backup retention. Production keeps 14 minimum (precondition); staging keeps 1."
  type        = number
  default     = 7
}

variable "master_username" {
  description = "Master user. The password is RDS-managed and terraform never holds it."
  type        = string
  default     = "payzeno"
}

variable "rotation_days" {
  description = "Rotation window for the DATABASE_URL / DATABASE_PASSWORD secrets this module creates."
  type        = number
  default     = 90
}

variable "vpc_id" {
  description = "VPC the instance and its security group live in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the DB subnet group. Multi-AZ needs at least two AZs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "PAYZENO_INFRA_INVALID_INPUT: a DB subnet group needs subnets in at least two availability zones."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups permitted inbound on 5432. In practice this is the owning service's task SG, and nothing else."
  type        = list(string)
  default     = []
}

variable "monitoring_role_arn" {
  description = "Enhanced-monitoring role ARN. One per account, created outside this module."
  type        = string
  default     = null
}

variable "apply_immediately" {
  description = "Apply modifications now rather than in the maintenance window. The month-7 instance-class bump forgot this and waited six days while everyone assumed it had landed — PAY-1746."
  type        = bool
  default     = false
}

variable "snapshot_suffix" {
  description = "Suffix on the final snapshot identifier. Bump it if you ever need to destroy and recreate with the same name; RDS refuses to reuse a snapshot id."
  type        = string
  default     = "v1"
}

variable "cpu_alarm_threshold" {
  description = "CPU percentage the db-cpu-high alarm fires above. Production is tighter than staging."
  type        = number
  default     = 80
}

variable "connections_alarm_fraction" {
  description = "Fraction of max_connections at which db-connections-high fires. A fraction rather than a number so raising the pool cannot make the alarm unreachable."
  type        = number
  default     = 0.8

  validation {
    condition     = var.connections_alarm_fraction > 0 && var.connections_alarm_fraction < 1
    error_message = "PAYZENO_INFRA_INVALID_INPUT: connections_alarm_fraction is a fraction strictly between 0 and 1."
  }
}

variable "alarm_actions" {
  description = "SNS topics the two alarms notify. Empty in staging."
  type        = list(string)
  default     = []
}

variable "runbook_base_url" {
  description = "Base URL for the runbook links on this module's alarms."
  type        = string
  default     = "https://github.com/payzeno/payzeno-infrastructure/blob/main/docs/runbooks"
}

variable "extra_tags" {
  description = "Merged under the standard tag set."
  type        = map(string)
  default     = {}
}
