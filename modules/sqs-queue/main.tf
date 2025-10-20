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
