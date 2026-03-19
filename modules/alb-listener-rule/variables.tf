# modules/alb-listener-rule — inputs.
#
# Read the priority validation before you add a rule. ALB evaluates rules
# lowest-priority-first and stops at the first match. A deny that sits numerically after
# the forward it is supposed to shadow is not a deny, it is a comment. We shipped exactly
# that for five months — see README "Gotchas" and PAY-1811.

variable "service" {
  description = "Owning service, for naming and tags. e.g. payzeno-api."
  type        = string
}

variable "environment" {
  description = "production | staging."
  type        = string
}

variable "name" {
  description = "Short rule name. Becomes part of the tag Name — e.g. v1, internal-deny, ws-notifications."
  type        = string
}

variable "listener_arn" {
  description = "ARN of the HTTPS listener this rule attaches to."
  type        = string
}

variable "priority" {
  description = "Evaluation order, LOWEST FIRST. Denies live in 1-99, forwards in 100+, catch-alls in 500+."
  type        = number

  validation {
    condition     = var.priority >= 1 && var.priority <= 50000
    error_message = "PAYZENO_INFRA_INVALID_INPUT: priority must be in [1, 50000]. It must also be unique on the listener — terraform will not tell you it is not, the API will, at apply, halfway through."
  }
}

variable "path_patterns" {
  description = "Path patterns matched by this rule. ALB globs, not regexes: /internal/* not ^/internal/."
  type        = list(string)

  validation {
    condition     = length(var.path_patterns) > 0 && length(var.path_patterns) <= 5
    error_message = "PAYZENO_INFRA_INVALID_INPUT: between 1 and 5 path patterns. Five is the ALB limit per condition, not ours."
  }

  validation {
    condition = alltrue([
      for p in var.path_patterns : startswith(p, "/")
    ])
    error_message = "PAYZENO_INFRA_INVALID_INPUT: path patterns are absolute and start with /."
  }
}

variable "host_headers" {
  description = "Optional host-header condition. Empty means the rule matches on path alone."
  type        = list(string)
  default     = []
}

variable "action" {
  description = "forward | deny. deny returns a fixed 404 — never a 403, which confirms the path exists."
  type        = string
  default     = "forward"

  validation {
    condition     = contains(["forward", "deny"], var.action)
    error_message = "PAYZENO_INFRA_INVALID_INPUT: action must be forward or deny."
  }
}

variable "target_group_arn" {
  description = "Target group for a forward action. Must be null for a deny."
  type        = string
  default     = null
}

variable "stickiness_duration" {
  description = "Target-group stickiness in seconds for this rule. 0 disables it. Only the WebSocket rule uses it."
  type        = number
  default     = 0
}

variable "extra_tags" {
  description = "Merged under the standard tag set."
  type        = map(string)
  default     = {}
}
