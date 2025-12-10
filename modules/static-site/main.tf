# modules/static-site
#
# S3 + CloudFront + origin access control for payzeno-console. The console is a Vite SPA;
# there is no server, so "deploying" it is a sync to a bucket and an invalidation.
#
# Two commits in twelve months. It was right the first time and the console team has never
# needed anything from it except the cache headers, which tflexbox added in month 5.
#
# The bucket is private. Everything goes through CloudFront via OAC — no website endpoint, no
# public bucket policy. That is not paranoia: a public bucket serving a SPA means the SPA is
# also reachable without the CSP and HSTS headers the distribution attaches, and a merchant
# console that can be framed is a merchant console that can be clickjacked.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

module "names" {
  source = "../naming"

  service     = var.service
  environment = var.environment
  component   = "site"
  extra_tags  = var.extra_tags
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name

  tags = merge(module.names.tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  # A bad console deploy is rolled back by re-syncing the previous build, but versioning is
  # what makes "what exactly was live at 01:40" answerable.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-old-builds"
    status = "Enabled"

    filter {
      prefix = "assets/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

output "distribution_domain_name" {
  description = "The *.cloudfront.net domain. The Route53 alias for var.domain_name points here."
  value       = aws_cloudfront_distribution.this.domain_name
}

