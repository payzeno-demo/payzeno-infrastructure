# payzeno-infrastructure

Terraform for everything Payzeno runs, plus the root `docker-compose.yml` and the nginx
config that fronts it. Owned by Infrastructure. If it has an ARN, a port, or an environment
variable, it is defined here.

This repo is the **writer**. The five service repos are readers. A queue name, a service
name, a port and an env var name are all decided in this repo and consumed elsewhere — so
renaming something here is never a local change, even when the diff looks like one.

---

## What is in here

```
docker-compose.yml          the only place a service is defined. All eleven of them.
docker-compose.override.yml local-dev: bind mounts, debug ports, the fake acquirer, localstack init
nginx/                      the container-plane ingress. Carries the ^/internal/ deny.
modules/                    reusable terraform. Everything bottoms out in modules/naming.
envs/production/            the real one. Six concern files plus alarms_ledger.tf.
envs/staging/               drifted. One big stack.tf. See "gotchas".
docs/runbooks/              deploys.md and oncall.md. Read oncall.md before your first shift.
docs/adr/                   why the compose file is single, why the modules look like that.
```

Eleven compose services: `payzeno-nginx`, `payzeno-api`, `payzeno-ledger`,
`payzeno-billing-legacy`, `payzeno-console`, `payzeno-vault`, `payzeno-postgres-api`,
`payzeno-postgres-ledger`, `payzeno-mysql-billing`, `payzeno-redis`, `payzeno-localstack`.
Ports are the same in compose and in ECS, deliberately: api **8080**, ledger **8000**,
legacy **8090**, vault **8099**. Every one of them serves `/healthz` and every healthcheck
hits it.

---

## Running the stack locally

You need Docker with the compose plugin, and the five service repos checked out **as
siblings of this one** — compose builds from `../payzeno-api`, `../payzeno-ledger`,
`../payzeno-billing-legacy`, `../payzeno-console`. It does not pull images for them.

```
~/payzeno/
  payzeno-api/
  payzeno-ledger/
  payzeno-billing-legacy/
  payzeno-console/
  payzeno-infrastructure/   <- you are here
```

```bash
make up        # build + start everything, with the override file
make ps
make logs SVC=payzeno-ledger
make down      # keeps volumes
make clean     # drops volumes; you will re-seed localstack
```

First boot takes a while — the legacy service compiles, and localstack has to create the
four SNS topics, the eight SQS queues, the DLQ redrive policies and the S3 buckets before
anything that publishes will start. That is `init-aws.sh`, and it creates the *same* names
`envs/*/messaging.tf` creates. If you add a queue in terraform and not in `init-aws.sh`,
local and production stop agreeing and you will spend an afternoon on it.

Useful once it is up:

| | |
|---|---|
| console | http://localhost/ |
| api | http://localhost:8080/healthz |
| ledger | http://localhost:8000/healthz |
| legacy | http://localhost:8090/healthz |
| internal listener | http://localhost:8081/internal/v1/ |
| localstack | http://localhost:4566 |

The internal listener is only reachable from `10.0.0.0/8` in production. Locally it is open,
which is the point — `/internal/v1/*` is how the services talk to each other and you cannot
debug it if you cannot curl it.

Your service repo has a thin `docker-compose.override.yml` of its own that `extends:` the
service defined here. Use that for your bind mounts. Do not define your service a second time.

---

## Working on the terraform

```bash
make fmt                       # rewrite in place, repo-wide
make validate ENV=staging      # init -backend=false + validate
make lint     ENV=staging      # tflint, following module calls
make plan     ENV=staging      # needs the infra role; writes plan.txt
make apply    ENV=staging      # applies the plan you just made, nothing else
```

`ENV` defaults to `staging`. That is not an accident.

CI runs `fmt -check`, `validate` and `tflint` against **both** roots, plus
`docker compose config` and `nginx -t`. It never applies. Apply is a human with the role
assumed, from a laptop, with the plan text pasted into the PR.

Everything in `modules/` composes down to `modules/naming`, which derives ids, DNS names,
log group names and the standard tag set from `(service, environment, component)`. If you
are writing a resource name as a string literal, you are doing it wrong — call `naming` and
use `module.names.id`. (`modules/rds-mysql` does exactly this wrong thing. It is from month
one. Leave it alone; see below.)

---

## Gotchas

Things that have cost someone an evening. In rough order of how likely they are to cost you one.

**The two ingress planes must agree, and once they did not.** nginx has the `^/internal/`
deny; the ALB has `module.rule_api_internal_deny`. They are supposed to be equivalent. For
five months the ALB rule sat at priority 400, *after* the `/v1/` forward at 100 — ALB
evaluates lowest first, so the deny never fired. nothing broke, because nginx caught it in
the container plane, but the ALB rule was inert the whole time. It is priority 10 now and
there is a `check "internal_deny_precedes_v1"` block in `envs/production/routing.tf` so it
cannot regress. If you add an ALB rule, check where it lands in the ordering.

**Staging is not a smaller production.** Production was split into six files in month 4.
Staging never was — `envs/staging/stack.tf` is one long file with all six services, all four
data stores and the ALB rules in it. Staging also pins `aws ~> 5.42` against production's
`~> 5.49`, has no alarms, and has no `check` blocks. It does not page anyone. A change that
plans clean in staging can still be wrong in production, and CI validating both roots is the
only thing that catches the easy half of that.

**`envs/production/alarms_ledger.tf` uses raw `aws_cloudwatch_metric_alarm` resources**,
not `modules/cloudwatch-alarm`, unlike every other alarm in the repo. It was written at 03:40
during the duplicate-settlement incident and never refactored. `docs/postmortems/` in the
ledger repo names those resource addresses literally. Refactoring the file means updating
them together — it is a real ticket, not a drive-by.

**`modules/rds-mysql` is pre-convention and load-bearing.** No `variables.tf`, no `naming`
call, resource names hardcoded (including one that says `prod` in staging), and a hand-built
`jdbc_url` output that `payzeno-billing-legacy` reads directly into
`SPRING_DATASOURCE_URL`. It also has `skip_final_snapshot = true` and
`deletion_protection = true`, which is a contradiction we are living with until the ledger
migration finishes. Two commits in twelve months. Do not modernise it as part of something
else.

**`terraform destroy` in this repo is never the answer.** Not in staging either — see
PAY-1522, which is the near-miss that added the deletion protection.

**Env vars are named in two places and the names must match exactly.** Once in
`docker-compose.yml` under `environment:`, once in an `environment_vars` or `secrets` map in
`envs/*/services.tf`. Values differ (localstack vs real AWS); names never do.
`modules/ecs-service` has a `validation` block on `environment_vars` that rejects a key not
on that service's list, which is annoying exactly once and then saves you.
`AWS_ENDPOINT_URL` is the one intentional asymmetry: compose only, never terraform.

**Secrets go in `secrets`, not `environment_vars`.** Anything that is a key, a password or a
pepper goes through `modules/secrets` and lands in the task definition's `secrets[]` block as
an ARN. We moved three plaintext API keys out of `environment[]` in month 7 and we are not
going back. A PR that puts a credential in `environment_vars` gets rejected on sight.

**Queue and topic names are frozen.** `payzeno-api-ledger`, not `payzeno_api_ledger`. The
list is in the service contracts, and `envs/*/messaging.tf` carries the filter policies
verbatim. Three event types are deliberately not subscribed by anything and there is a
comment saying so — that is not a bug to fix.

**`payzeno-console-notifications` has two topic subscriptions**, payments and ledger, each
with its own filter policy. It is the easiest thing in `messaging.tf` to delete by accident
while tidying.

---

## Who to ask

Infra owns this repo and reviews everything in it. `envs/production/` needs a second pair of
eyes on top of that. If you are a service team adding an env var for your own service, open
the PR — that is the normal path and it is fine. If the diff touches `modules/`, `nginx/` or
routing, talk to us first; those changes are cheap to write and expensive to be wrong about.

On-call: `docs/runbooks/oncall.md`. Deploys: `docs/runbooks/deploys.md`. Both are current;
if you find one that is not, fix it in the same PR as whatever proved it wrong.
