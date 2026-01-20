# Deploys

Two things get deployed and they are not the same thing.

| | What moves | Who does it | Rollback |
|---|---|---|---|
| **Application** | a container image tag on an ECS service | the service repo's CI, on merge to main | redeploy the previous tag |
| **Infrastructure** | terraform state | a human, from a laptop, with the plan pasted in the PR | `git revert`, plan, apply |

Terraform does **not** deploy applications. `aws_ecs_service` has
`lifecycle { ignore_changes = [task_definition] }` for exactly that reason: without it, a
`terraform apply` for an unrelated tag change would roll every service back to whatever image
sha was last written to state. The `local.images` map in `envs/*/main.tf` is what a *fresh*
environment gets created with. It goes stale between applies and that is expected. If you
want to know what is running, ask ECS, not this repo.

---

## Deploying an application

Merge to `main` in the service repo. Its CI builds, pushes to ECR, registers a new task
definition revision and calls `update-service`. Nothing here needs to happen.

Watch it:

```bash
export AWS_PROFILE=payzeno-production
export CLUSTER=payzeno-production
SVC=payzeno-api-production

aws ecs describe-services --cluster $CLUSTER --services $SVC \
  --query 'services[0].deployments[].{status:status,desired:desiredCount,running:runningCount,rollout:rolloutState}'
```

`deployment_circuit_breaker` is on with `rollback = true`, so a deploy whose tasks never
reach a healthy target group rolls itself back. Give it four minutes before you intervene.
`deployment_minimum_healthy_percent = 100` means capacity never dips during a deploy — which
also means a deploy of a service at `desired_count = 1` needs room for a second task.

Rolling back is redeploying the previous tag:

```bash
aws ecs update-service --cluster $CLUSTER --service $SVC \
  --task-definition payzeno-api-production:<previous-revision> \
  --force-new-deployment
```

Then say so in `#deploys` with the revision number. Do not roll back silently; the next
person to deploy will put the broken tag back.

---

### Reading a plan

Things worth stopping for, none of which terraform highlights:

- **`must be replaced`** on anything with data in it. An `aws_db_instance` replacement is a
  new empty database. An `aws_sqs_queue` replacement drops whatever is in the queue.
- **A target group replacement.** The service will be deregistered and re-registered; on a
  small `desired_count` that is a gap.
- **`known after apply` on a secret ARN.** Means the secret is being recreated, which means
  the value is being replaced with a random placeholder and a human has to set the real one
  again. Check `modules/secrets` before you approve that.
- **Nothing but tag churn.** Usually a provider version difference. It is safe and it is also
  400 lines nobody reads, which is how a real change hides in one. Split it out.

---

## Environment variables

The most common change in this repo, and the easiest to do half of.

1. `docker-compose.yml`, under the service's `environment:`.
2. `envs/production/services.tf` **and** `envs/staging/stack.tf`, in `environment_vars`.
3. Credentials go in `secrets` instead, backed by `modules/secrets`. Never in
   `environment_vars` — `modules/ecs-service` rejects anything that looks like one.
4. `modules/ecs-service/variables.tf`'s allowed-key list, and `local.allowed_env_keys` in
   `modules/ecs-service/main.tf` for the service's own list. Miss this and the validation
   rejects your own change with the exact reason.
5. The service repo's config module and `.env.example`.

Then deploy the **service**, not the infrastructure. A changed task definition does not reach
a running task until the service is redeployed:

```bash
aws ecs update-service --cluster $CLUSTER --service $SVC --force-new-deployment
```

This trips people up roughly monthly. `terraform apply` writes a new task definition
revision; the service keeps running the old one until something tells it not to.

Console `VITE_*` values are different again: they are build-time, stored in SSM, and baked
into the bundle by Vite. Changing one does nothing at all until the console is rebuilt and
redeployed. The SSM parameters carry a `Rebuild = required` tag as a reminder.

---

## Deploying the console

```bash
aws s3 sync dist/ "s3://$(terraform -chdir=envs/production output -raw console_bucket)/" \
  --delete --cache-control "public,max-age=31536000,immutable" --exclude index.html

aws s3 cp dist/index.html \
  "s3://$(terraform -chdir=envs/production output -raw console_bucket)/index.html" \
  --cache-control "no-cache"

aws cloudfront create-invalidation \
  --distribution-id "$(terraform -chdir=envs/production output -raw console_distribution_id)" \
  --paths /index.html
```

Assets are hashed and immutable; `index.html` is not and must never be cached. Invalidate
`/index.html` only — invalidating `/*` costs money and achieves nothing extra, because the
hashed asset paths change on every build.

---

## Database changes

Migrations belong to the service that owns the schema (alembic in payzeno-ledger, TypeORM in
payzeno-api, Flyway in payzeno-billing-legacy) and run from that service's deploy. Terraform
owns the instance, the parameter group and the connection budget, and nothing inside the
database.

If a migration needs a parameter change, they are two PRs in two repos and the terraform one
lands first. Note that a static parameter (`max_connections`, `shared_preload_libraries`)
needs a reboot, and `apply_immediately` is `false` by default — the change will sit pending
until the maintenance window. That has caught us: the month-7 ledger instance-class bump
waited six days while everyone assumed it had applied. `module.db_ledger` sets
`apply_immediately = true` now for exactly that reason.

---

## Provider and lock file

`.terraform.lock.hcl` is committed for both roots and CI fails on a diff. A provider bump is
two files:

```bash
# edit the constraint in envs/<env>/versions.tf, then
make lock ENV=<env>
```

The two roots are pinned differently on purpose (production `~> 5.49`, staging `~> 5.42`).
Do not unify them in a PR that is about something else. The last attempt produced a 400-line
tag-only plan diff at 18:00 on a Friday and was reverted the same night — PAY-1904.

---

## Never

- `terraform destroy`. Not in staging either. PAY-1522 is the near-miss that added
  `deletion_protection` to the billing MySQL, and that module still has
  `skip_final_snapshot = true`.
- `-auto-approve` against `envs/production/`.
- `-target`. If you need it, the dependency graph is wrong and the fix is in the code.
- Editing state by hand without a second person watching.
- Changing anything in the ECS or RDS console and leaving it there. Terraform will revert it
  on the next apply, at a moment nobody has chosen — probably during someone else's change.
