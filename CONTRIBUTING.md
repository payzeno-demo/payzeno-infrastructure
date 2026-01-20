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

### `PAYZENO_INFRA_PRECONDITION` — `lifecycle { precondition { ... } }`

Invariants that depend on resolved values, not just inputs — a relationship between two
things rather than a property of one. Examples:

- `ecs-service`: a `secrets[]` entry exists for every key named in `var.secrets`
- `rds-postgres`: `multi_az` is true when `environment == "production"`
- `secrets`: KMS key rotation is enabled in production
- `sqs-queue`: a DLQ exists for every queue with a redrive policy

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
