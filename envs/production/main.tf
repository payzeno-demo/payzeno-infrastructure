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

# CloudFront certificates are read from us-east-1 and nowhere else.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

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

locals {
  environment = "production"
  region      = "eu-west-1"

  # The three console/API hostnames. api.payzeno.com is the only public ingress for the
  # platform API; console.payzeno.com is the SPA; vault.payzeno.com is the card iframe origin
  # and is deliberately a different host so the console's CSP can name it.
  api_domain     = "api.payzeno.com"
  console_domain = "console.payzeno.com"
  vault_domain   = "vault.payzeno.com"

  api_origin          = "https://${local.api_domain}"
  vault_public_origin = "https://${local.vault_domain}"

  # Image tags. Moved by the deploy pipeline, not by terraform — aws_ecs_service ignores
  # task_definition changes for exactly this reason. These are the values terraform will
  # write on a fresh create, and they go stale between applies. That is expected; if you are
  # reading a tag here to find out what is running, read the ECS console instead.
  image_registry = "418355290117.dkr.ecr.eu-west-1.amazonaws.com"

  images = {
    api            = "${local.image_registry}/payzeno-api:sha-9f41ac2"
    ledger         = "${local.image_registry}/payzeno-ledger:sha-c07be13"
    billing_legacy = "${local.image_registry}/payzeno-billing-legacy:sha-4d2119e"
    vault          = "payzeno/card-vault:2.3"
  }

  runbook_base_url = "https://github.com/payzeno/payzeno-infrastructure/blob/main/docs/runbooks"

  account_id = data.aws_caller_identity.current.account_id
  vpc_id     = data.aws_vpc.payzeno.id
  subnet_ids = data.aws_subnets.private.ids
  acm_arn    = data.aws_acm_certificate.payzeno.arn
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "payzeno" {
  filter {
    name   = "tag:Name"
    values = ["payzeno-vpc"]
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

# Regional certificate, for the ALB.
data "aws_acm_certificate" "payzeno" {
  domain      = "*.payzeno.com"
  statuses    = ["ISSUED"]
  most_recent = true
}

# The same wildcard, issued again in us-east-1 for CloudFront. Two certificates, one name;
# this trips someone up roughly once a year.
data "aws_acm_certificate" "payzeno_cloudfront" {
  provider = aws.us_east_1

  domain      = "*.payzeno.com"
  statuses    = ["ISSUED"]
  most_recent = true
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

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

resource "aws_ecs_cluster_capacity_providers" "payzeno" {
  cluster_name = aws_ecs_cluster.payzeno.name

  capacity_providers = ["FARGATE"]

  # No FARGATE_SPOT in production. A reclaimed task in the middle of a settlement batch is
  # a reconciliation_item stuck in `settling` and a human reading a runbook at 02:00.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "production.payzeno.internal"
  description = "Service discovery for payzeno-production. The first DNS label equals the docker-compose service name."
  vpc         = local.vpc_id

  tags = {
    Name = "production.payzeno.internal"
  }
}

# ---------------------------------------------------------------------------
# RDS enhanced monitoring role. One per account, shared by both Postgres instances.
# ---------------------------------------------------------------------------

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
  name               = "payzeno-production-rds-monitoring"
  description        = "Enhanced monitoring for the production Postgres instances"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------------------------------------------------------
# Shared config bucket. modules/nginx-sidecar writes the rendered nginx config here and the
# task execution roles read it back at start.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "service_config" {
  bucket = "payzeno-production-service-config-${local.account_id}"

  tags = {
    Name = "payzeno-production-service-config"
  }
}

resource "aws_s3_bucket_public_access_block" "service_config" {
  bucket = aws_s3_bucket.service_config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "service_config" {
  bucket = aws_s3_bucket.service_config.id

  # An nginx config change takes effect on the next task start, which can be hours later.
  # Versioning is how you find out what the sidecar was actually running at the time.
  versioning_configuration {
    status = "Enabled"
  }
}

output "cluster_arn" {
  description = "ECS cluster ARN. Handy in the runbook — every aws ecs command wants it."
  value       = aws_ecs_cluster.payzeno.arn
}

output "account_id" {
  description = "Account this root deploys into."
  value       = local.account_id
}
