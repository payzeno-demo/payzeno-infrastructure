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

