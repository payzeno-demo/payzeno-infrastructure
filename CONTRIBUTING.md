# Contributing to payzeno-infrastructure

Short version: one approval, two for `envs/production/`, `make ci` green, plan text in the
PR body. Longer version below, plus the conventions that are not obvious from reading the
code.

---

## 1. Branches, commits, PRs

- Branch: `<type>/PAY-<num>-<slug>` — e.g. `feat/PAY-1841-ledger-retry-drain-alarm`.
- Commit subject: conventional — `feat(infra):`, `fix(nginx):`, `chore(tf):`.
- PR title carries the ticket key. The Jira link is not optional; half of what this repo
  does only makes sense next to the ticket that asked for it.
- One reviewer by default. **Two for anything under `envs/production/`**, and one of them
  is infra.
- Paste the plan. `make plan ENV=production` writes `envs/production/plan.txt`; that goes
  in the PR body. Do not attach the binary `tfplan` — it renders resolved secret values.

Applies are manual, from a laptop, with the infra role assumed. CI plans and lints; it never
applies. If you need something applied, say so on the PR and infra will do it.

---

## 2. Provider pins and the lock file

`.terraform.lock.hcl` **is committed**, for both roots. CI regenerates it and fails on a
diff, so a provider bump is a deliberate two-file change: the constraint in `versions.tf`
and the lock.

The two roots are pinned differently on purpose right now (production `~> 5.49`, staging
`~> 5.42`). That is drift, it is tracked, and it is not something to "just fix" in an
unrelated PR — the last attempt produced a 400-line tag-only plan diff on a Friday evening
and got reverted the same night.

Lock refresh:

```bash
make lock ENV=production   # darwin_arm64 + linux_amd64 + linux_arm64
```

---

## 3. Failure surface — say it out loud, in one of three tiers

Terraform has no exceptions, so the equivalent question — *how does this fail, and does it
fail loudly?* — has to be answered on purpose. A module where nothing can fail is not a
simple module, it is an untested one.

Three tiers. Each has a greppable message prefix. Use the right one.

### `PAYZENO_INFRA_PRECONDITION` — `lifecycle { precondition { ... } }`

Invariants that depend on resolved values, not just inputs — a relationship between two
things rather than a property of one. Examples:

- `ecs-service`: a `secrets[]` entry exists for every key named in `var.secrets`
- `rds-postgres`: `multi_az` is true when `environment == "production"`
- `secrets`: KMS key rotation is enabled in production
- `sqs-queue`: a DLQ exists for every queue with a redrive policy

### `PAYZENO_INFRA_DRIFT` — `check { assert { ... } }`

Things that are true today, that a future PR could quietly make untrue, and where failing
the *plan* is too aggressive but a warning on every run is right. Only `envs/production/`
carries these:

- the `/internal/` deny rule's priority is lower than the `/v1/` forward's
- every contracted queue has exactly one subscription — except
  `payzeno-console-notifications`, which must have two
- no two `ecs-service` instantiations share a `discovery_dns`

Staging has no `check` blocks. Staging does not page anyone; a check that nobody reads is
noise.

**If you add a module, add at least one validation to it.** A module with no failure surface
is a module that will be misused.

---

## 4. Module conventions

- Everything composes down to `modules/naming`. Derive ids, DNS names, log group names and
  tags from it. Do not write a resource name as a string literal.
- Merge `module.names.tags` into every resource's tags. `Team`, `Repo`, `ManagedBy`,
  `Service`, `Environment`, `Component` are how cost allocation works.
- **Modules under 60 lines keep their `variable` and `output` blocks in `main.tf`. Larger
  modules split them into `variables.tf` and `outputs.tf`.**
- Every variable is typed and has a `description`. tflint enforces both.
- A module's variable and output names are its interface. Renaming an output silently
  breaks every caller's reference — grep the whole repo before you do it, and expect the
  PR to be reviewed as a breaking change.

Current state, honestly: `ecs-service`, `rds-postgres` and `sqs-queue` are split correctly.
`naming`, `cloudwatch-alarm` and `sns-topic` are correctly inline. `nginx-sidecar`,
`secrets`, `alb-listener-rule` and `static-site` are split when they did not need to be —
harmless, not worth a churn PR. `rds-mysql` is inline when it should not be, along with
everything else wrong with it; that one is a real ticket and has been for a while.

---

## 6. Things that need a conversation first

Open a ticket and talk to infra before you write the PR:

- anything in `modules/` beyond adding an optional variable
- ALB rules, listener changes, TLS policy
- `nginx/` — especially the `^/internal/` deny and the log format, both of which are PCI
  scope and have compliance docs pointing at them
- deleting a queue, topic or subscription
- `modules/rds-mysql`, at all
- moving a `/internal/v1/` route between upstreams — that is the strangler boundary, and
  which service owns which prefix is a product decision with a flag attached to it

Everything else: open the PR.
