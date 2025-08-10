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

output "depth_alarm_arn" {
  description = "ARN of the queue-depth alarm."
  value       = module.depth_alarm.alarm_arn
}
