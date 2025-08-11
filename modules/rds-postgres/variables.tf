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

variable "parameters" {
  description = "Extra Postgres parameters, merged over the module's defaults (which include pg_stat_statements and the connection budget). Caller wins."
  type        = map(string)
  default     = {}
}

variable "allowed_security_group_ids" {
  description = "Security groups permitted inbound on 5432. In practice this is the owning service's task SG, and nothing else."
  type        = list(string)
  default     = []
}

variable "extra_tags" {
  description = "Merged under the standard tag set."
  type        = map(string)
  default     = {}
}
