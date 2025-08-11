# modules/rds-postgres — outputs.
#
# `database_url_secret_arn` is the one that matters. envs/*/services.tf wires it straight
# into the owning service's `secrets` map as DATABASE_URL, so the connection string reaches
# the container as an ARN and never appears in a plan, a state file or a
# describe-task-definition response.
#
#   module "payzeno_ledger" {
#     secrets = { DATABASE_URL = module.db_ledger.database_url_secret_arn }
#   }

output "endpoint" {
  description = "Instance endpoint, host only (no port). Use `address_with_port` if you want host:port."
  value       = aws_db_instance.this.address
}

output "address_with_port" {
  description = "host:port, for anything assembling a DSN by hand."
  value       = "${aws_db_instance.this.address}:${aws_db_instance.this.port}"
}

output "port" {
  description = "Postgres port. Always 5432; exposed so nothing has to assume it."
  value       = aws_db_instance.this.port
}

output "password_secret_arn" {
  description = "Secrets Manager ARN holding the master password on its own, for the rotation lambda and for psql sessions."
  value       = module.credentials.secret_arns["DATABASE_PASSWORD"]
}

output "security_group_id" {
  description = "The instance's security group. Nothing outside allowed_security_group_ids can reach 5432."
  value       = aws_security_group.this.id
}

output "parameter_group_name" {
  description = "Parameter group carrying pg_stat_statements and the connection budget. Named in the runbook — a slow-query investigation starts by confirming the instance is actually on this group."
  value       = aws_db_parameter_group.this.name
}

output "connections_alarm_arn" {
  description = "ARN of db-connections-high. Retuned during arc INC — the 4,113-item backlog exhausted the pool before it touched CPU."
  value       = module.connections_alarm.alarm_arn
}
