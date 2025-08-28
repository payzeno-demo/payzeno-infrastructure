# TODO(apager): split like production — PAY-1780
#
# envs/staging/stack.tf
#
# Everything except the bus, which moved to messaging.tf in month 11. Six services, four
# data stores, the ALB and its rules, the console distribution. Production was split into
# concern files in month 4; this never was, and every time it nearly gets scheduled something
# that pages people wins instead.
#
# Ordering below is the original month-1 ordering: ALB first, then services, then data
# stores, then the console. Production reads the other way round. That is the main reason a
# diff between the two roots is hard to read, and it is the main reason PAY-1780 is worth
# doing.
#
# Staging is NOT a smaller production. Concretely, at time of writing:
#   * aws provider pinned ~> 5.42 here, ~> 5.49 there (versions.tf, PAY-1904)
#   * no alarm actions anywhere — the alarm resources exist and notify nobody
#   * no `check` blocks
#   * single-AZ databases, FARGATE_SPOT, one task per service
#   * IDEMPOTENCY_BACKEND differs from production (see the api block below)
# A change that plans and applies clean here can still be wrong there.

# ---------------------------------------------------------------------------
# ALB + rules
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "payzeno-staging-alb-sg"
