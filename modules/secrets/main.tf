# modules/secrets
#
# Secrets Manager entries + a per-service CMK + the `secrets[]` projection that
# modules/ecs-service feeds straight into the task definition.
#
# The projection output is the whole point of this module. Before month 7 the api's
# WORLDFLOW_API_KEY, NORDPAY_API_KEY and VAULT_API_KEY sat in the task definition's
# `environment[]` block in plaintext, which meant they were in every `describe-task-definition`
# call and in every plan output. PAY-1755 moved them here. Three review rounds with
# dhotfix, and the rule that came out of it is in CONTRIBUTING.md §5.3: a credential goes
# in `secrets`, never in `environment_vars`.
#
# terraform does not know the values. It creates the container and a random placeholder
# version so the task can start; a human sets the real value once, out of band.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Outputs. These stayed here when variables.tf was split out; see the note there.
# ---------------------------------------------------------------------------

