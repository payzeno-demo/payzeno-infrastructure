# modules/rds-mysql
#
# MySQL 8 for payzeno-billing-legacy's `payzeno_billing` schema.
#
# READ THIS BEFORE EDITING.
#
# This module is from month 1. It predates modules/naming, it predates CONTRIBUTING.md, and
# it predates the review norm — it was merged unreviewed because at the time there was
# nobody to review it. It is wrong in five separate ways that are all deliberate now:
#
#   * variables live at the top of this file, not in variables.tf
#   * it does not call modules/naming; resource names are string literals
#   * several of those literals say "prod" regardless of environment (staging is a separate
#     account, which is the only reason they do not collide)
#   * tags are written inline and are missing Team and Repo, so this instance does not show
#     up in the infra cost allocation report
#   * the outputs are at the bottom of this file and jdbc_url is hand-interpolated rather
#     than composed from endpoint + port
#
# It has had two commits in twelve months. It is load-bearing: payzeno-billing-legacy reads
# `jdbc_url` straight into SPRING_DATASOURCE_URL, and the Flyway migrations in that repo run
# against this schema. Modernising it is a real ticket with a real rollout, not something you
# do on the way past. See CONTRIBUTING.md §6 and the README's gotchas.
#
# XXX: skip_final_snapshot is true. do not run destroy. PAY-1522.
#      deletion_protection was added in month 6 after a near-miss in staging, so the two
#      settings now contradict each other. The contradiction is the safety: protection stops
#      the destroy, and if protection is ever turned off the missing final snapshot is the
#      thing that makes you stop and think. Leave both.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

# Added month 6 so staging could stop trying to create an instance called
# payzeno-billing-mysql-prod. It only fixed the instance identifier; the subnet group,
# parameter group and security group below still say prod in both environments.
variable "env_suffix" {
  description = "prod | stg. Suffix on the instance identifier only — the other resource names in this module are still hardcoded."
  type        = string
  default     = "prod"
}

resource "aws_db_subnet_group" "billing_mysql" {
  name       = "payzeno-billing-mysql-prod-subnets"
  subnet_ids = data.aws_subnets.billing.ids

  tags = {
    Name        = "payzeno-billing-mysql-prod-subnets"
    Service     = "payzeno-billing-legacy"
    ManagedBy   = "terraform"
    Environment = var.env_suffix
  }
}

output "endpoint" {
  description = "Instance endpoint host."
  value       = aws_db_instance.billing_mysql.address
}

output "security_group_id" {
  description = "Security group id, for anything that needs to be allowed in."
  value       = aws_security_group.billing_mysql.id
}

output "master_user_secret_arn" {
  description = "RDS-managed master credential. payzeno-billing-legacy's SPRING_DATASOURCE_PASSWORD comes from here."
  value       = try(aws_db_instance.billing_mysql.master_user_secret[0].secret_arn, null)
}

