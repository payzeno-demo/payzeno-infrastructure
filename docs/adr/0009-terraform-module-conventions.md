# ADR 0009 — Terraform module conventions

- **Status:** accepted
- **Date:** month 4
- **Author:** `apager`
- **Reviewer:** `dhotfix`
- **Ticket:** PAY-1512
- **Related:** ADR 0003 (one compose file), `CONTRIBUTING.md` §3-§5

## Context

By month 4 there were eight modules and two environment roots, and no two modules agreed
about anything. `rds-mysql` hardcoded its resource names. `ecs-service` derived them from a
local. `sqs-queue` took a `name_prefix` that two of its three callers passed differently.
Tags were per-module and the cost report could not attribute half the account.

The specific thing that forced the decision: an ALB target group and a security group for the
same service ended up with names that differed by a hyphen, and it took forty minutes to work
out which one an error message was about. Nothing was broken. Everything was ambiguous.

Meanwhile `envs/production/` had become one 700-line file and a plan diff was unreadable.

## Decision

### 1. Names are derived, never spelled

Every module calls `modules/naming` and takes its ids, DNS names, log group names, parameter
prefixes and tags from it. `modules/naming` takes exactly three inputs —
`(service, environment, component)` — and is the terminal node of the module graph: it has no
resources and calls nothing.

A resource name written as a string literal is a name that will disagree with something else,
and you will find out from a graph or an error message rather than from a plan.

`modules/naming` is the one module written by `dhotfix` rather than `apager`. It was written
once, in month 2, and has not been touched since. That is the intended state.

### 2. Layering, and a deliberate module depth

Modules compose. The env roots do not talk to `aws_*` resources for anything a module owns:

```
envs/*/                 layer 0
  ecs-service           layer 1   -> nginx-sidecar, secrets, cloudwatch-alarm x3, naming
  rds-postgres          layer 1   -> secrets, cloudwatch-alarm x2, naming
  sqs-queue             layer 1   -> cloudwatch-alarm x3, naming
  static-site           layer 1   -> naming
  sns-topic             layer 2   -> naming
  alb-listener-rule     layer 2   -> naming
  secrets               layer 2   -> naming
  nginx-sidecar         layer 2   -> naming
  cloudwatch-alarm      layer 3   -> naming
  naming                layer 4   -> nothing
```

Four or five hops from an env root to a raw resource is not accidental depth. It is what
makes "change how every service is alarmed" a one-file change.

### 3. A module's variables and outputs are its interface

Renaming an output silently breaks every caller's reference. Treat it as a breaking change:
grep the repo, change all call sites in the same PR, and expect the review to be about that
rather than about the rename.

`modules/ecs-service`'s outputs (`target_group_arn`, `discovery_dns`, `security_group_id`,
`task_role_arn`, …) are referenced from both roots. `modules/rds-postgres`'s
`database_url_secret_arn` and `modules/rds-mysql`'s hand-built `jdbc_url` are each read
directly into a service's configuration.

### 4. Every module has a failure surface, in one of three named tiers

Terraform has no exceptions, so "how does this fail" has to be answered on purpose. Three
tiers, each with a greppable prefix:

- `PAYZENO_INFRA_INVALID_INPUT` — `variable { validation }`. Bad input, caught at plan.
- `PAYZENO_INFRA_PRECONDITION` — `lifecycle { precondition }`. An invariant between two
  resolved values.
- `PAYZENO_INFRA_DRIFT` — `check { assert }`. True today, could quietly stop being true.
  **Production only.**

A module with no validations is a module that will be misused. The two that have earned their
keep most often:

- `environment_vars` keys must be on the service's contracted list. This is why an env var
  name cannot silently differ between `docker-compose.yml` and `services.tf`.
- `runbook_url` on `cloudwatch-alarm` must be a non-empty `https://` link. An alarm without a
  runbook is a 03:00 phone call with no instructions attached.

Note the terraform version constraint interacts with this: on 1.7 a variable validation may
only reference its own variable. Cross-variable rules (`max_connections >= 3 ×
client_pool_size`) are therefore preconditions, not validations, and the variable-level check
is the weaker self-contained form of the same rule.

### 5. Small modules keep variables and outputs inline

Under about 60 lines of resource, `variable` and `output` blocks stay in `main.tf`. Larger
modules split them into `variables.tf` and `outputs.tf`.

### 6. Environment roots are split by concern

`envs/production/` is `versions`, `main`, `data_stores`, `messaging`, `services`, `routing`
(and later `alarms_ledger`). The dependency order runs data_stores and messaging before
services, because services consumes their outputs.

## Consequences

**Good.** Cost allocation works. A plan diff is readable. Adding an alarm to every service is
one file. The `check` blocks in `envs/production/` have caught two real regressions —
including the one that made them exist, `module.rule_api_internal_deny` sitting at priority
400 behind a forward at 100 for five months (PAY-1811).

**Bad.** Four hops to a resource means `terraform plan` output addresses are long and a
newcomer has to read three files to find where a security group is actually created. Module
cycles are a real constraint and not an obvious one: `modules/ecs-service` consumes
`module.db_*.database_url_secret_arn`, so the database modules cannot consume the service
security groups, and the ingress rules are declared in the env root instead. That looks like
a workaround because it is one.

**Where we do not comply, honestly:**

- `modules/rds-mysql` complies with none of this. No `variables.tf`, no `naming` call,
  hardcoded names — several of which say `prod` in both environments — inline tags missing
  `Team` and `Repo`, and outputs at the bottom of `main.tf`. It predates every rule here. It
  has had two commits in twelve months and `payzeno-billing-legacy`'s
  `SPRING_DATASOURCE_URL` comes out of its hand-built `jdbc_url`. Modernising it is a real
  ticket, and `terraform_standard_module_structure` is disabled in `.tflint.hcl` because of
  it. Do not do it on the way past something else.
- `envs/staging/` never got the §6 split. It is one `stack.tf` with the original month-1
  ordering. PAY-1780, open since month 4.
- `nginx-sidecar`, `secrets`, `alb-listener-rule` and `static-site` are split when §5 says
  they need not be. Harmless. Not worth a churn PR.
- `envs/production/alarms_ledger.tf` uses raw `aws_cloudwatch_metric_alarm` resources rather
  than `modules/cloudwatch-alarm`. One good reason (it needs metric math, which the module
  cannot express) and one honest one (it was written at 03:40). The postmortem and two
  hardening tickets name those resource addresses literally, so refactoring it means updating
  them together.

The gap between this document and the repo is not a failure of the document. It is the map of
where the repo grew faster than the convention, and every entry above is a ticket somebody
can pick up.
