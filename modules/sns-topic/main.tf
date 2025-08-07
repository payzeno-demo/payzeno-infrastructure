# modules/sns-topic
#
# One topic, KMS-encrypted, with a delivery policy that retries SQS delivery rather than
# dropping it. Small module, so variables and outputs stay here — CONTRIBUTING.md §4.
#
# Topic names are frozen by payzeno-contracts' events.ts header table. The `name` input
# is the *bare* topic name from that table (payzeno-ledger-events), and in staging it is
# prefixed to payzeno-staging-ledger-events. Do not "tidy" the name; five repos read it
# out of an env var that this module's ARN feeds.

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
  source = "../naming"

  # The topic is owned by whichever service publishes to it, but the *name* is the
  # bounded context, not the service. naming wants a payzeno- service string and gets
  # one; the component is what makes the id distinct.
  service     = var.name
  environment = var.environment
  component   = "topic"
  extra_tags  = var.extra_tags
}

resource "aws_sns_topic" "this" {
  name              = local.topic_name
  kms_master_key_id = var.kms_key_arn

  # SQS delivery only. If a subscription starts failing we want it retried for an hour
  # before the message lands in the topic's own failure feedback, not dropped in 30s.
  delivery_policy = jsonencode({
    http = {
      defaultHealthyRetryPolicy = {
        minDelayTarget     = 5
        maxDelayTarget     = 60
        numRetries         = 15
        numMaxDelayRetries = 10
        numNoDelayRetries  = 0
        numMinDelayRetries = 5
        backoffFunction    = "exponential"
      }
      disableSubscriptionOverrides = false
    }
  })

  tags = merge(module.names.tags, {
    Name           = local.topic_name
    BoundedContext = replace(replace(var.name, "payzeno-", ""), "-events", "")
  })
}

