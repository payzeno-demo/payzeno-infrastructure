# ADR 0003 — One compose file, in the infrastructure repo

- **Status:** accepted
- **Date:** month 2
- **Author:** `apager`
- **Reviewer:** `dhotfix`
- **Ticket:** PAY-1247
- **Supersedes:** nothing. This is the first ADR in this repo.

## Context

Five repos, four of which build a container. Each one arrived with its own
`docker-compose.yml`, because each one was written by whoever started it and each one needed
to run locally.

By the end of month 1 that meant:

- `payzeno-api`'s compose file defined a Postgres, a Redis and a **stub** ledger.
- `payzeno-ledger`'s compose file defined a different Postgres and no api at all.
- `payzeno-billing-legacy`'s compose file used MySQL 5.7. Production was on 8.
- Three different names for the same Postgres container, so three different
  `DATABASE_URL` values in three `.env.example` files.
- Nobody could run the whole platform. Testing an api change against the real ledger meant
  hand-editing two compose files and getting the network name right.

The concrete failure that produced this ADR: a `merchant.status_changed` consumer was written
against a stub that published a payload with `status` where the real event has `new_status`.
It passed every local test. It failed in staging, and the reason it failed was that the stub
and the contract had never been in the same file as each other.

## Decision

**There is exactly one file that defines a service, and it is
`payzeno-infrastructure/docker-compose.yml`.**

1. All eleven services are defined there: `payzeno-nginx`, `payzeno-api`, `payzeno-ledger`,
   `payzeno-billing-legacy`, `payzeno-console`, `payzeno-vault`, `payzeno-postgres-api`,
   `payzeno-postgres-ledger`, `payzeno-mysql-billing`, `payzeno-redis`,
   `payzeno-localstack`.
2. The four first-party services are **built from source**, not pulled:
   `build.context: ../payzeno-api` and so on. The service repos are expected to be checked
   out as siblings. This is a deliberate constraint — it means you cannot run the stack
   against an image whose source you do not have.
3. A service repo may carry a thin `docker-compose.override.yml` that `extends:` the root
   file's definition of **its own** service, for bind mounts and debug ports. It may not
   define a service, and it may not define anybody else's.
4. **Compose service names, terraform module names and service-discovery DNS labels are the
   same strings.** `payzeno-ledger` is the compose service, `module.payzeno_ledger` is the
   ECS service, and `payzeno-ledger.production.payzeno.internal` is what
   `LEDGER_BASE_URL` resolves to. Three planes, one name.
5. **Environment variable names are identical between compose and terraform.** Values differ
   — localstack against real AWS — names never do. `modules/ecs-service` has a `validation`
   block that rejects a key outside the contracted list, which is the mechanism that keeps
   this true rather than aspirational.
6. Ports match between the two planes: api 8080, ledger 8000, legacy 8090, vault 8099.
   Every service serves `/healthz` and every healthcheck hits it.
7. `AWS_ENDPOINT_URL` is the **one** intentional asymmetry. It points at localstack, exists
   only in compose, and is rejected by terraform.

## Consequences

**Good.**

- The compose file is a readable topology diagram. `depends_on` is the service graph, and it
  is the only place it is written down once.
- A new engineer runs `make up` and has the platform. That was not true before and it is the
  single biggest thing this decision bought.
- Env-var drift between local and production is a plan error rather than a staging surprise.
- Local development goes through the same nginx config as the container plane in ECS, so the
  `^/internal/` deny is exercised locally.

**Bad, and we knew it at the time.**

- **The compose file is a merge-conflict magnet.** Every team edits it. It co-changes with
  `envs/production/services.tf` on about 70% of its commits, and both of them are in the
  top three most-edited files in the repo. This is the price and we are still paying it.
- Infra reviews changes to a file that is mostly other people's business. That is fine when
  it is an env var, and it slows people down when it is not.
- First boot is slow: the legacy service compiles, and localstack has to create four SNS
  topics, eight SQS queues, the redrive policies and the buckets before anything that
  publishes will start.
- `init-aws.sh` creates the same topic and queue names `envs/*/messaging.tf` creates, in a
  second place, by hand. Adding a queue in terraform and not there is a real and recurring
  mistake. There is no mechanism preventing it — only the comment saying so.

## Alternatives considered

**Per-repo compose files with a shared network.** Rejected: it is what we had, and "shared
network" turns out to mean "everyone hardcodes the same network name and one person gets it
wrong".

**A separate `payzeno-devstack` repo.** Rejected: a sixth repo that has to be checked out and
kept in step with five others, owned by nobody in particular. The compose file belongs next to
the terraform that mirrors it, because the two have to agree and reviewing them together is
the only thing that makes that happen.

**Pre-built images from ECR instead of `build.context`.** Rejected then, and it comes up again
about twice a year. It would make first boot much faster. It would also make it possible to
run the stack against an image whose source you do not have checked out, which is precisely
the class of confusion this ADR exists to remove. If we revisit it, the compromise is probably
pulled images for `payzeno-vault` (already a vendor image) and built for the four we own —
which is what we do today.
