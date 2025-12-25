PACKAGES := $(shell ls -1 packages)

.PHONY: help fmt fmt-check check test ci clean

help:
	@echo "oni dev commands"
	@echo ""
	@echo "make fmt        - format all Gleam packages"
	@echo "make fmt-check  - verify formatting"
	@echo "make check      - typecheck all packages"
	@echo "make test       - run tests for all packages"
	@echo "make ci         - run formatting + check + tests"
	@echo "make clean      - remove build artifacts"

fmt:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> formatting $$p"; \
	  (cd packages/$$p && gleam format); \
	done

fmt-check:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> fmt-check $$p"; \
	  (cd packages/$$p && gleam format --check); \
	done

check:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> check $$p"; \
	  (cd packages/$$p && gleam check); \
	done

test:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> test $$p"; \
	  (cd packages/$$p && gleam test); \
	done

ci: fmt-check check test

clean:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> clean $$p"; \
	  (cd packages/$$p && gleam clean); \
	done
