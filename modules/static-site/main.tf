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

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  # A bad console deploy is rolled back by re-syncing the previous build, but versioning is
  # what makes "what exactly was live at 01:40" answerable.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
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

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

# Added month 5 by tflexbox, tightened in the PCI wave. The CSP allows the API origin and the
# vault's public origin (the card iframe posts to it) and nothing else. frame-ancestors 'none'
# is the clickjacking guard.
resource "aws_cloudfront_response_headers_policy" "this" {
  name = "${module.names.id}-headers"

  security_headers_config {
    content_security_policy {
      override = true
      content_security_policy = join("; ", [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "connect-src 'self' ${var.api_origin} ${var.vault_public_origin}",
        "frame-src ${var.vault_public_origin}",
        "frame-ancestors 'none'",
        "base-uri 'self'",
      ])
    }

    strict_transport_security {
      override                   = true
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      override     = true
      frame_option = "DENY"
    }

    referrer_policy {
      override        = true
      referrer_policy = "strict-origin-when-cross-origin"
    }
  }
}

output "bucket_arn" {
  description = "ARN of the asset bucket, for the deploy role's policy."
  value       = aws_s3_bucket.this.arn
}

output "distribution_arn" {
  description = "ARN of the distribution."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "The *.cloudfront.net domain. The Route53 alias for var.domain_name points here."
  value       = aws_cloudfront_distribution.this.domain_name
}

