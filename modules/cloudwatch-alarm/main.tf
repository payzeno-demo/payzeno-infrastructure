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
  type        = string
  default     = "GreaterThanThreshold"
}

variable "threshold" {
  description = "Threshold the statistic is compared against."
  type        = number
}

variable "period" {
  description = "Evaluation period in seconds. 60 for anything that pages, 300 for trend alarms."
  type        = number
  default     = 300
}

variable "evaluation_periods" {
  description = "How many periods are examined."
  type        = number
  default     = 3
}

variable "datapoints_to_alarm" {
  description = "How many of evaluation_periods must breach. Added by PAY-2055 — the duplicate-settlement alarm needs 1-of-1 on a metric that is normally absent."
  type        = number
  default     = null
}

variable "treat_missing_data" {
  description = "missing | notBreaching | breaching | ignore. Added by PAY-2055 for the same reason."
  type        = string
  default     = "missing"

  validation {
    condition     = contains(["missing", "notBreaching", "breaching", "ignore"], var.treat_missing_data)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: treat_missing_data must be one of missing, notBreaching, breaching, ignore."
  }
}

variable "dimensions" {
  description = "Metric dimensions, e.g. { ClusterName = ..., ServiceName = ... }."
  type        = map(string)
  default     = {}
}

variable "alarm_actions" {
  description = "SNS topic ARNs notified on ALARM. In production this is always the pager topic."
  type        = list(string)
  default     = []
