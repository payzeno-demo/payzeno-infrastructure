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

