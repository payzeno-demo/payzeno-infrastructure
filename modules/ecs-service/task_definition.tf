# modules/ecs-service — the task definition.
#
# Split out of main.tf in month 4 because it is the part that changes. Every env-var PR in
# the org ends up touching envs/production/services.tf and this file, in that order.
#
# The container list is one or two entries:
#   [ <service> ]            vault, and anything not ALB-fronted
#   [ <service>, nginx ]     everything else — nginx listens on 80 and 8081 and proxies to
#                            the app on its own port over the loopback inside the task
#
# PCI, month 7 (PAY-1761 / PAY-1755). Two changes landed here in the same wave and both are
# non-negotiable now:
#   1. log retention dropped 365 -> 90 days for api and ledger. Request logs are in scope.
#   2. WORLDFLOW_API_KEY, NORDPAY_API_KEY and VAULT_API_KEY moved out of `environment[]` and
#      into `secrets[]`. `describe-task-definition` is an IAM-gated read that a lot of roles
#      have; it used to return three live acquirer credentials in plaintext. Three review
#      rounds with dhotfix and the rule is in CONTRIBUTING.md §5.3.

resource "aws_cloudwatch_log_group" "this" {
  name              = module.names.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(module.names.tags, {
    Name = module.names.log_group_name
  })
}

locals {
  log_configuration = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.this.name
      "awslogs-region"        = data.aws_region.current.name
      "awslogs-stream-prefix" = var.component == "" ? "app" : var.component
    }
  }

  # environment[] — plaintext only. The validation in variables.tf and the precondition in
  # main.tf between them guarantee nothing credential-shaped reaches this list.
  container_environment = [
    for k, v in var.environment_vars : {
      name  = k
      value = v
    }
  ]

  # secrets[] — { name, valueFrom }. Two sources: the ARNs a caller handed us (DATABASE_URL
  # from rds-postgres, REDIS_URL from the cache) and the secrets modules/secrets created for
  # this service. task_secrets is the projection that module exists to produce.
  caller_secrets = [
    for k, arn in var.secrets : {
      name      = k
      valueFrom = arn
    }
  ]

  module_secrets = length(module.task_secrets) > 0 ? module.task_secrets[0].task_secrets : []

  container_secrets = concat(local.caller_secrets, local.module_secrets)

  app_container = {
    name      = var.service
    image     = var.image
    essential = true

    portMappings = [{
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
      name          = "app"
    }]

    environment = local.container_environment
    secrets     = local.container_secrets

    logConfiguration = local.log_configuration

    # Same probe the ALB target group uses and the same one docker-compose uses. Three
    # places, one path, and it is /healthz everywhere.
    healthCheck = {
      command     = ["CMD-SHELL", "curl -fsS http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    # SIGTERM then 30s. The ledger's sweep checks a shutdown flag between items, so a clean
    # stop finishes the item it is on and does not leave a reconciliation_item in `settling`.
    stopTimeout = 30

    ulimits = [{
      name      = "nofile"
      softLimit = 65536
      hardLimit = 65536
    }]

    mountPoints = [
      for v in var.efs_volumes : {
        sourceVolume  = v.name
        containerPath = v.root_directory
        readOnly      = false
      }
    ]
  }

  sidecar_container = length(module.sidecar) > 0 ? [module.sidecar[0].container_definition] : []

  container_definitions = concat([local.app_container], local.sidecar_container)
}

data "aws_region" "current" {}

resource "aws_ecs_task_definition" "this" {
  family                   = module.names.id
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode(local.container_definitions)

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

