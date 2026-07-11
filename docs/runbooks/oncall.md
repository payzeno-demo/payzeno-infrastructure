# On-call runbook

You are on the pager. It is 02:00. Read the section for the alarm that woke you and do what
it says. Do not start by reading code.

Every alarm carries a `Runbook` tag and its `alarm_description` ends with a link to a section
in this file. If you got paged by an alarm with no section here, that is a bug — file it in
the morning, and in the meantime page `@apager`.

**Three rules.**

1. **Stop the bleeding before you understand it.** Scaling something down, turning a flag
   off and disabling a schedule are all reversible. A wrong diagnosis at 02:00 is not.
2. **Say what you did, in `#incidents`, as you do it.** One line per action, with the
   timestamp. The postmortem is written from that thread and if it is not there it did not
   happen.
3. **Money problems are Sev1 by default.** If a merchant or a cardholder could have been
   charged twice, wake `@dhotfix`. Do not wait until you are sure.

Assume the role before anything else:

```bash
aws sso login --profile payzeno-production
export AWS_PROFILE=payzeno-production
export CLUSTER=payzeno-production
```

---

## duplicate-settlement

**Alarm:** `payzeno-ledger-production-duplicate-settlement` — Sev1.
**Also fires:** `payzeno-ledger-production-batch-overposted`, and the composite
`payzeno-ledger-production-settlement-integrity`.

The ledger has posted a second `purpose='settle'` transaction for a charge it had already
settled. **A duplicate settlement is internally balanced**, so the ledger's own imbalance
checks will not catch it and nothing else will tell you. If the merchant has
`capture_at_settlement = true`, the cardholder has been charged twice, for real, and the
clock on that is a chargeback.

Do this, in order.

**1. Stop the drain.** Scale the retry-drain canary to zero. It is the only task in
production with `RETRY_DRAIN_ENABLED=true`.

```bash
aws ecs update-service --cluster $CLUSTER \
  --service payzeno-ledger-production-canary --desired-count 0
```

**2. Scale the ledger to one task.** See [scale the ledger to one task](#scale-the-ledger-to-one-task)
below. One task cannot overlap itself.

**3. Count the damage.** The duplicate-finding query is in
`payzeno-ledger/docs/runbooks/reconciliation.md`, section "duplicate settlement detected".
Run it against the ledger read replica, not the writer.

```bash
aws rds describe-db-instances \
  --db-instance-identifier payzeno-ledger-production \
  --query 'DBInstances[0].Endpoint.Address'
```

**4. If any duplicate charge belongs to a `capture_at_settlement` merchant, wake `@dhotfix`
and open a Sev1.** That is a cardholder double-charge and it needs a refund run, not a
ledger correction. Cardholder remediation is a payzeno-api job — see PAY-2042 for the shape
of the last one.

**5. Only then** work out why. Start with `payzeno-ledger/docs/adr/0011-lock-ordering-in-the-money-path.md`.

**Known weakness of this alarm.** It is gated on `FLAG_DUPLICATE_SETTLEMENT_ALARM` in the
ledger's config (`envs/production/services.tf`, `local.ledger_env`). If that flag is turned
off, the metric stops being emitted and this alarm goes *quiet*, not red. Nothing here can
tell the difference between "no duplicates" and "no metric". If you are investigating a
suspected duplicate and this alarm never fired, check the flag before you conclude anything.

---

## scale the ledger to one task

The reconciliation sweep and the retry drain are two independent schedulers that both process
items in `RETRYABLE_STATUSES`. They serialise against *themselves* and not against each
other. One ledger task cannot overlap itself, so cutting to one task removes the concurrency
without turning anything off.

```bash
# current state first — write it in #incidents before you change it
aws ecs describe-services --cluster $CLUSTER \
  --services payzeno-ledger-production payzeno-ledger-production-canary \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount}'

aws ecs update-service --cluster $CLUSTER \
  --service payzeno-ledger-production --desired-count 1

aws ecs update-service --cluster $CLUSTER \
  --service payzeno-ledger-production-canary --desired-count 0
```

Application autoscaling will fight you. Suspend it first:

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/payzeno-ledger-production \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 --max-capacity 1
```

**One task is a degraded state, not a fix.** Settlement throughput drops to roughly a quarter
and the API's `/v1/settlements` reads get slower. It is survivable for hours, not for a day.
Put it back when the cause is fixed:

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/payzeno-ledger-production \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 4 --max-capacity 12

aws ecs update-service --cluster $CLUSTER \
  --service payzeno-ledger-production --desired-count 4
```

Then land the same numbers in `envs/production/services.tf` in a PR the same day. A console
change that terraform does not know about is a change that reverts itself on the next apply,
at a time nobody has chosen.

---

## reconciliation-lag

**Alarm:** `payzeno-ledger-production-reconciliation-lag` — Sev2.

The oldest item in a retryable status is over two hours old. The sweep is behind.

This is not itself an incident. It is the state that *precedes* one: a large retryable
backlog is what makes a sweep and a drain end up on the same item.

1. Check the acquirers first. Nine times out of ten the sweep is behind because Worldflow is
   returning 5xx and the breaker is open.

   ```bash
   aws logs tail /payzeno/production/payzeno-ledger --since 30m \
     --filter-pattern '"breaker"' --follow
   ```

2. Check the database is not the constraint —
   [database-connections-high](#database-connections-high).
3. If both are clean, look at `RECONCILE_MAX_ITEMS_PER_RUN` (2000) against the actual backlog.
   The sweep has a wall budget of 600s and will stop mid-backlog rather than run long.

Do **not** raise `RETRY_DRAIN_BATCH_SIZE` or widen `RETRY_DRAIN_ENABLED` to make this go
faster. That is what the drain is for and it is the thing that is not safe to run everywhere
until PAY-2059 lands the backoff and the breaker.

---

## retry-backlog

**Alarm:** `payzeno-ledger-production-retry-drain-depth` — Sev2.

More than 500 items are sitting in a retryable status.

The drain runs on **one** task (`module.payzeno_ledger_canary`, the only place
`RETRY_DRAIN_ENABLED=true`). It clears roughly 200 items a minute in the good case. Above
about 500 it cannot catch up inside a 900s sweep interval, which means the next sweep starts
while the drain is still working — and that is the overlap.

1. Find out why items are going retryable. It is almost always an acquirer.
2. If an acquirer is degraded: leave it. The breaker will do its job and the backlog will
   drain when the acquirer recovers. Hammering a degraded acquirer for 22 minutes is what we
   did last time and it is why PAY-2059 exists.
3. If the backlog is growing **and** the acquirers are healthy, treat it as a
   [duplicate-settlement](#duplicate-settlement) precursor: scale to one task and page.

---

## dead-letter-queue

**Alarm:** `*-dlq-not-empty`.

Something failed `max_receive_count` times in a row. One message is enough to page, on
purpose.

Look before you move anything:

```bash
aws sqs receive-message \
  --queue-url "$(aws sqs get-queue-url --queue-name ${QUEUE}-dlq --query QueueUrl --output text)" \
  --max-number-of-messages 10 --visibility-timeout 0 \
  --message-attribute-names All
```

If the cause is fixed, move them back:

```bash
aws sqs start-message-move-task \
  --source-arn "arn:aws:sqs:eu-west-1:418355290117:${QUEUE}-dlq" \
  --max-number-of-messages-per-second 10
```

There is no automation for this. That is PAY-2062 and it has been open since the postmortem.

---

## unhealthy-targets

**Alarm:** `*-unhealthy-hosts`.

Targets are failing `/healthz`.

```bash
SVC=payzeno-api-production

aws ecs describe-services --cluster $CLUSTER --services $SVC \
  --query 'services[0].events[:10]'

aws logs tail /payzeno/production/payzeno-api --since 15m --follow
```

The usual causes, in order of how often they are the cause:

1. A deploy just went out. Check `deployments[]` — the circuit breaker rolls back on its own,
   so give it four minutes before you touch anything.
2. The service cannot reach its database. Go to
   [database-connections-high](#database-connections-high).
3. A secret was rotated and the task cannot read it. The error is in the **ECS event stream**,
   not in the application logs, because the execution role fails before the container starts.

---

## tasks-below-desired

**Alarm:** `*-tasks-below-desired`.

Fewer tasks are running than `desired_count`. Either they are crashing or they cannot be
placed.

```bash
aws ecs describe-services --cluster $CLUSTER --services $SVC \
  --query 'services[0].events[:20]'

aws ecs list-tasks --cluster $CLUSTER --service-name $SVC --desired-status STOPPED
aws ecs describe-tasks --cluster $CLUSTER --tasks <arn> \
  --query 'tasks[0].{stopped:stoppedReason,containers:containers[].{n:name,r:reason,e:exitCode}}'
```

`OutOfMemoryError: Container killed due to memory usage` means the task `memory` in
`envs/production/services.tf` is too low for what the service is now doing. Raise it in a PR;
do not raise it in the console, because the next apply will put it back.

---

## service-cpu-high

**Alarm:** `*-cpu-high`.

Above 85% for five minutes. Autoscaling should already be reacting — check that it is:

```bash
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/$SVC --max-results 5
```

If it is at `autoscaling_max`, raise the max in a PR. If it is *not* scaling, the scalable
target has probably been pinned by hand during a previous incident and never unpinned — see
the end of [scale the ledger to one task](#scale-the-ledger-to-one-task).

For the ledger specifically: CPU is a poor proxy for its load, because its work is a queue
backlog and a blocked task is an idle task. On the night of PAY-2041 the ledger was 4,113
items behind and CPU said everything was fine. That is PAY-1912.

---

## database-cpu-high

**Alarm:** `*-db-cpu-high`.

```bash
aws rds describe-db-instances --db-instance-identifier payzeno-ledger-production \
  --query 'DBInstances[0].{class:DBInstanceClass,pg:DBParameterGroups[0].DBParameterGroupName,pi:PerformanceInsightsEnabled}'
```

Confirm the instance is actually on `payzeno-ledger-production-db-pg15`. If it is not, the
parameter group change is pending a reboot and `pg_stat_statements` is not loaded, which
means the next step will not work.

Then find the query. Performance Insights is on for both production instances (731-day
retention on the ledger), or from psql:

```sql
select calls, round(mean_exec_time::numeric, 1) as mean_ms,
       round(total_exec_time::numeric / 1000, 1) as total_s, query
from pg_stat_statements
order by total_exec_time desc
limit 20;
```

---

## database-connections-high

**Alarm:** `*-db-connections-high`.

The threshold is a *fraction* of `max_connections` (0.75 on the ledger since PAY-2041), not
a fixed number, so it cannot be made unreachable by raising the pool.

```sql
select state, count(*) from pg_stat_activity group by state;
select pid, state, now() - xact_start as xact_age, left(query, 80)
from pg_stat_activity
where state <> 'idle'
order by xact_start
limit 20;
```

- Lots of `idle in transaction` — a handler is holding a transaction open across an external
  call. That is a bug and it is the shape of the money-path lock problem; read
  `payzeno-ledger/docs/adr/0011-lock-ordering-in-the-money-path.md`.
- Lots of `active`, all short — you are out of pool, not out of database. Check task count ×
  `DATABASE_POOL_SIZE` against `max_connections` (`envs/production/data_stores.tf`,
  `module.db_ledger`). Four tasks × 20 = 80, plus the canary, plus alembic during a deploy.

Do not raise `DATABASE_POOL_SIZE` without raising `max_connections` in the same PR.
`modules/rds-postgres` has a precondition on the 3× rule and it will fail the plan, which is
what it is for.

---

## secrets and rotation

A task that will not start with no application logs at all is usually a secret it cannot
read. The failure is in the ECS event stream.

```bash
aws ecs describe-tasks --cluster $CLUSTER --tasks <arn> \
  --query 'tasks[0].stoppedReason'
```

`ResourceInitializationError: unable to pull secrets` means the execution role has lost
`secretsmanager:GetSecretValue` or `kms:Decrypt` on the CMK. Both are granted by named ARN in
`modules/ecs-service/iam.tf` — if a secret was recreated it has a new ARN and the apply that
created it is the one that fixed or broke this.

**`WEBHOOK_SIGNING_KEK` is not a normal secret.** It is the envelope key wrapping every
`webhook_endpoint.secret_ciphertext` row in `payzeno_api`. Rotating it re-wraps every
merchant's webhook secret and is a migration with a maintenance window, not a rotation.
`enable_key_rotation` is deliberately `false` on `aws_kms_key.webhook_signing`. Do not turn
it on at 02:00. PAY-1699.

---

## when it is over

- Put every console change into a PR the same day. Anything terraform does not know about
  reverts itself on the next apply.
- Postmortem within 48 hours, blameless, with the `#incidents` timeline pasted in as-is.
- One hardening ticket per contributing cause, not one per symptom.
- If the alarm that should have caught it did not exist, write it *before* the postmortem
  meeting. That is what `envs/production/alarms_ledger.tf` is, and it was written at 03:40
  because at 01:44 there was nothing to read.
