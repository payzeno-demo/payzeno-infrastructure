# envs/staging/messaging.tf
#
# Split out of stack.tf in month 11. Not because anyone planned to split staging up — the
# PAY-1780 split still has not happened — but because ystackoverflow needed to add a queue,
# could not find the existing ones in a 400-line file, and the review turned into "fine,
# move the queues out first, then add yours".
#
# Same four topics and eight queues as production, prefixed payzeno-staging-* by
# modules/sns-topic and modules/sqs-queue. Filter policies are identical to production's on
# purpose: the whole value of staging on the bus is that a consumer which receives the wrong
# set of event types here receives the wrong set there too.
#
# No pager topic. alarm_actions is empty on every queue, so the age, depth and DLQ alarms
# exist as resources and notify nobody. That is deliberate — the resource addresses have to
# match production or a module change that breaks one root passes in the other.
#
# The same three event types are unsubscribed here as in production
# (settlement.batch_closed, settlement.reconciliation_failed, ledger.transaction_posted).
# There is no `check` block asserting it, because staging has no check blocks.

resource "aws_kms_key" "bus" {
  description             = "Payzeno staging event bus — SNS at-rest encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = {
    Name = "payzeno-staging-bus"
  }
}

module "q_api_webhooks" {
  source = "../../modules/sqs-queue"

  name        = "payzeno-api-webhooks"
  environment = local.environment
  topic_arn   = module.topic_ledger_events.topic_arn

  filter_policy = {
    event_type = [
      "payout.scheduled",
      "settlement.item_settled",
    ]
  }

  additional_topic_arns = [module.topic_payments_events.topic_arn]

  visibility_timeout    = 60
  depth_alarm_threshold = 500
}

resource "aws_sns_topic_subscription" "console_notifications_payments" {
  topic_arn = module.topic_payments_events.topic_arn
  protocol  = "sqs"
  endpoint  = module.q_console_notifications.queue_arn

  raw_message_delivery = false
  filter_policy_scope  = "MessageAttributes"

  filter_policy = jsonencode({
    event_type = ["dispute.opened"]
  })
}

