# modules/ecs-service — IAM.
#
# Two roles, and the distinction matters more than it looks:
#
#   execution role  is assumed by the ECS agent, before the container exists. It pulls the
#                   image, reads the secrets named in the task definition and writes to the
#                   log group. If this role is wrong the task never starts and the error is
#                   in the ECS event stream, not in your application logs.
#   task role       is assumed by the application. SNS publish, SQS consume, S3, KMS.
#                   If this role is wrong the application starts fine and fails on its first
#                   AWS call, which is usually four minutes later and looks like a bug.
#
# Least privilege here is per-service and derived, not a wildcard. The api may publish to
# the payments and merchant topics; the ledger may publish to the ledger topic; neither can
# publish to the other's. That is enforced by resource ARNs built from the naming module,
# not by a policy comment.

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "EcsTasksAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Confused-deputy guard: only tasks in this account, on this cluster.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${module.names.id}-exec"
  description        = "ECS agent role for ${var.service} (${var.environment}) — image pull, secret read, log write"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(module.names.tags, {
    Name = "${module.names.id}-exec"
  })
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

locals {
  # The ARNs the agent must be able to read at task-start. Both sources: what a caller
  # handed us and what modules/secrets created for this service.
  exec_secret_arns = sort(values(local.all_secret_arns))

  exec_kms_arns = compact([
    length(module.task_secrets) > 0 ? module.task_secrets[0].kms_key_arn : null,
  ])
}

data "aws_iam_policy_document" "exec" {
  statement {
    sid       = "WriteOwnLogGroup"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  # Named ARNs only. A GetSecretValue on * would let the api's execution role read the
  # ledger's DATABASE_URL, which is the whole thing we moved secrets here to avoid.
  dynamic "statement" {
    for_each = length(local.exec_secret_arns) > 0 ? [1] : []

    content {
      sid       = "ReadTaskSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.exec_secret_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.exec_kms_arns) > 0 ? [1] : []

    content {
      sid       = "DecryptTaskSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = local.exec_kms_arns
    }
  }

  # The sidecar's nginx.conf is pulled from S3 at task start by an init container. Read-only,
  # one object prefix.
  dynamic "statement" {
    for_each = length(module.sidecar) > 0 ? [1] : []

    content {
      sid       = "ReadSidecarConfig"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${module.sidecar[0].config_bucket_arn}/${module.names.id}/*"]
    }
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = "${module.names.id}-exec"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.exec.json
}

# ---------------------------------------------------------------------------
# Task role — what the application itself may do
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${module.names.id}-task"
  description        = "Application role for ${var.service} (${var.environment})"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(module.names.tags, {
    Name = "${module.names.id}-task"
  })
}

locals {
  arn_prefix = "arn:aws:%s:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}"

  # Which topics this service is allowed to publish to. Derived from the events.ts header
  # table: the api owns payments + merchant, the ledger owns ledger, legacy owns billing.
  publishable_topics = {
    "payzeno-api"            = ["payzeno-payments-events", "payzeno-merchant-events"]
    "payzeno-ledger"         = ["payzeno-ledger-events"]
    "payzeno-billing-legacy" = ["payzeno-billing-events"]
  }

  # Which queues it consumes. api-surface.md §14.
  consumable_queues = {
    "payzeno-api"            = ["payzeno-api-ledger", "payzeno-api-webhooks", "payzeno-console-notifications", "payzeno-api-billing", "payzeno-dlq-monitor"]
    "payzeno-ledger"         = ["payzeno-ledger-payments", "payzeno-ledger-merchants"]
    "payzeno-billing-legacy" = ["payzeno-billing-merchants"]
  }

  env_resource_prefix = var.environment == "production" ? "payzeno-" : "payzeno-staging-"

  topic_arns = [
    for t in lookup(local.publishable_topics, var.service, []) :
    "${format(local.arn_prefix, "sns")}:${replace(t, "payzeno-", local.env_resource_prefix)}"
  ]

  queue_arns = [
    for q in lookup(local.consumable_queues, var.service, []) :
    "${format(local.arn_prefix, "sqs")}:${replace(q, "payzeno-", local.env_resource_prefix)}"
  ]
}

data "aws_iam_policy_document" "task" {
  dynamic "statement" {
    for_each = length(local.topic_arns) > 0 ? [1] : []

    content {
      sid       = "PublishOwnTopics"
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = local.topic_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.queue_arns) > 0 ? [1] : []

    content {
      sid    = "ConsumeOwnQueues"
      effect = "Allow"
      actions = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      # The DLQ is a redrive target, so the consumer needs the *-dlq suffixed queues too.
      resources = concat(local.queue_arns, [for q in local.queue_arns : "${q}-dlq"])
    }
  }

  # Custom metrics. Payzeno/Ledger DuplicateSettlementDetected is published by the ledger's
  # SettlementPoster and is what aws_cloudwatch_metric_alarm.ledger_duplicate_settlement
  # watches (PAY-2055). Without this statement the alarm is on a metric nothing can write.
  statement {
    sid       = "PutOwnCustomMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Payzeno/${title(module.names.short_service)}"]
    }
  }

  statement {
    sid     = "TraceExport"
    effect  = "Allow"
    actions = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    # X-Ray's API is not resource-scoped. Nothing to narrow to.
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${module.names.id}-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}
