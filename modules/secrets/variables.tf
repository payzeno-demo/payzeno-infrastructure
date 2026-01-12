# modules/secrets — inputs.
#
# Split out in month 7 during the PCI wave, when this module went from "two secrets for
# the api" to the thing every task definition depends on. The outputs stayed at the
# bottom of main.tf and nobody has minded enough to move them. CONTRIBUTING.md §4 says
# split means both files; this is half of one. It is on the list.

variable "service" {
  description = "Owning service. Secrets are namespaced per service — payzeno-api cannot read payzeno-ledger's."
  type        = string
}

variable "environment" {
  description = "production | staging."
  type        = string
}

variable "secret_names" {
  description = <<-EOT
    Logical secret names, which become BOTH the Secrets Manager path leaf and the env var
    name injected into the container. These are the names in interfaces.md §7 — e.g.
    SESSION_SECRET, WORLDFLOW_API_KEY, DATABASE_URL. The value is never in terraform:
    terraform creates the container and an initial random placeholder, a human rotates it.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.secret_names) > 0
