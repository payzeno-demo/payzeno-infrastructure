# modules/cloudwatch-alarm
#
# The one alarm primitive. Highest fan-in in the repo — ecs-service instantiates it
# three times, rds-postgres twice, sqs-queue once, and the env roots call it directly.
#
# Rule, and it is not negotiable: an alarm without a runbook is a 03:00 phone call with
# no instructions attached. `runbook_url` is required and validated. If there is no
# runbook section for what you are alarming on, write one first — docs/runbooks/ —
# and link the anchor.
#
# Inline variables/outputs: this module is well under 60 lines of resource. CONTRIBUTING.md §4.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

variable "service" {
  description = "Owning service, passed through to naming. e.g. payzeno-ledger."
  type        = string
}

variable "environment" {
  description = "production | staging."
  type        = string
}

variable "name" {
