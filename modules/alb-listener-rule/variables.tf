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

