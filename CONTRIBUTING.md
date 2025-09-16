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
