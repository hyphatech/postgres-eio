SWITCH ?= hypha-postgres-eio
OPAM = opam exec --switch=$(SWITCH) --

PG_TEST_PORT ?= 5435
PG_TEST_URL  ?= postgres://postgres_eio:postgres_eio@localhost:$(PG_TEST_PORT)/postgres_eio
export PG_TEST_PORT

DOCS_PORT ?= 4321

.DEFAULT_GOAL := help
.PHONY: help setup build test lint fmt docs docs-serve db db-down

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

setup: ## create the switch and install dependencies
	@podman compose version >/dev/null 2>&1 || echo "The tests need podman compose."
	@opam switch list --short | grep -qx $(SWITCH) || opam switch create $(SWITCH) --empty -y
	opam install . --switch=$(SWITCH) --deps-only --with-test --with-dev-setup -y

build: ## build everything
	$(OPAM) dune build @all

test: db ## run the tests
	POSTGRES_EIO_TEST_PG=$(PG_TEST_URL) $(OPAM) dune test --force

# Release is the profile opam installs with.
lint: ## check formatting, docs and the release build
	$(OPAM) dune build @all @fmt @doc
	$(OPAM) dune build --profile release @all

fmt: ## format the code
	$(OPAM) dune fmt

docs/node_modules: docs/package.json docs/bun.lock
	cd docs && bun install --frozen-lockfile
	@touch docs/node_modules

# odoc's reference from the .mli files, copied in for the site to serve,
# then the site built into _build/docs.
docs: docs/node_modules ## build the documentation site
	$(OPAM) dune build @doc
	rm -rf docs/public/reference
	mkdir -p docs/public/reference
	cd _build/default/_doc/_html && cp -R postgres-eio odoc.support $(CURDIR)/docs/public/reference/
	chmod -R u+w docs/public/reference
	cd docs && bun --bun astro build

# The built site, as Pages serves it: Pagefind's index exists only in a
# build, and a page served as it changes loads its styles after its text.
docs-serve: docs ## serve the built documentation site
	cd docs && bun --bun astro preview --open --port $(DOCS_PORT)

db: ## start the test database
	podman compose up -d --build --wait db

db-down: ## stop and delete the test database
	podman compose rm -sf db
