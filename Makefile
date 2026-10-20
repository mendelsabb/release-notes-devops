SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV ?= prod
VERSION ?=
DURATION ?= 90
TEST_DB_PORT ?= 55432
TEST_DB_URL := postgresql+psycopg://test:test@127.0.0.1:$(TEST_DB_PORT)/release_notes_test

##@ Lifecycle
.PHONY: up down clean status
up: ## Create the kind cluster and deploy everything (idempotent)
	@scripts/up.sh

down: ## Delete the kind cluster (ALL cluster data, incl. Postgres volumes, is lost)
	@scripts/down.sh

clean: down ## down + remove the local image registry and the git mirror remote
	@scripts/down.sh --registry

status: ## Show Argo CD, workload and endpoint status
	@scripts/status.sh

##@ Delivery (GitOps: every change below is a git commit Argo CD reconciles)
.PHONY: release promote rollback
release: ## Release VERSION=x.y.z to dev (github: version-bump PR, CI builds; local: local build)
	@scripts/release.sh "$(VERSION)"

promote: ## Promote the exact image digest running in dev to prod
	@scripts/promote.sh

rollback: ## Roll ENV (default prod) back to its previous image (git revert of image.yaml)
	@scripts/rollback.sh "$(ENV)"

##@ Demos and verification
.PHONY: traffic demo-rollout demo-broken-rollout demo-pod-kill demo-db-restart e2e
traffic: ## Run the in-cluster traffic generator against ENV for DURATION seconds
	@scripts/traffic.sh "$(ENV)" "$(DURATION)"

demo-rollout: ## Zero-downtime demo: traffic + release a new version + promote to prod
	@scripts/demo/rollout.sh

demo-broken-rollout: ## Failure demo: an image that never becomes Ready, then rollback
	@scripts/demo/broken-rollout.sh

demo-pod-kill: ## Failure demo: delete an API pod under traffic (CRASH=1: SIGKILL instead)
	@scripts/demo/pod-kill.sh

demo-db-restart: ## Failure demo: restart Postgres, verify data persists and recovery
	@scripts/demo/db-restart.sh

e2e: ## Verify a running stack end to end (API, persistence, metrics, logs, Argo CD)
	@scripts/verify.sh

##@ Development
.PHONY: lint test test-db validate image
lint: ## Ruff lint + format check, shellcheck
	uv run ruff check .
	uv run ruff format --check .
	shellcheck scripts/*.sh scripts/demo/*.sh

test: ## Unit + integration (throwaway Postgres in Docker) + Helm chart tests
	@trap 'docker rm -f rn-test-db >/dev/null 2>&1' EXIT; \
	docker rm -f rn-test-db >/dev/null 2>&1; \
	docker run -d --name rn-test-db -e POSTGRES_USER=test -e POSTGRES_PASSWORD=test \
	  -e POSTGRES_DB=release_notes_test -p 127.0.0.1:$(TEST_DB_PORT):5432 postgres:17.11-alpine >/dev/null; \
	until docker exec rn-test-db pg_isready -q -U test -d release_notes_test -h 127.0.0.1; do sleep 1; done; \
	REQUIRE_DB=1 TEST_DATABASE_URL=$(TEST_DB_URL) uv run pytest

validate: ## Helm lint/template for every environment + schema validation
	@scripts/validate-manifests.sh

image: ## Build the application image locally
	docker build -t release-notes:dev --build-arg APP_VERSION=dev --build-arg GIT_SHA=$$(git rev-parse --short HEAD) .

help:
	@awk 'BEGIN {FS = ":.*##"} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
