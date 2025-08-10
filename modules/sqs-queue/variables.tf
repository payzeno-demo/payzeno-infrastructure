# modules/sqs-queue — inputs.
#
# The EVENT_TYPES list below is a copy of payzeno-contracts' events.ts EVENT_TYPES. It is
# duplicated here on purpose: terraform cannot import a TypeScript const, and a filter policy
# containing a typo does not fail — it silently matches nothing, and the consumer looks
# healthy while receiving no work. A misspelled event type has to be a plan error.
#
# When contracts adds an event type, add it here in the same PR. That is four repos for one
# name (contracts, the publisher, the consumer, here) and it is the price of the name meaning
# the same thing in all four.

variable "name" {
  description = "Bare queue name from api-surface.md §14 — e.g. payzeno-api-ledger. Hyphens, not underscores. Staging prefixes this to payzeno-staging-*."
  type        = string

  validation {
    condition     = can(regex("^payzeno-[a-z][a-z-]*[a-z]$", var.name))
    error_message = "PAYZENO_INFRA_INVALID_INPUT: queue name must match ^payzeno-[a-z-]+$ and must appear in api-surface.md §14. payzeno_api_ledger and payzeno-api-ledger are two different queues as far as the graph is concerned, and only one of them is real."
  }
}

variable "filter_policy" {
  description = <<-EOT
    SNS filter policy, keyed on MessageAttributes. Always of the shape

        { event_type = ["payment.authorized", "payment.captured", ...] }

    and the members come verbatim from that queue's row in api-surface.md §14. An empty
    filter policy means "everything on the topic", which is right only for the DLQ monitor.
  EOT
  type        = map(list(string))
  default     = {}

  validation {
    condition = alltrue([
      for t in try(var.filter_policy["event_type"], []) : contains([
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
      ], t)
    ])
    error_message = "PAYZENO_INFRA_INVALID_INPUT: filter_policy contains an event_type that is not in EVENT_TYPES (payzeno-contracts src/events.ts). A typo here does not fail at apply — it produces a subscription that matches nothing and a consumer that looks healthy and receives no work."
  }

  validation {
    condition = alltrue([
      for k in keys(var.filter_policy) : k == "event_type"
    ])
    error_message = "PAYZENO_INFRA_INVALID_INPUT: the only filter attribute Payzeno publishes is event_type. Filtering on anything else silently matches nothing, because the publisher does not set the attribute."
  }
}

variable "depth_alarm_threshold" {
  description = "ApproximateNumberOfMessagesVisible threshold. Catches 'consuming but losing ground', which age does not — every message in a 4,113-item backlog can be young."
  type        = number
  default     = 1000
}

variable "extra_tags" {
  description = "Merged under the standard tag set."
  type        = map(string)
  default     = {}
}
