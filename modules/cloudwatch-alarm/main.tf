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
  description = "Short alarm name, appended to the naming id. e.g. cpu-high, queue-age."
  type        = string
}

variable "namespace" {
  description = "CloudWatch namespace. AWS/ECS, AWS/RDS, AWS/SQS, or Payzeno/<Service> for custom metrics."
  type        = string
}

variable "metric_name" {
  description = "CloudWatch metric name."
  type        = string
}

variable "statistic" {
  description = "Statistic to evaluate. Leave empty when using extended_statistic."
  type        = string
  default     = "Average"
}

variable "extended_statistic" {
  description = "Percentile statistic, e.g. p99. Mutually exclusive with statistic. Added month 7 for arc PERF."
  type        = string
  default     = null
}

variable "comparison_operator" {
  description = "GreaterThanThreshold, GreaterThanOrEqualToThreshold, LessThanThreshold, LessThanOrEqualToThreshold."
