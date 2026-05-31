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
    error_message = "PAYZENO_INFRA_INVALID_INPUT: secret_names must not be empty. A secrets module with no secrets is a KMS key nobody uses."
  }

  validation {
    condition = alltrue([
      for n in var.secret_names : can(regex("^[A-Z][A-Z0-9_]*$", n))
    ])
    error_message = "PAYZENO_INFRA_INVALID_INPUT: secret names are SCREAMING_SNAKE — they are injected verbatim as env var names and must match interfaces.md §7."
  }
}

variable "rotation_days" {
  description = "Automatic rotation window. 0 disables rotation (the acquirer keys, which are rotated by hand with the acquirer on the phone)."
  type        = number
  default     = 90

  validation {
    condition     = var.rotation_days == 0 || (var.rotation_days >= 30 && var.rotation_days <= 365)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: rotation_days must be 0 (manual) or between 30 and 365."
  }
}

variable "recovery_window_days" {
  description = "Deletion recovery window. 0 means immediate destroy and is only acceptable in staging."
  type        = number
  default     = 30
}

variable "kms_deletion_window_days" {
  description = "Waiting period before the CMK is actually destroyed."
  type        = number
  default     = 30
}

variable "purpose" {
  description = <<-EOT
    Disambiguator when one service has more than one secrets module. Empty for the default
    instantiation; "db" for the credentials rds-postgres creates, "cache" for the Redis URL,
    "platform" for the shared api secrets. It only affects the CMK alias and the CMK's Name
    tag — the secret paths are keyed on the secret name and never collided.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.purpose == "" || can(regex("^[a-z][a-z0-9-]*$", var.purpose))
