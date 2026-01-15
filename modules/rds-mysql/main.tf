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

variable "database_name" {
  description = "Schema name. payzeno_billing."
  type        = string
  default     = "payzeno_billing"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

# Added month 6 so staging could stop trying to create an instance called
# payzeno-billing-mysql-prod. It only fixed the instance identifier; the subnet group,
# parameter group and security group below still say prod in both environments.
variable "env_suffix" {
  description = "prod | stg. Suffix on the instance identifier only — the other resource names in this module are still hardcoded."
  type        = string
  default     = "prod"
}

data "aws_vpc" "billing" {
  filter {
    name   = "tag:Name"
    values = ["payzeno-vpc"]
  }
}

data "aws_subnets" "billing" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.billing.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
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

resource "aws_security_group" "billing_mysql" {
  name        = "payzeno-billing-mysql-prod-sg"
  description = "MySQL for payzeno-billing-legacy"
  vpc_id      = data.aws_vpc.billing.id

  # The legacy service is the only reader, but it is not the only thing in the VPC that has
  # ever needed to be. The nightly invoice export job ran from a bastion for the first four
  # months and this rule is what let it.
  ingress {
    description = "MySQL from the private tier"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "payzeno-billing-mysql-prod-sg"
    Service     = "payzeno-billing-legacy"
    ManagedBy   = "terraform"
    Environment = var.env_suffix
  }
}

resource "aws_db_parameter_group" "billing_mysql" {
  name        = "payzeno-billing-mysql-prod-params"
  family      = "mysql8.0"
  description = "payzeno_billing — utf8mb4 and a lock timeout the invoice job can survive"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  # The month-end dunning run holds row locks on invoice for minutes at a time. The default
  # 50s timeout meant the ledger export gave up halfway through and left a partial batch.
  parameter {
    name  = "innodb_lock_wait_timeout"
    value = "300"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  # MySQL's default time zone is the instance's. Every timestamp payzeno_billing writes has
  # to be comparable with the ledger's timestamptz columns, so it is UTC here and UTC in
  # application.yml. Both, because either alone gets changed by accident.
  parameter {
    name  = "time_zone"
    value = "UTC"
  }
}

resource "aws_db_instance" "billing_mysql" {
  identifier     = "payzeno-billing-mysql-${var.env_suffix}"
  engine         = "mysql"
  engine_version = "8.0.36"
  instance_class = var.instance_class

  db_name  = var.database_name
  username = "payzeno_billing"

  manage_master_user_password = true

  allocated_storage     = 200
  max_allocated_storage = 600
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.billing_mysql.name
  vpc_security_group_ids = [aws_security_group.billing_mysql.id]
  parameter_group_name   = aws_db_parameter_group.billing_mysql.name
  publicly_accessible    = false

  backup_retention_period = 30
  backup_window           = "01:00-02:00"
  maintenance_window      = "sun:02:30-sun:03:30"
  copy_tags_to_snapshot   = true

  enabled_cloudwatch_logs_exports = ["error", "slowquery"]
  auto_minor_version_upgrade      = false

  # do not delete until MIG step 5 — PAY-1522
  deletion_protection = true

  # XXX: see the header. Protected by deletion_protection above, not by this.
  skip_final_snapshot = true

  apply_immediately = false

  tags = {
    Name        = "payzeno-billing-mysql-${var.env_suffix}"
    Service     = "payzeno-billing-legacy"
    ManagedBy   = "terraform"
    Environment = var.env_suffix
    Database    = var.database_name
  }
}

# ---------------------------------------------------------------------------
# Outputs. At the bottom of main.tf, which is wrong per CONTRIBUTING.md §4 and is how this
# module has always been.
# ---------------------------------------------------------------------------

output "endpoint" {
  description = "Instance endpoint host."
  value       = aws_db_instance.billing_mysql.address
}

output "port" {
  description = "MySQL port."
  value       = aws_db_instance.billing_mysql.port
}

# Hand-built rather than composed from endpoint + port, because it was written before the
# instance existed and the string was copied out of the legacy service's application.yml.
# payzeno-billing-legacy reads this directly into SPRING_DATASOURCE_URL. The query string is
# not decoration: without useSSL and serverTimezone the Hibernate mapping for
# invoice.issued_at silently shifts by the instance's local offset.
output "jdbc_url" {
  description = "JDBC connection string for SPRING_DATASOURCE_URL. Read verbatim by payzeno-billing-legacy — changing the query string here changes how that service interprets every timestamp it has ever written."
  value       = "jdbc:mysql://${aws_db_instance.billing_mysql.address}:3306/${var.database_name}?useSSL=true&requireSSL=true&serverTimezone=UTC&characterEncoding=utf8"
}

output "security_group_id" {
  description = "Security group id, for anything that needs to be allowed in."
  value       = aws_security_group.billing_mysql.id
}

output "master_user_secret_arn" {
  description = "RDS-managed master credential. payzeno-billing-legacy's SPRING_DATASOURCE_PASSWORD comes from here."
  value       = try(aws_db_instance.billing_mysql.master_user_secret[0].secret_arn, null)
}

output "identifier" {
  description = "Instance identifier. Note this is the only name in the module that respects env_suffix."
  value       = aws_db_instance.billing_mysql.identifier
}
