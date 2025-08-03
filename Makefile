# payzeno-infrastructure
#
# Two things live in this repo and they have nothing to do with each other:
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

# terraform
# ---------------------------------------------------------------------------
