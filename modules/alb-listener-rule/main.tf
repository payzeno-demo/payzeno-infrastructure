# modules/alb-listener-rule
#
# One path-prefix rule on the public HTTPS listener. Either forwards to a target group or
# returns a fixed 404.
#
# This module is the AWS half of a pair. The other half is nginx/payzeno-api.conf, which
# carries the same rules in the container plane (interfaces.md §6.3, api-surface.md §1.1).
# They are supposed to be equivalent. When they are not, the container plane wins silently
# and you find out years later.
#
# The deny body is a 404, not a 403. A 403 on /internal/v1/merchants/mrc_123 tells an
# unauthenticated caller that mrc_123 exists. Same rule as MerchantScopeGuard in the api.
