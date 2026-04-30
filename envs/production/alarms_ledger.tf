# envs/production/alarms_ledger.tf
#
# PAY-2055. Written at 03:40 on the postmortem day, straight after the hotfix went out.
#
# These are RAW aws_cloudwatch_metric_alarm resources, not modules/cloudwatch-alarm, which
# is against the convention in every other file in this repo. Two reasons, and only one of
# them is good:
#
#   1. metric math. ledger_batch_overposted divides one custom metric by another, and the
#      module takes a single metric_name. Adding metric_query support to the module at 03:40
#      was not going to happen.
#   2. it was 03:40.
#
# payzeno-ledger/docs/postmortems/2041-duplicate-settlement.md names these resource addresses
# literally, and so do PAY-2054 and PAY-2059. Refactoring this file onto the module means
