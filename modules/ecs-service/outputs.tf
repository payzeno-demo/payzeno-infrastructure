# modules/ecs-service — outputs.
#
# These names are the module's interface to both environment roots. Renaming one silently
# breaks every reference in envs/*/services.tf and envs/*/routing.tf; terraform will tell
# you, but only for the references it can see, and only at plan.

output "service_arn" {
  description = "ARN of the ECS service."
  value       = aws_ecs_service.this.id
}

output "service_name" {
  description = "Resolved ECS service name, e.g. payzeno-ledger-production-canary."
  value       = aws_ecs_service.this.name
}

output "target_group_arn" {
  description = "Target group the ALB forwards to. Null when the service is not ALB-fronted (the vault). Consumed by modules/alb-listener-rule in envs/*/routing.tf."
  value       = local.is_alb_fronted ? aws_lb_target_group.this[0].arn : null
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix, for CloudWatch dimensions in the env roots' own alarms."
  value       = local.is_alb_fronted ? aws_lb_target_group.this[0].arn_suffix : null
}

output "task_role_arn" {
  description = "ARN of the application role. Hand this to a queue or topic policy that needs to name the consumer."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the ECS agent role. Needs kms:Decrypt on any CMK wrapping a secret this task reads."
  value       = aws_iam_role.execution.arn
}

output "security_group_id" {
  description = "Security group of the task ENIs. RDS and ElastiCache ingress rules reference this."
  value       = aws_security_group.this.id
}

output "log_group_name" {
  description = "CloudWatch log group the containers write to."
  value       = aws_cloudwatch_log_group.this.name
}

output "task_definition_arn" {
  description = "ARN of the task definition revision terraform last wrote. Deploys move the service off this; it is a starting point, not the running revision."
  value       = aws_ecs_task_definition.this.arn
}

output "discovery_dns" {
  description = <<-EOT
    Service-discovery DNS name. The first label equals the docker-compose service name,
    which is what makes LEDGER_BASE_URL resolve to the same node in both planes.
    envs/production/services.tf's `check "unique_discovery_dns"` block compares these.
  EOT
  value       = "${aws_service_discovery_service.this.name}.${var.environment}.payzeno.internal"
}

output "base_url" {
  description = "http:// base URL for this service, ready to drop into another service's *_BASE_URL env var."
  value       = "http://${aws_service_discovery_service.this.name}.${var.environment}.payzeno.internal:${var.container_port}"
}

output "alarm_arns" {
  description = "ARNs of the three alarms this module creates, for composite alarms in the env roots."
  value = compact([
    module.cpu_alarm.alarm_arn,
    length(module.unhealthy_host_alarm) > 0 ? module.unhealthy_host_alarm[0].alarm_arn : null,
    module.task_stopped_alarm.alarm_arn,
  ])
}

output "managed_secret_arns" {
  description = "Secrets this module created for the service, name -> ARN. Empty unless managed_secret_names was set."
  value       = local.managed_secret_arns
}
