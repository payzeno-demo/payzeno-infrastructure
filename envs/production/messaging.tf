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

module "topic_payments_events" {
  source = "../../modules/sns-topic"

  name        = "payzeno-payments-events"
  environment = local.environment
  kms_key_arn = aws_kms_key.bus.arn
}

module "topic_merchant_events" {
  source = "../../modules/sns-topic"

  name        = "payzeno-merchant-events"
  environment = local.environment
  kms_key_arn = aws_kms_key.bus.arn
}

# Created month 6, when invoice.issued landed in contracts and the strangler needed a way to
# get invoices out of the legacy biller without the api polling it. Before that this topic
# did not exist and module.q_api_billing did not either.
module "topic_billing_events" {
  source = "../../modules/sns-topic"

  name        = "payzeno-billing-events"
  environment = local.environment
  kms_key_arn = aws_kms_key.bus.arn
}

# ---------------------------------------------------------------------------
# The pager. Not an application topic — this is where every cloudwatch-alarm's alarm_actions
# point.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "payzeno_pager" {
  name = "payzeno-production-pager"

  tags = {
    Name = "payzeno-production-pager"
    Role = "alarm-destination"
  }
}

resource "aws_sns_topic_subscription" "pager_pagerduty" {
  topic_arn = aws_sns_topic.payzeno_pager.arn
  protocol  = "https"
  endpoint  = "https://events.pagerduty.com/integration/${var.pagerduty_integration_key}/enqueue"

  endpoint_auto_confirms = true
}

# Added the morning after PAY-2041. The alarm that would have caught the duplicate
# settlements did not exist yet, but even the alarms that DID exist only went to PagerDuty,
# and PagerDuty only pages one person. We found out about a 1,847-transaction duplicate from
# a merchant's support email. Everything that pages now also lands in a room.
resource "aws_sns_topic_subscription" "pager_slack_incidents" {
  topic_arn = aws_sns_topic.payzeno_pager.arn
  protocol  = "https"
  endpoint  = "https://hooks.slack.com/services/${var.slack_incidents_webhook_path}"

  endpoint_auto_confirms = true
}

variable "pagerduty_integration_key" {
  description = "PagerDuty Events API v2 integration key for the payzeno-production service. Supplied at apply time; not in state as a secret because the endpoint URL is the credential and it is rotated by rotating the integration."
  type        = string
  sensitive   = true
  default     = "PLACEHOLDER_SET_AT_APPLY"
}

variable "slack_incidents_webhook_path" {
  description = "Path portion of the #incidents Slack webhook."
  type        = string
  sensitive   = true
  default     = "PLACEHOLDER_SET_AT_APPLY"
}

# ---------------------------------------------------------------------------
# Queues — payzeno-ledger consumers
# ---------------------------------------------------------------------------

module "q_ledger_payments" {
  source = "../../modules/sqs-queue"

  name        = "payzeno-ledger-payments"
  environment = local.environment
  topic_arn   = module.topic_payments_events.topic_arn

  # PaymentEventConsumer (payzeno-ledger). api-surface.md §14.
  filter_policy = {
    event_type = [
      "payment.authorized",
      "payment.captured",
      "payment.canceled",
      "refund.created",
      "dispute.opened",
      "dispute.closed",
    ]
  }

  # This consumer does acquirer I/O inside the handler on the capture_at_settlement path.
  # 60s was not enough and the redeliveries were doing real work twice.
  visibility_timeout = 300
  max_receive_count  = 5

  age_alarm_threshold_seconds = 300
  depth_alarm_threshold       = 2000

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

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

module "q_api_ledger" {
  source = "../../modules/sqs-queue"

  name        = "payzeno-api-ledger"
  environment = local.environment
  topic_arn   = module.topic_ledger_events.topic_arn

  # LedgerEventsConsumer (payzeno-api). settlement.duplicate_detected was added to this list
  # by PAY-2055 — the consumer now writes an audit_log row and opens a support task when the
  # charge has capture_at_settlement.
  filter_policy = {
    event_type = [
      "settlement.completed",
      "settlement.duplicate_detected",
      "settlement.variance_detected",
      "payout.paid",
      "payout.failed",
      "payout.returned",
      "ledger.imbalance_detected",
    ]
  }

  visibility_timeout          = 120
  age_alarm_threshold_seconds = 300
  depth_alarm_threshold       = 1000

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

module "q_api_webhooks" {
  source = "../../modules/sqs-queue"

  name        = "payzeno-api-webhooks"
  environment = local.environment
  topic_arn   = module.topic_ledger_events.topic_arn

  # WebhookFanoutConsumer (payzeno-api) — the only writer of webhook_event.
  #
  # This queue is subscribed to BOTH payments and ledger, same as console-notifications:
  # payment.failed / refund.* / dispute.evidence_submitted are on payments, and
  # payout.scheduled / settlement.item_settled are on ledger. The second subscription is
  # aws_sns_topic_subscription.api_webhooks_payments below.
  filter_policy = {
    event_type = [
      "payout.scheduled",
      "settlement.item_settled",
    ]
  }

  additional_topic_arns = [module.topic_payments_events.topic_arn]

  # Outbound HTTP to merchant endpoints happens in WebhookDeliveryJob, not in the consumer,
  # so the handler is a database insert and 60s is plenty.
  visibility_timeout          = 60
  age_alarm_threshold_seconds = 600
  depth_alarm_threshold       = 5000

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

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

module "q_api_billing" {
  source = "../../modules/sqs-queue"

  name        = "payzeno-api-billing"
  environment = local.environment
  topic_arn   = module.topic_billing_events.topic_arn

  # InvoiceProjectionConsumer (payzeno-api) — refreshes invoice_projection. Created month 6
  # alongside module.topic_billing_events, arc MIG.
  filter_policy = {
    event_type = ["invoice.issued"]
  }

  visibility_timeout          = 60
  age_alarm_threshold_seconds = 900
  depth_alarm_threshold       = 500

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

module "q_dlq_monitor" {
  source = "../../modules/sqs-queue"

  name        = "payzeno-dlq-monitor"
  environment = local.environment

  # No topic. DeadLetterConsumer reads this queue, which is fed by redrive rather than by a
  # subscription — that is why topic_arn is null and the filter policy is empty, and it is
  # the one queue in this file for which that is correct.
  topic_arn = null

  message_retention_seconds   = 1209600
  visibility_timeout          = 60
  max_receive_count           = 3
  age_alarm_threshold_seconds = 300
  depth_alarm_threshold       = 1

  alarm_actions    = [aws_sns_topic.payzeno_pager.arn]
  runbook_base_url = local.runbook_base_url
}

# ---------------------------------------------------------------------------
# Queues — payzeno-billing-legacy consumers
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "ledger_settlements" {
  name                      = "payzeno-ledger-settlements"
  message_retention_seconds = 345600
  sqs_managed_sse_enabled   = true

  tags = {
    Name    = "payzeno-ledger-settlements"
    Service = "payzeno-ledger"
    Status  = "orphan"
  }
}

# ---------------------------------------------------------------------------
# Drift checks. PAYZENO_INFRA_DRIFT — warnings on every plan, never a hard failure.
# ---------------------------------------------------------------------------

locals {
  # Queues that carry exactly one topic subscription created by their own module.
  single_subscription_queues = {
    "payzeno-ledger-payments"   = module.q_ledger_payments.subscription_arn
    "payzeno-ledger-merchants"  = module.q_ledger_merchants.subscription_arn
    "payzeno-api-ledger"        = module.q_api_ledger.subscription_arn
    "payzeno-api-billing"       = module.q_api_billing.subscription_arn
    "payzeno-billing-merchants" = module.q_billing_merchants.subscription_arn
  }

  # The two that must have a second subscription created here, and the resource that is it.
  double_subscription_queues = {
    "payzeno-api-webhooks"          = aws_sns_topic_subscription.api_webhooks_payments.arn
    "payzeno-console-notifications" = aws_sns_topic_subscription.console_notifications_payments.arn
  }

  # Union of everything any queue admits. Used to prove the three unconsumed types are the
  # only three, so that "we forgot one" and "we meant to leave it" are distinguishable.
  subscribed_event_types = toset(concat(
    module.q_ledger_payments.subscribed_event_types,
    module.q_ledger_merchants.subscribed_event_types,
    module.q_api_ledger.subscribed_event_types,
    module.q_api_webhooks.subscribed_event_types,
    module.q_console_notifications.subscribed_event_types,
    module.q_api_billing.subscribed_event_types,
    module.q_billing_merchants.subscribed_event_types,
    ["payment.failed", "refund.succeeded", "refund.failed", "dispute.evidence_submitted"],
    ["dispute.opened"],
  ))

  intentionally_unconsumed = toset([
    "settlement.batch_closed",
    "settlement.reconciliation_failed",
    "ledger.transaction_posted",
  ])

  # Types that exist in the contract, are not subscribed, and are not on the intentional
  # list. Should always be empty.
  accidentally_unconsumed = setsubtract(
    setsubtract(toset(local.all_event_types), local.subscribed_event_types),
    local.intentionally_unconsumed,
  )

  all_event_types = [
    "payment.authorized", "payment.captured", "payment.failed", "payment.canceled",
    "refund.created", "refund.succeeded", "refund.failed",
    "dispute.opened", "dispute.evidence_submitted", "dispute.closed",
    "merchant.created", "merchant.updated", "merchant.status_changed",
    "merchant.bank_account_verified",
    "settlement.completed", "settlement.item_settled", "settlement.batch_closed",
    "settlement.funded", "settlement.variance_detected",
    "settlement.duplicate_detected", "settlement.reconciliation_failed",
    "payout.scheduled", "payout.paid", "payout.failed", "payout.returned",
    "ledger.transaction_posted", "ledger.imbalance_detected",
    "invoice.issued",
  ]
}

check "every_contracted_queue_is_subscribed" {
  assert {
    condition = alltrue([
      for name, arn in local.single_subscription_queues : arn != null
    ])
    error_message = "PAYZENO_INFRA_DRIFT: a contracted queue lost its topic subscription. A queue with no subscription is a consumer that runs, reports healthy, and receives nothing."
  }
}

check "console_notifications_has_two_subscriptions" {
  assert {
    condition = alltrue([
      for name, arn in local.double_subscription_queues : arn != null
    ]) && module.q_console_notifications.subscription_arn != null && module.q_api_webhooks.subscription_arn != null
    error_message = "PAYZENO_INFRA_DRIFT: payzeno-console-notifications and payzeno-api-webhooks each need TWO topic subscriptions (payments + ledger). Losing the payments one silently stops dispute.opened reaching the console and stops payment.failed reaching merchant webhooks. It is the easiest thing in this file to delete while tidying."
  }
}

check "no_accidentally_unconsumed_event_types" {
  assert {
    condition     = length(local.accidentally_unconsumed) == 0
    error_message = "PAYZENO_INFRA_DRIFT: these event types have no subscriber and are not on the intentionally-unconsumed list: ${join(", ", local.accidentally_unconsumed)}. Either a consumer was added to contracts without a filter policy here, or a filter policy lost a member."
  }
}

# ---------------------------------------------------------------------------
# Outputs consumed by services.tf
# ---------------------------------------------------------------------------

output "pager_topic_arn" {
  description = "The alarm destination. Every module's alarm_actions points here."
  value       = aws_sns_topic.payzeno_pager.arn
}
