# envs/production/services.tf
#
# The five ECS services (six instantiations — the ledger has a canary) and the ingress nginx
# config. This is the most-edited file in the repo: every env-var change in the org lands
# here and in docker-compose.yml, in that order, in the same PR.
#
# Names are load-bearing in three directions at once:
#   * `service` matches the docker-compose service name -> the graph joins the two planes
#   * `service` is the first label of the service-discovery DNS name -> LEDGER_BASE_URL and
#     PAYZENO_LEDGER_BASE_URL resolve to the same node instead of to two string literals
#   * every key in environment_vars is validated against interfaces.md §7
#
# Values here are AWS values. The same NAMES appear in docker-compose.yml with localstack
# values. AWS_ENDPOINT_URL is the one key that exists there and must never exist here.

locals {
  # -------------------------------------------------------------------------
  # payzeno-api
  # -------------------------------------------------------------------------
  api_env = {
    NODE_ENV = "production"
    PORT     = "8080"

    LEDGER_BASE_URL         = "http://payzeno-ledger.production.payzeno.internal:8000"
    BILLING_LEGACY_BASE_URL = "http://payzeno-billing-legacy.production.payzeno.internal:8090"
    VAULT_BASE_URL          = "http://payzeno-vault.production.payzeno.internal:8099"
    VAULT_PUBLIC_URL        = local.vault_public_origin
    BILLING_LEGACY_USER     = "payzeno_api"

    WORLDFLOW_BASE_URL = "https://api.worldflow.com"
