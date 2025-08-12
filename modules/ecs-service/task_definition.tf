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
