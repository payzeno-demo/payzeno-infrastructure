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

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

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

locals {
  environment = "staging"
  region      = "eu-west-1"

  api_domain     = "api.staging.payzeno.com"
  console_domain = "console.staging.payzeno.com"
  vault_domain   = "vault.staging.payzeno.com"

  api_origin          = "https://${local.api_domain}"
  vault_public_origin = "https://${local.vault_domain}"

  image_registry = "418355290117.dkr.ecr.eu-west-1.amazonaws.com"

  # STALE (1/3): these tags are older than production's. Staging is deployed from the same
  # pipeline but only on merge to main, and the values terraform holds go stale between
  # applies for the same reason production's do — aws_ecs_service ignores task_definition.
  # Reading a tag here to find out what is deployed will mislead you.
  images = {
    api            = "${local.image_registry}/payzeno-api:sha-71c3d80"
    ledger         = "${local.image_registry}/payzeno-ledger:sha-a49ef65"
    billing_legacy = "${local.image_registry}/payzeno-billing-legacy:sha-4d2119e"
    vault          = "payzeno/card-vault:2.3"
  }

  # STALE (2/3): production moved to a per-environment runbook anchor set in month 9 when
  # alarms_ledger.tf landed. Staging has no alarms, so nothing here reads this and nobody
  # noticed it still points at the repo root.
  runbook_base_url = "https://github.com/payzeno/payzeno-infrastructure/blob/main/docs"

  # The acquirer sandboxes. Production talks to the real acquirers; staging talks to the
  # same sandbox endpoints the local compose stack fakes.
  worldflow_base_url = "https://sandbox.worldflow.com"
  nordpay_base_url   = "https://sandbox.nordpay.eu"

  account_id = data.aws_caller_identity.current.account_id
  vpc_id     = data.aws_vpc.payzeno.id
  subnet_ids = data.aws_subnets.private.ids
  acm_arn    = data.aws_acm_certificate.payzeno.arn
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

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.payzeno.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["public"]
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

resource "aws_ecs_cluster" "payzeno" {
  name = "payzeno-staging"

  # STALE (3/3): production turned Container Insights on in month 6 when we started paying
  # for the metrics that make the ECS alarms meaningful. Staging never did, because staging
  # has no alarms. It also means task-level memory numbers are not available here, which is
  # occasionally exactly what you came to staging to find out.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = "payzeno-staging"
  }
}

resource "aws_ecs_cluster_capacity_providers" "payzeno" {
  cluster_name = aws_ecs_cluster.payzeno.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Spot in staging. A reclaimed task here is a restarted task and nothing more, and it is
  # roughly a third of the cost. Production is FARGATE only, deliberately.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
    base              = 0
  }
}

resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "staging.payzeno.internal"
  description = "Service discovery for payzeno-staging."
  vpc         = local.vpc_id

  tags = {
    Name = "staging.payzeno.internal"
  }
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

resource "aws_iam_role" "rds_monitoring" {
  name               = "payzeno-staging-rds-monitoring"
  description        = "Enhanced monitoring for the staging Postgres instances"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_s3_bucket" "service_config" {
  bucket = "payzeno-staging-service-config-${local.account_id}"

  tags = {
    Name = "payzeno-staging-service-config"
  }
}

resource "aws_s3_bucket_public_access_block" "service_config" {
  bucket = aws_s3_bucket.service_config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "cluster_arn" {
  description = "Staging ECS cluster ARN."
  value       = aws_ecs_cluster.payzeno.arn
}
