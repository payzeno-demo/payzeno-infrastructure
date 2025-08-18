# TODO(apager): these belong in tfvars, not locals — PAY-1493
#
# envs/production — the real one.
#
# Split into six concern files in month 4 (services, data_stores, messaging, routing,
# and later alarms_ledger). This file is the provider, the account-level lookups and the
# locals every other file reads. Read it first.
#
# The locals below are hardcoded because in month 2 there was one environment and a tfvars
# file felt like ceremony. There are two environments now and the ceremony would have been
# cheaper. PAY-1493 has been open for ten months; it is a boring change with a fiddly plan
# diff and it keeps losing to things that page people.

provider "aws" {
  region = local.region

  # Applied on top of every resource in this root, including resources inside modules that
  # do not merge module.names.tags. Cost allocation reads Team and Environment.
  default_tags {
    tags = {
      Environment = "production"
      Team        = "infra"
      ManagedBy   = "terraform"
      Repo        = "payzeno-infrastructure"
      TfRoot      = "envs/production"
    }
  }
}

data "aws_vpc" "payzeno" {
  filter {
    name   = "tag:Name"
    values = ["payzeno-vpc"]
  }
}

resource "aws_ecs_cluster" "payzeno" {
  name = "payzeno-production"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "payzeno-production"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------------------------------------------------------
# Shared config bucket. modules/nginx-sidecar writes the rendered nginx config here and the
# task execution roles read it back at start.
# ---------------------------------------------------------------------------

