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

