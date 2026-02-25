# modules/sqs-queue — outputs.
#
# `queue_url` is the one every service reads. envs/*/services.tf wires it into the consuming
# service's environment_vars under the name from interfaces.md §7:
#
#   module.q_api_ledger.queue_url            -> payzeno-api  SQS_LEDGER_QUEUE_URL
#   module.q_ledger_payments.queue_url       -> payzeno-ledger SQS_PAYMENTS_QUEUE_URL
#   module.q_console_notifications.queue_url -> payzeno-api  SQS_CONSOLE_NOTIFICATIONS_URL
#
# That wiring is the whole reason this module exists as a module. The URL is not guessable —
# it carries the account id — so a consumer that hardcodes one is a consumer that works in
# exactly one account.

output "queue_url" {
  description = "HTTPS URL of the queue. Read by the consuming service as SQS_*_QUEUE_URL."
  value       = aws_sqs_queue.this.id
}

output "queue_arn" {
  description = "ARN of the queue. Needed by any topic subscription the caller creates itself — payzeno-console-notifications' second subscription uses this."
  value       = aws_sqs_queue.this.arn
}

output "queue_name" {
  description = "Resolved queue name, environment prefix included. This is the QueueName CloudWatch dimension and the string you paste into the console."
  value       = aws_sqs_queue.this.name
}

output "dlq_url" {
  description = "HTTPS URL of the dead-letter queue. payzeno-api's DeadLetterConsumer reads the DLQ-monitor one as SQS_DLQ_URL."
  value       = aws_sqs_queue.dlq.id
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Resolved DLQ name — always <queue>-dlq. The redrive command in the runbook uses this."
  value       = aws_sqs_queue.dlq.name
}

output "subscribed_event_types" {
  description = "The event types this queue's filter policy admits. Exposed so envs/*/messaging.tf can assert the union across all queues against EVENT_TYPES and prove which three are deliberately unconsumed."
  value       = local.filter_event_types
}

output "age_alarm_arn" {
  description = "ARN of the oldest-message-age alarm."
  value       = module.age_alarm.alarm_arn
}

output "depth_alarm_arn" {
  description = "ARN of the queue-depth alarm."
  value       = module.depth_alarm.alarm_arn
}
