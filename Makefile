.PHONY: bootstrap dev stop logs shell check test format contracts docs-check release clean
bootstrap:
	docker compose run --rm app sh -lc "mix local.hex --force && mix local.rebar --force && mix setup"
dev:
	docker compose up --build
stop:
	docker compose down
logs:
	docker compose logs -f app
shell:
	docker compose run --rm app iex -S mix
check:
	docker compose run --rm -e MIX_ENV=test app mix check
test:
	docker compose run --rm -e MIX_ENV=test app mix test
format:
	docker compose run --rm app mix format
contracts:
	python3 scripts/validate_contracts.py
docs-check:
	python3 scripts/validate_docs.py
release:
	docker compose run --rm -e MIX_ENV=prod app mix release k_comms --overwrite
clean:
	docker compose down -v --remove-orphans
	rm -rf _build deps cover doc
