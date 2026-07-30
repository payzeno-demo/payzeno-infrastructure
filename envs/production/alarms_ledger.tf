# envs/production/alarms_ledger.tf
#
# PAY-2055. Written at 03:40 on the postmortem day, straight after the hotfix went out.
#
# These are RAW aws_cloudwatch_metric_alarm resources, not modules/cloudwatch-alarm, which
# is against the convention in every other file in this repo. Two reasons, and only one of
# them is good:
#
#   1. metric math. ledger_batch_overposted divides one custom metric by another, and the
#      module takes a single metric_name. Adding metric_query support to the module at 03:40
#      was not going to happen.
#   2. it was 03:40.
#
# payzeno-ledger/docs/postmortems/2041-duplicate-settlement.md names these resource addresses
# literally, and so do PAY-2054 and PAY-2059. Refactoring this file onto the module means
# updating those in the same PR. It is a real ticket, not a drive-by. Leave it.
#
# What these alarms are for, in one line each:
#
#   We shipped 1,847 duplicate settle transactions and 218 duplicate cardholder captures, and
#   the way we found out was a merchant's support email nineteen hours later. Every alarm in
#   this file would have fired inside five minutes. None of them existed.

locals {
  ledger_namespace = "Payzeno/Ledger"

  # Every alarm in this file goes to the pager AND to #incidents. See the second subscription
  # on aws_sns_topic.payzeno_pager in messaging.tf — same postmortem, same reason.
  ledger_alarm_actions = [aws_sns_topic.payzeno_pager.arn]

  ledger_runbook = "${local.runbook_base_url}/oncall.md"
}

# ---------------------------------------------------------------------------
# The one that matters.
#
# SettlementPoster emits DuplicateSettlementDetected each time it finds an existing
# purpose='settle' transaction for a charge it is about to post. In steady state this metric
# is ABSENT, not zero — which is why treat_missing_data is notBreaching and why
# datapoints_to_alarm is 1. One occurrence in one five-minute window is a page.
#
# It is gated on FLAG_DUPLICATE_SETTLEMENT_ALARM in the ledger's config, which is "true" in
# services.tf. If someone turns that flag off, this alarm goes quiet rather than going green,
# and there is nothing here that can tell the difference. That is the known weakness of this
# alarm and it is written down in the runbook.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ledger_duplicate_settlement" {
  alarm_name        = "payzeno-ledger-production-duplicate-settlement"
  alarm_description = "payzeno-ledger detected a duplicate settle transaction. A duplicate settlement is internally balanced, so nothing else will tell you. If capture_at_settlement is on for the merchant, the cardholder has been charged twice. Runbook: ${local.ledger_runbook}#duplicate-settlement"

  namespace   = local.ledger_namespace
  metric_name = "DuplicateSettlementDetected"
  statistic   = "Sum"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1

  # The metric does not exist when nothing is wrong. `missing` would leave this alarm in
  # INSUFFICIENT_DATA forever and INSUFFICIENT_DATA does not page.
  treat_missing_data = "notBreaching"

  dimensions = {
    Environment = "production"
  }

  alarm_actions = local.ledger_alarm_actions

  tags = {
    Name        = "payzeno-ledger-production-duplicate-settlement"
    Service     = "payzeno-ledger"
    Environment = "production"
    Team        = "infra"
    ManagedBy   = "terraform"
    Repo        = "payzeno-infrastructure"
    Ticket      = "PAY-2055"
    Runbook     = "${local.ledger_runbook}#duplicate-settlement"
    Severity    = "sev1"
  }
}

# ---------------------------------------------------------------------------
# Metric math: posted_total_minor / expected_total_minor > 1.001.
#
# The duplicate alarm above catches the case where the ledger NOTICES. This one catches the
# case where it does not: a batch that has posted more money than the acquirer said it should
# have. On the night, this ratio was 1.34 for forty minutes.
#
# 1.001 rather than 1.0 because rounding on a large batch of minor units can land a few units
# over and paging on four pence is how an alarm gets muted.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ledger_batch_overposted" {
  alarm_name        = "payzeno-ledger-production-batch-overposted"
  alarm_description = "A settlement batch has posted more than it was supposed to (posted_total_minor / expected_total_minor > 1.001). Either items are being settled twice or the acquirer file was reimported. Runbook: ${local.ledger_runbook}#duplicate-settlement"

  comparison_operator = "GreaterThanThreshold"
  threshold           = 1.001
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "posted / expected"
    label       = "posted_total_minor / expected_total_minor"
    return_data = true
  }

  metric_query {
    id = "posted"

    metric {
      namespace   = local.ledger_namespace
      metric_name = "SettlementPostedTotalMinor"
      stat        = "Sum"
      period      = 300

      dimensions = {
        Environment = "production"
      }
    }
  }

  metric_query {
    id = "expected"

    metric {
      namespace   = local.ledger_namespace
      metric_name = "SettlementExpectedTotalMinor"
      stat        = "Sum"
      period      = 300

      dimensions = {
        Environment = "production"
      }
    }
  }

  alarm_actions = local.ledger_alarm_actions

  tags = {
    Name        = "payzeno-ledger-production-batch-overposted"
    Service     = "payzeno-ledger"
    Environment = "production"
    Team        = "infra"
    ManagedBy   = "terraform"
    Repo        = "payzeno-infrastructure"
    Ticket      = "PAY-2055"
    Runbook     = "${local.ledger_runbook}#duplicate-settlement"
    Severity    = "sev1"
  }
}

# ---------------------------------------------------------------------------
# Reconciliation lag.
#
# ReconciliationOldestPendingItemAgeSeconds — how old the oldest item in a RETRYABLE status
# is. Two hours means the sweep is not keeping up, which is the precondition for everything
# else in this file: a large retryable backlog is what makes a sweep and a drain overlap on
# the same item in the first place.
#
# 7200 is deliberately generous. The sweep runs every 900s and a normal batch takes two or
# three passes; anything under an hour is noise.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ledger_reconciliation_lag" {
  alarm_name        = "payzeno-ledger-production-reconciliation-lag"
  alarm_description = "The oldest pending reconciliation_item is over two hours old. The sweep is behind. This is the state that precedes a sweep/drain overlap — read the runbook before touching anything. Runbook: ${local.ledger_runbook}#reconciliation-lag"

  namespace   = local.ledger_namespace
  metric_name = "ReconciliationOldestPendingItemAgeSeconds"
  statistic   = "Maximum"

  comparison_operator = "GreaterThanThreshold"
  threshold           = 7200
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    Environment = "production"
  }

  alarm_actions = local.ledger_alarm_actions

  tags = {
    Name        = "payzeno-ledger-production-reconciliation-lag"
    Service     = "payzeno-ledger"
    Environment = "production"
    Team        = "infra"
    ManagedBy   = "terraform"
    Repo        = "payzeno-infrastructure"
    Ticket      = "PAY-2055"
    Runbook     = "${local.ledger_runbook}#reconciliation-lag"
    Severity    = "sev2"
  }
}

# ---------------------------------------------------------------------------
# Retry drain depth.
#
# RetryableItemCount — how many reconciliation_items are sitting in a RETRYABLE status. It
# went from single digits to 4,113 in eleven minutes and nothing anywhere reported it. The
# drain was running, on one task (module.payzeno_ledger_canary), and it took 21 minutes to
# work through them while three batch sweeps ran alongside.
#
# 500 is roughly the point at which the drain stops being able to catch up within one sweep
# interval on a single task. If PAY-1691 ever lands and the drain runs everywhere, this
# threshold goes up.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ledger_retry_drain_depth" {
  alarm_name        = "payzeno-ledger-production-retry-drain-depth"
  alarm_description = "More than 500 reconciliation_items are in a retryable status. The retry drain runs on ONE task (module.payzeno_ledger_canary, RETRY_DRAIN_ENABLED=true) and cannot clear this inside a sweep interval. Runbook: ${local.ledger_runbook}#retry-backlog"

  namespace   = local.ledger_namespace
  metric_name = "RetryableItemCount"
  statistic   = "Maximum"

  comparison_operator = "GreaterThanThreshold"
  threshold           = 500
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    Environment = "production"
  }

  alarm_actions = local.ledger_alarm_actions

  tags = {
    Name        = "payzeno-ledger-production-retry-drain-depth"
    Service     = "payzeno-ledger"
    Environment = "production"
    Team        = "infra"
    ManagedBy   = "terraform"
    Repo        = "payzeno-infrastructure"
    Ticket      = "PAY-2055"
    Runbook     = "${local.ledger_runbook}#retry-backlog"
    Severity    = "sev2"
  }
}

# ---------------------------------------------------------------------------
# Composite: any of the four above. This is what the #incidents room subscribes to so that a
# sweep-and-drain cascade shows up as one incident rather than four separate pages three
# minutes apart, which is what happened and which is part of why it took as long as it did.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_composite_alarm" "ledger_settlement_integrity" {
  alarm_name        = "payzeno-ledger-production-settlement-integrity"
  alarm_description = "Any settlement-integrity alarm is firing on payzeno-ledger. Start at ${local.ledger_runbook}#duplicate-settlement and work down."

  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.ledger_duplicate_settlement.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.ledger_batch_overposted.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.ledger_reconciliation_lag.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.ledger_retry_drain_depth.alarm_name})",
  ])

  alarm_actions = local.ledger_alarm_actions

  tags = {
    Name        = "payzeno-ledger-production-settlement-integrity"
    Service     = "payzeno-ledger"
    Environment = "production"
    Team        = "infra"
    ManagedBy   = "terraform"
    Repo        = "payzeno-infrastructure"
    Ticket      = "PAY-2055"
    Runbook     = "${local.ledger_runbook}#duplicate-settlement"
  }
}

output "ledger_duplicate_settlement_alarm_name" {
  description = "Named in payzeno-ledger/docs/postmortems/2041-duplicate-settlement.md. Do not rename without updating it."
  value       = aws_cloudwatch_metric_alarm.ledger_duplicate_settlement.alarm_name
}
