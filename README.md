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

## Who to ask

Infra owns this repo and reviews everything in it. `envs/production/` needs a second pair of
eyes on top of that. If you are a service team adding an env var for your own service, open
the PR — that is the normal path and it is fine. If the diff touches `modules/`, `nginx/` or
routing, talk to us first; those changes are cheap to write and expensive to be wrong about.

On-call: `docs/runbooks/oncall.md`. Deploys: `docs/runbooks/deploys.md`. Both are current;
if you find one that is not, fix it in the same PR as whatever proved it wrong.
