# envs/production/messaging.tf
#
# The bus. Four application topics, eight consumer queues, one pager topic.
#
# Names are frozen by payzeno-contracts (src/events.ts header table) and api-surface.md §14.
# `payzeno-api-ledger`, not `payzeno_api_ledger`. A queue whose name here differs by one
# character from the name in the contract is a queue with no consumer and a consumer with no
# queue, and neither side reports an error.
#
# Every module "q_*" below carries an explicit filter_policy whose event_type members are
# copied verbatim from that queue's row in §14. modules/sqs-queue validates them against a
# checked-in copy of EVENT_TYPES, so a typo is a plan error rather than a subscription that
# silently matches nothing.
#
# THREE EVENT TYPES ARE DELIBERATELY UNSUBSCRIBED and this is not a gap to fix:
#
#     settlement.batch_closed
#     settlement.reconciliation_failed
#     ledger.transaction_posted
#
# They exist for the audit trail and for the ops firehose subscription on the topic. Adding a
# consumer for them means writing a consumer class in a service repo first. See
# api-surface.md §14, the paragraph headed "Intentionally unconsumed".
#
# Note that consumer_role_arns is empty on every queue here. Consumer permission comes from
# the task role's own policy in modules/ecs-service/iam.tf, which builds the queue ARNs from
# strings rather than references — passing the role ARNs in would make the services and the
# queues mutually dependent, and terraform will not build that graph.

resource "aws_kms_key" "bus" {
  description             = "Payzeno production event bus — SNS at-rest encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name = "payzeno-production-bus"
  }
}

resource "aws_kms_alias" "bus" {
  name          = "alias/payzeno-production-bus"
  target_key_id = aws_kms_key.bus.key_id
}

# ---------------------------------------------------------------------------
# Topics
# ---------------------------------------------------------------------------

module "q_ledger_merchants" {
  source = "../../modules/sqs-queue"

  name        = "payzeno-ledger-merchants"
  environment = local.environment
  topic_arn   = module.topic_merchant_events.topic_arn

  # MerchantEventConsumer (payzeno-ledger) — maintains the ledger's merchant projection.
  filter_policy = {
    event_type = [
      "merchant.created",
      "merchant.updated",
      "merchant.status_changed",
      "merchant.bank_account_verified",
    ]
  }

  visibility_timeout          = 60
  age_alarm_threshold_seconds = 600
  depth_alarm_threshold       = 500

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

# ---------------------------------------------------------------------------
# Queues — payzeno-api consumers
# ---------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "api_webhooks_payments" {
  topic_arn = module.topic_payments_events.topic_arn
  protocol  = "sqs"
  endpoint  = module.q_api_webhooks.queue_arn

  raw_message_delivery = false
  filter_policy_scope  = "MessageAttributes"

  filter_policy = jsonencode({
    event_type = [
      "payment.failed",
      "refund.succeeded",
      "refund.failed",
      "dispute.evidence_submitted",
    ]
  })
}

# THE DOUBLE-SUBSCRIBED QUEUE. Do not "tidy" this.
#
# NotificationRelayConsumer (payzeno-api) pushes to NotificationsGateway, which fans out over
# the /ws/notifications WebSocket to the console. It needs payout.failed and
# settlement.completed (ledger topic) AND dispute.opened (payments topic). One queue, one
# consumer, two topics, two filter policies. events.ts's header table says so explicitly and
# api-surface.md §14 says so again.
#
# The module creates the ledger subscription; the payments one is the raw resource below.
module "q_console_notifications" {
  source = "../../modules/sqs-queue"

  name        = "payzeno-console-notifications"
  environment = local.environment
  topic_arn   = module.topic_ledger_events.topic_arn

  filter_policy = {
    event_type = [
      "payout.failed",
      "settlement.completed",
    ]
  }

  additional_topic_arns = [module.topic_payments_events.topic_arn]

  # A notification nobody is connected to receive is not worth redelivering for four days.
  message_retention_seconds   = 86400
  visibility_timeout          = 30
  max_receive_count           = 3
  age_alarm_threshold_seconds = 180
  depth_alarm_threshold       = 500

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

