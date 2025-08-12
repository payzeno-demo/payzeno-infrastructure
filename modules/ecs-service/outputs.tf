# modules/ecs-service — outputs.
#
# These names are the module's interface to both environment roots. Renaming one silently
# breaks every reference in envs/*/services.tf and envs/*/routing.tf; terraform will tell
# you, but only for the references it can see, and only at plan.

output "service_arn" {
  description = "ARN of the ECS service."
  value       = aws_ecs_service.this.id
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix, for CloudWatch dimensions in the env roots' own alarms."
  value       = local.is_alb_fronted ? aws_lb_target_group.this[0].arn_suffix : null
}

output "task_role_arn" {
  description = "ARN of the application role. Hand this to a queue or topic policy that needs to name the consumer."
  value       = aws_iam_role.task.arn
}

output "log_group_name" {
  description = "CloudWatch log group the containers write to."
  value       = aws_cloudwatch_log_group.this.name
}

output "discovery_dns" {
  description = <<-EOT
    Service-discovery DNS name. The first label equals the docker-compose service name,
    which is what makes LEDGER_BASE_URL resolve to the same node in both planes.
    envs/production/services.tf's `check "unique_discovery_dns"` block compares these.
  EOT
  value       = "${aws_service_discovery_service.this.name}.${var.environment}.payzeno.internal"
}

