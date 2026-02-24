# modules/sqs-queue
#
# One consumer queue: the queue itself, its DLQ, the redrive policy, the SNS subscription
# with its event_type filter policy, the queue policy that lets SNS deliver, and two alarms.
#
# This module is the physical LISTENS_ON edge. `aws_sns_topic_subscription.this` is the
# actual line between a topic in events.ts and a consumer class in api-surface.md §14 — the
# filter policy is the list of event types that class handles, copied from the contract.
# If the filter policy and the consumer's switch statement disagree, the consumer is either
# dead code or silently dropping events, and neither shows up as an error anywhere.
#
# The age alarm and the depth alarm were added in month 9 (PAY-2055). Before that no queue in
# either environment had a depth alarm at all, which is why a 4,113-item retry backlog was
# invisible for 22 minutes on the night of PAY-2041. We found out from a merchant.
#
# TODO(apager): per-queue DLQ redrive automation — PAY-2062. Right now moving messages back
# out of a DLQ is a human running `aws sqs start-message-move-task` from the runbook, and the
# runbook is the only place that command exists.

terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

module "names" {
  source = "../naming"

  # The queue's "service" is its own name — payzeno-api-ledger is owned by payzeno-api but
  # named for the pairing. naming wants a payzeno- prefixed string and this is one.
  service     = var.name
  environment = var.environment
  component   = "queue"
  extra_tags  = var.extra_tags
}

locals {
  # payzeno-api-ledger          (production)
  # payzeno-staging-api-ledger  (staging)
  queue_name = var.environment == "production" ? var.name : replace(var.name, "payzeno-", "payzeno-staging-")
  dlq_name   = "${local.queue_name}-dlq"

  has_subscription = var.topic_arn != null

  # Every topic allowed to deliver into this queue. Normally one. payzeno-console-notifications
  # is the exception: it takes dispute.opened from the payments topic and payout.failed /
  # settlement.completed from the ledger topic, so envs/*/messaging.tf hands it a second ARN
  # here and creates the second aws_sns_topic_subscription itself.
  delivering_topic_arns = compact(concat([var.topic_arn], var.additional_topic_arns))

  filter_event_types = try(var.filter_policy["event_type"], [])
}

resource "aws_sqs_queue" "dlq" {
  name = local.dlq_name

  # 14 days. A message that lands here is going to be looked at by a human, and the human
  # may be on holiday. Retention shorter than the on-call rotation is retention that loses
  # the evidence.
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = merge(module.names.tags, {
    Name = local.dlq_name
    Role = "dlq"
  })
}

resource "aws_sqs_queue" "this" {
  name = local.queue_name

  visibility_timeout_seconds = var.visibility_timeout
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  tags = merge(module.names.tags, {
    Name = local.queue_name
  })

  lifecycle {
    precondition {
      # The visibility timeout has to outlast the consumer's slowest handler or the message
      # becomes visible again mid-processing and a second consumer picks it up. Every
      # consumer here is idempotent on envelope.id, so that is survivable — but it is also
      # exactly how you get two workers doing the same settlement, which is a shape we have
      # met before.
