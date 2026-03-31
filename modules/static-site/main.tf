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

locals {
  bucket_name = "${module.names.id}-assets"

  # Vite emits hashed filenames under /assets/. Those are immutable forever. index.html is
  # not, and caching it is how a deploy goes out and nobody sees it for a day.
  immutable_path = "/assets/*"
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

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${module.names.id}-oac"
  description                       = "OAC for ${var.service} (${var.environment})"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
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

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.service} — ${var.environment}"
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = [var.domain_name]

  origin {
    origin_id                = local.bucket_name
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = local.bucket_name
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # CachingOptimized. index.html is short-TTL by the ordered behaviour below.
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.this.id
  }

  ordered_cache_behavior {
    path_pattern           = local.immutable_path
    target_origin_id       = local.bucket_name
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.this.id
  }

  # The SPA fallback. Any path the bucket does not have is index.html with a 200, because
  # /settlements/stl_123 is a client route and a 404 there is a blank page. This is the
  # CloudFront equivalent of nginx/payzeno-console.conf's `try_files $uri /index.html`, and
  # the two must agree — local dev goes through nginx, production goes through here.
  dynamic "custom_error_response" {
    for_each = var.spa_fallback ? [403, 404] : []

    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(module.names.tags, {
    Name = "${module.names.id}-cdn"
  })

  lifecycle {
    precondition {
      condition     = !var.spa_fallback || var.domain_name != ""
      error_message = "PAYZENO_INFRA_PRECONDITION: an SPA distribution needs its alias, or every deep link resolves against the cloudfront.net domain and the CSP's connect-src blocks the API call."
    }
  }
}

# ---------------------------------------------------------------------------
# Outputs. Small module; they stay here. (variables.tf is split out anyway — see
# CONTRIBUTING.md §4 on the honest state of that convention.)
# ---------------------------------------------------------------------------

output "bucket" {
  description = "Asset bucket name. The console's deploy job syncs its dist/ here."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the asset bucket, for the deploy role's policy."
  value       = aws_s3_bucket.this.arn
}

output "distribution_id" {
  description = "CloudFront distribution id. The deploy job invalidates /index.html against this after the sync."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "ARN of the distribution."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "The *.cloudfront.net domain. The Route53 alias for var.domain_name points here."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "domain_name" {
  description = "The console's real hostname — console.payzeno.com in production."
  value       = var.domain_name
}
