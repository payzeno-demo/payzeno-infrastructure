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
