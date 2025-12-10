# modules/static-site — inputs.
#
# The console's build-time configuration (VITE_PAYZENO_API_URL, VITE_WS_URL,
# VITE_VAULT_PUBLIC_URL, VITE_ENVIRONMENT, the two VITE_FEATURE_* flags) is NOT here. Those
# are baked into the bundle by the console's own CI at build time, and the values are passed
# as build args from envs/*/routing.tf. This module only owns the bucket the built bundle
# lands in and the distribution in front of it.
#
# What IS here is api_origin and vault_public_origin, because the CSP has to allow exactly
# the origins the bundle will call — and those two facts have to agree or the console loads
# and then fails every request with a console error nobody reads.

variable "service" {
  description = "Always payzeno-console. Kept as a variable so naming works the same way it does everywhere else."
  type        = string
  default     = "payzeno-console"
}

variable "environment" {
  description = "production | staging."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate for domain_name. Must be in us-east-1 — CloudFront reads certificates from there and only there, regardless of where anything else lives."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:acm:us-east-1:", var.acm_certificate_arn))
    error_message = "PAYZENO_INFRA_INVALID_INPUT: CloudFront certificates live in us-east-1. An eu-west-1 ARN here fails at apply with a message that does not say why."
  }
}

variable "vault_public_origin" {
  description = "The card vault's public origin. The PAN entry iframe is served from here and posts to it; it needs to be in both frame-src and connect-src or card entry silently fails."
  type        = string

  validation {
    condition     = startswith(var.vault_public_origin, "https://")
    error_message = "PAYZENO_INFRA_INVALID_INPUT: vault_public_origin must be an https:// origin."
  }
}

variable "price_class" {
  description = "CloudFront edge coverage. Production serves EU and North America merchants; staging is cheapest-only."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_All", "PriceClass_200", "PriceClass_100"], var.price_class)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: price_class must be PriceClass_All, PriceClass_200 or PriceClass_100."
  }
}

