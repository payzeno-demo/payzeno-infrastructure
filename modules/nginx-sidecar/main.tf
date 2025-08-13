# modules/nginx-sidecar
#
# Produces the nginx container definition that modules/ecs-service drops into its task
# definition, plus the S3 object holding the rendered config.
#
# Why a sidecar at all, given the ALB already terminates TLS and routes: because the ALB is
# not the only way into a task. Service-to-service traffic goes over service discovery
# straight to the ENI, and the ^/internal/ deny has to exist on that path too. The ALB rule
# and this config are two halves of the same policy (interfaces.md §6.3), and for five
# months the ALB half was inert while this half was the only thing working. See PAY-1811.
#
# The config is not baked into an image. It is written to S3 by terraform and pulled at task
# start, so an nginx change is an `apply` and a service restart rather than a build. That was
# the right call in month 2 and it is a slightly odd one now — service connect would replace
# the whole thing. It is on the list and it is not urgent.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

data "aws_region" "current" {}

output "config_bucket_arn" {
  description = "ARN of the shared service-config bucket. The execution role needs s3:GetObject under this module's prefix."
  value       = "arn:aws:s3:::${local.config_bucket}"
}

