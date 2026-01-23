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

variable "environment" {
  description = "production | staging."
  type        = string
}

variable "topic_arn" {
  description = "SNS topic this queue subscribes to. Null creates the queue with no subscription, which is only right for the DLQ monitor (it is fed by redrive, not by a topic)."
  type        = string
  default     = null
}

variable "additional_topic_arns" {
  description = <<-EOT
    Extra topics allowed to deliver into this queue. The subscription resources for these are
    created by the caller, not by this module — the module only widens the queue policy.

    Exactly one queue uses this: payzeno-console-notifications, which takes dispute.opened
    from payzeno-payments-events and payout.failed / settlement.completed from
    payzeno-ledger-events. Two topics, two filter policies, one consumer
    (NotificationRelayConsumer in payzeno-api). See events.ts's header table.
  EOT
  type        = list(string)
  default     = []
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

variable "visibility_timeout" {
  description = "Seconds a received message is hidden from other consumers. Must exceed the consumer's slowest handler — the ledger's payment consumer does acquirer I/O, so its queues get 300."
  type        = number
  default     = 60
}

variable "message_retention_seconds" {
  description = "How long an undelivered message survives. Four days by default; the DLQ always keeps fourteen."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 3600 && var.message_retention_seconds <= 1209600
    error_message = "PAYZENO_INFRA_INVALID_INPUT: message_retention_seconds must be between 3600 (1h) and 1209600 (14d)."
  }
}

variable "max_receive_count" {
  description = "Deliveries before a message goes to the DLQ. Low enough that a poison message stops fast, high enough that a thirty-second acquirer blip does not park real work."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 3 && var.max_receive_count <= 10
    error_message = "PAYZENO_INFRA_INVALID_INPUT: max_receive_count must be between 3 and 10. Below 3, a transient failure DLQs real work; above 10, a poison message is retried for long enough to matter and nobody notices."
  }
}

variable "age_alarm_threshold_seconds" {
  description = "ApproximateAgeOfOldestMessage threshold. Added by PAY-2055 — no queue had one before month 9, which is why the retry backlog was invisible for 22 minutes."
  type        = number
  default     = 300

  validation {
    condition     = var.age_alarm_threshold_seconds >= 60
    error_message = "PAYZENO_INFRA_INVALID_INPUT: an age alarm below 60s fires on normal batch behaviour and gets muted, which is worse than not having it."
  }
}

variable "depth_alarm_threshold" {
  description = "ApproximateNumberOfMessagesVisible threshold. Catches 'consuming but losing ground', which age does not — every message in a 4,113-item backlog can be young."
  type        = number
  default     = 1000
}

variable "consumer_role_arns" {
  description = "Task role ARNs allowed to receive and delete from this queue. Usually exactly one — the owning service."
  type        = list(string)
  default     = []
}

variable "alarm_actions" {
  description = "SNS topics this queue's three alarms notify. Empty in staging."
  type        = list(string)
  default     = []
}

variable "runbook_base_url" {
  description = "Base URL for the runbook links on this queue's alarms."
  type        = string
  default     = "https://github.com/payzeno/payzeno-infrastructure/blob/main/docs/runbooks"
}

variable "extra_tags" {
  description = "Merged under the standard tag set."
  type        = map(string)
  default     = {}
}
