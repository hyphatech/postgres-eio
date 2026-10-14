PG_TEST_PORT ?= 5435
PG_TEST_URL  ?= postgres://postgres_eio:postgres_eio@localhost:$(PG_TEST_PORT)/postgres_eio
export PG_TEST_PORT

.DEFAULT_GOAL := help
.PHONY: help setup build test lint fmt doc db db-down

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

# dune builds the dependencies as it needs them (dune-workspace); setup
# brings dune's tools.
setup: ## install the formatter, odoc, the language server and Merlin
	@docker compose version >/dev/null 2>&1 || echo "The tests need docker compose."
	dune tools install ocamlformat
	dune tools install odoc
	dune tools install ocamllsp
	dune tools install ocamlmerlin

build: ## build everything
	dune build @all

test: db ## run the tests
	POSTGRES_EIO_TEST_PG=$(PG_TEST_URL) dune test --force

# Release is the profile opam installs with.
lint: ## check formatting, docs and the release build
	dune build @all @fmt @doc
	dune build --profile release @all

fmt: ## format the code
	dune fmt

doc: ## build the API docs into _build/default/_doc/_html
	dune build @doc

db: ## start the test database
	docker compose up -d --build --wait db

db-down: ## stop and delete the test database
	docker compose rm -sf db
