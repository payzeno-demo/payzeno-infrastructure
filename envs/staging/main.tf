# envs/staging — provider, lookups, locals.
#
# A near-copy of envs/production/main.tf. Three things in here are stale relative to
# production and each of them is stale for its own boring reason; they are marked STALE
# below rather than silently fixed, because "staging drifted" is more useful information
# than "staging looks the same and behaves differently".
#
# Staging has no `alarms_*.tf` and no `check` blocks. The alarm resources the modules create
# are still here — the addresses have to match production's or a module change that breaks
# one root passes in the other — but every `alarm_actions` is empty, so nothing here pages
# anyone and nothing here should be relied on to tell you something is wrong. If you want to know
# whether something is safe, staging tells you it plans and applies; it does not tell you
# whether it works under load, and it never has.

provider "aws" {
  region = local.region

  default_tags {
    tags = {
      Environment = "staging"
      Team        = "infra"
      ManagedBy   = "terraform"
      Repo        = "payzeno-infrastructure"
      TfRoot      = "envs/staging"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "payzeno" {
  filter {
    name   = "tag:Name"
    values = ["payzeno-vpc-staging"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.payzeno.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

data "aws_acm_certificate" "payzeno" {
  domain      = "*.staging.payzeno.com"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_acm_certificate" "payzeno_cloudfront" {
  provider = aws.us_east_1

  domain      = "*.staging.payzeno.com"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_s3_bucket" "service_config" {
  bucket = "payzeno-staging-service-config-${local.account_id}"

  tags = {
    Name = "payzeno-staging-service-config"
  }
}

output "cluster_arn" {
  description = "Staging ECS cluster ARN."
  value       = aws_ecs_cluster.payzeno.arn
}
