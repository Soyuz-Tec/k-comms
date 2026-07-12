CONTAINER_ENGINE ?= podman
COMPOSE ?= $(CONTAINER_ENGINE) compose
CONTAINER_BUILD_FLAGS ?= $(if $(filter podman podman.exe,$(notdir $(firstword $(CONTAINER_ENGINE)))),--format docker,)
IMAGE ?= localhost/k-comms:dev
PYTHON ?= python3
KUBE_OVERLAY ?= deploy/k8s/overlays/staging
PRODUCTION_OVERLAY ?= deploy/k8s/overlays/production
LOCAL_PROOF_OVERLAY ?= deploy/k8s/overlays/local-proof
PLATFORM_ROLE_OPERATION ?= deploy/k8s/operations/platform-role
PRODUCTION_BUNDLE ?=
TEST_DATABASE_URL ?= ecto://postgres:postgres@postgres:5432/k_comms_test

.PHONY: bootstrap dev stop logs shell check test format web-check contracts docs-check \
	validation-deps qualification-script-tests build container-smoke compose-validate \
	kube-validate production-preflight release clean

bootstrap:
	$(COMPOSE) up -d postgres minio minio-init
	$(COMPOSE) run --rm app sh -lc "mix local.hex --force && mix local.rebar --force && mix setup"

dev:
	$(COMPOSE) up --build app web

stop:
	$(COMPOSE) down --remove-orphans

logs:
	$(COMPOSE) logs -f app web

shell:
	$(COMPOSE) run --rm app iex -S mix

check:
	$(COMPOSE) run --rm -e MIX_ENV=test -e DATABASE_URL=$(TEST_DATABASE_URL) app \
		sh -lc "mix deps.get --check-locked && mix ecto.create && mix ecto.migrate && mix check"

test:
	$(COMPOSE) run --rm -e MIX_ENV=test -e DATABASE_URL=$(TEST_DATABASE_URL) app \
		sh -lc "mix deps.get --check-locked && mix ecto.create && mix ecto.migrate && mix test --warnings-as-errors"

format:
	$(COMPOSE) run --rm app mix format

web-check:
	$(COMPOSE) run --rm web sh -lc "npm ci --no-audit --no-fund && npm audit --omit=dev --audit-level=high && npm run lint && npm run typecheck && npm run test && npm run build"

validation-deps:
	$(PYTHON) -m pip install -r requirements-validation.txt

contracts:
	$(PYTHON) scripts/validate_contracts.py

docs-check:
	$(PYTHON) scripts/validate_docs.py

qualification-script-tests:
	node --test scripts/staging_acceptance.test.mjs \
		scripts/staging_product_acceptance.test.mjs \
		scripts/staging_load.test.mjs

build:
	$(CONTAINER_ENGINE) build $(CONTAINER_BUILD_FLAGS) --target runtime --tag $(IMAGE) .

container-smoke:
	CONTAINER_ENGINE=$(CONTAINER_ENGINE) IMAGE=$(IMAGE) bash scripts/container_smoke.sh

compose-validate:
	$(COMPOSE) config --quiet

kube-validate:
	@set -eu; \
		secrets="$(KUBE_OVERLAY)/secrets.env"; \
		created=0; \
		if [ ! -f "$$secrets" ]; then cp "$$secrets.example" "$$secrets"; created=1; fi; \
		trap 'if [ "$$created" = 1 ]; then rm -f "$$secrets"; fi' EXIT; \
		kubectl kustomize "$(KUBE_OVERLAY)" >/dev/null; \
		kubectl kustomize "$(KUBE_OVERLAY)/bootstrap" >/dev/null; \
		kubectl kustomize "$(LOCAL_PROOF_OVERLAY)" >/dev/null; \
		kubectl kustomize "$(PRODUCTION_OVERLAY)" >/dev/null; \
		kubectl kustomize "$(PLATFORM_ROLE_OPERATION)" >/dev/null

production-preflight:
	@test -n "$(PRODUCTION_BUNDLE)" || \
		(echo "set PRODUCTION_BUNDLE to the reviewed rendered provider bundle" >&2; exit 2)
	$(PYTHON) scripts/validate_production_bundle.py "$(PRODUCTION_BUNDLE)"

release:
	$(CONTAINER_ENGINE) build $(CONTAINER_BUILD_FLAGS) --target runtime --tag $(IMAGE) .

clean:
	$(COMPOSE) down -v --remove-orphans
	rm -rf _build deps cover doc clients/web/node_modules clients/web/dist
