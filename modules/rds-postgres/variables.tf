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

variable "allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 100
}

variable "parameters" {
  description = "Extra Postgres parameters, merged over the module's defaults (which include pg_stat_statements and the connection budget). Caller wins."
  type        = map(string)
  default     = {}
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

variable "vpc_id" {
  description = "VPC the instance and its security group live in."
  type        = string
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
