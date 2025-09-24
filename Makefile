# payzeno-infrastructure
#
# Two things live in this repo and they have nothing to do with each other:
#   1. terraform under envs/ and modules/  -> `make fmt validate lint plan`
#   2. the local stack under docker-compose -> `make up logs down`
#
# ENV defaults to staging on purpose. If you meant production, say production.

ENV ?= staging
ROOT := envs/$(ENV)
TF   := terraform -chdir=$(ROOT)

COMPOSE := docker compose -f docker-compose.yml -f docker-compose.override.yml

.DEFAULT_GOAL := help
.PHONY: help fmt fmt-check validate lint init plan apply lock docs-check ci \
        up down logs ps nginx-check compose-config seed localstack-queues clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# terraform
# ---------------------------------------------------------------------------

fmt: ## Rewrite HCL in place (repo-wide, both envs and all modules)
	terraform fmt -recursive .

fmt-check: ## CI gate: fail if anything is unformatted
	terraform fmt -check -recursive -diff .

init: ## terraform init for $(ENV). Uses the real S3 backend — needs creds.
	$(TF) init -input=false

validate: ## terraform validate for $(ENV) without touching the backend
	terraform -chdir=$(ROOT) init -backend=false -input=false >/dev/null
	$(TF) validate

lint: ## tflint over $(ENV), following module calls
	tflint --init --config=$(CURDIR)/.tflint.hcl
	tflint --chdir=$(ROOT) --config=$(CURDIR)/.tflint.hcl --recursive

plan: init ## terraform plan for $(ENV), written to $(ROOT)/tfplan
	$(TF) plan -input=false -lock-timeout=120s -out=tfplan
	$(TF) show -no-color tfplan > $(ROOT)/plan.txt
	@echo "--> paste $(ROOT)/plan.txt into the PR. Do NOT attach tfplan itself."

apply: ## terraform apply of an existing plan for $(ENV)
	@test -f $(ROOT)/tfplan || { echo "no plan for $(ENV) — run make plan ENV=$(ENV)"; exit 1; }
	$(TF) apply -input=false -lock-timeout=120s tfplan

lock: ## Refresh .terraform.lock.hcl for all platforms we run on
	$(TF) providers lock \
	  -platform=darwin_arm64 \
	  -platform=linux_amd64 \
	  -platform=linux_arm64

ci: fmt-check validate lint ## What .github/workflows/terraform.yml runs

# ---------------------------------------------------------------------------
# local stack
# ---------------------------------------------------------------------------

up: ## Bring up the whole local stack (all eleven services)
	$(COMPOSE) up -d --build
	@echo "--> api      http://localhost:8080/healthz"
	@echo "--> ledger   http://localhost:8000/healthz"
	@echo "--> legacy   http://localhost:8090/healthz"
	@echo "--> console  http://localhost/"
	@echo "--> internal http://localhost:8081/internal/v1/  (10.0.0.0/8 only in prod)"

down: ## Tear the local stack down, keeping volumes
	$(COMPOSE) down

clean: ## Tear down AND drop volumes. You will re-seed localstack.
	$(COMPOSE) down -v

ps: ## Container status
	$(COMPOSE) ps

logs: ## Tail everything (make logs SVC=payzeno-ledger for one service)
	$(COMPOSE) logs -f --tail=200 $(SVC)

compose-config: ## Resolve and validate the merged compose file
	$(COMPOSE) config -q && echo "compose OK"

nginx-check: ## nginx -t against nginx/ as the payzeno-nginx service actually loads it
	# NOT `docker run -v ./nginx:/etc/nginx/conf.d nginx -t`. That mount leaves the stock
	# main config in place, whose `include conf.d/*.conf` reaches payzeno-*.conf a second
	# time — nginx/nginx.conf already includes them — and nginx dies on a duplicate
	# upstream. The nginx-main config in docker-compose.override.yml is the fix, so the
	# check has to run through compose to see it.
	$(COMPOSE) run --rm --no-deps --entrypoint nginx payzeno-nginx -t

seed: ## Re-run the localstack bootstrap (topics, queues, buckets, secrets)
	$(COMPOSE) exec payzeno-localstack /etc/localstack/init/ready.d/init-aws.sh

localstack-queues: seed ## Alias for `seed`. payzeno-ledger's docker-compose.override.yml
	@echo "--> topics and queues created; see docker-compose.override.yml's localstack-init"
