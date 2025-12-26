PACKAGES := $(shell ls -1 packages)
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

.PHONY: help fmt fmt-check check test ci clean build docs bench version info

help:
	@echo "oni development commands"
	@echo ""
	@echo "Development:"
	@echo "  make fmt        - format all Gleam packages"
	@echo "  make fmt-check  - verify formatting"
	@echo "  make check      - typecheck all packages"
	@echo "  make test       - run tests for all packages"
	@echo "  make build      - build all packages"
	@echo "  make docs       - generate documentation"
	@echo "  make bench      - run benchmarks"
	@echo "  make clean      - remove build artifacts"
	@echo ""
	@echo "CI/CD:"
	@echo "  make ci         - run full CI pipeline (fmt-check + check + test)"
	@echo "  make ci-quick   - quick CI check (fmt-check + check)"
	@echo ""
	@echo "Info:"
	@echo "  make version    - show version info"
	@echo "  make info       - show project info"

# Format all packages
fmt:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> formatting $$p"; \
	  (cd packages/$$p && gleam format); \
	done

# Check formatting without modifying files
fmt-check:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> fmt-check $$p"; \
	  (cd packages/$$p && gleam format --check); \
	done

# Type check all packages
check:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> check $$p"; \
	  (cd packages/$$p && gleam check); \
	done

# Run all tests
test:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> test $$p"; \
	  (cd packages/$$p && gleam test); \
	done

# Build all packages
build:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> build $$p"; \
	  (cd packages/$$p && gleam build); \
	done

# Generate documentation
docs:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> docs $$p"; \
	  (cd packages/$$p && gleam docs build) || true; \
	done
	@echo ""
	@echo "Documentation generated in packages/*/build/docs/"

# Run benchmarks
bench:
	@if [ -f scripts/bench.sh ]; then \
	  chmod +x scripts/bench.sh && ./scripts/bench.sh; \
	else \
	  echo "No benchmark script found. Create scripts/bench.sh"; \
	fi

# Full CI pipeline
ci: fmt-check check test
	@echo ""
	@echo "✅ CI pipeline passed!"

# Quick CI check (no tests)
ci-quick: fmt-check check
	@echo ""
	@echo "✅ Quick CI check passed!"

# Clean build artifacts
clean:
	@set -e; \
	for p in $(PACKAGES); do \
	  echo "==> clean $$p"; \
	  (cd packages/$$p && gleam clean); \
	done

# Show version info
version:
	@echo "oni version: $(VERSION)"
	@echo "gleam: $$(gleam --version 2>/dev/null || echo 'not found')"
	@echo "erlang: $$(erl -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo 'not found')"

# Show project info
info:
	@echo "oni - Bitcoin full node implementation in Gleam"
	@echo ""
	@echo "Version: $(VERSION)"
	@echo "Packages: $(PACKAGES)"
	@echo ""
	@echo "Package status:"
	@for p in $(PACKAGES); do \
	  lines=$$(find packages/$$p/src -name "*.gleam" -exec cat {} \; 2>/dev/null | wc -l); \
	  tests=$$(find packages/$$p/test -name "*.gleam" -exec cat {} \; 2>/dev/null | wc -l); \
	  echo "  $$p: $$lines source lines, $$tests test lines"; \
	done
