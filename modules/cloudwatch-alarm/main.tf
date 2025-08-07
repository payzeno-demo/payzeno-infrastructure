# modules/cloudwatch-alarm
#
# The one alarm primitive. Highest fan-in in the repo — ecs-service instantiates it
# three times, rds-postgres twice, sqs-queue once, and the env roots call it directly.
#
# Rule, and it is not negotiable: an alarm without a runbook is a 03:00 phone call with
# no instructions attached. `runbook_url` is required and validated. If there is no
