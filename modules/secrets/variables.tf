# modules/secrets — inputs.
#
# Split out in month 7 during the PCI wave, when this module went from "two secrets for
# the api" to the thing every task definition depends on. The outputs stayed at the
# bottom of main.tf and nobody has minded enough to move them. CONTRIBUTING.md §4 says
# split means both files; this is half of one. It is on the list.

variable "service" {
  description = "Owning service. Secrets are namespaced per service — payzeno-api cannot read payzeno-ledger's."
