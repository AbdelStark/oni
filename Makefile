PACKAGES := $(shell ls -1 packages)
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

.PHONY: help fmt fmt-check check test ci clean build docs bench version info nif run run-testnet run-testnet4 run-regtest test-vectors test-differential test-all

help:
	@echo "oni development commands"
	@echo ""
	@echo "Development:"
	@echo "  make fmt        - format all Gleam packages"
	@echo "  make fmt-check  - verify formatting"
	@echo "  make check      - typecheck all packages"
	@echo "  make test       - run tests for all packages"
	@echo "  make build      - build all packages"
	@echo "  make nif        - build secp256k1 NIF (requires libsecp256k1)"
	@echo "  make docs       - generate documentation"
	@echo "  make bench      - run benchmarks"
	@echo "  make clean      - remove build artifacts"
	@echo ""
	@echo "Running:"
	@echo "  make run          - run node in mainnet mode (port 8333/8332)"
	@echo "  make run-testnet  - run node in testnet3 mode (port 18333/18332)"
	@echo "  make run-testnet4 - run node in testnet4 mode (port 48333/48332)"
	@echo "  make run-regtest  - run node in regtest mode (port 18444/18443)"
	@echo ""
	@echo "Testing:"
	@echo "  make test-vectors     - run test vector suite"
	@echo "  make test-differential - run differential tests vs bitcoind"
	@echo "  make test-e2e         - run E2E tests (node must be running)"
	@echo "  make test-e2e-full    - run E2E tests (starts node automatically)"
	@echo "  make test-all         - run all test suites"
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

# Build secp256k1 NIF
nif:
	@echo "==> Building secp256k1 NIF..."
	@if [ -f packages/oni_bitcoin/c_src/Makefile ]; then \
	  (cd packages/oni_bitcoin/c_src && make); \
	else \
	  echo "NIF Makefile not found. Skipping NIF build."; \
	fi

# Run node in mainnet mode
run: build
	@echo "==> Starting oni node (mainnet)..."
	@cd packages/oni_node && gleam run

# Run node in testnet mode
run-testnet: build
	@echo "==> Starting oni node (testnet3)..."
	@cd packages/oni_node && erl \
	  -noshell \
	  -pa build/dev/erlang/*/ebin \
	  -pa ../oni_bitcoin/build/dev/erlang/*/ebin \
	  -pa ../oni_consensus/build/dev/erlang/*/ebin \
	  -pa ../oni_storage/build/dev/erlang/*/ebin \
	  -pa ../oni_p2p/build/dev/erlang/*/ebin \
	  -pa ../oni_rpc/build/dev/erlang/*/ebin \
	  -eval 'cli:run([<<"--testnet">>])'

# Run node in testnet4 mode (BIP-94)
run-testnet4: build
	@echo "==> Starting oni node (testnet4)..."
	@cd packages/oni_node && erl \
	  -noshell \
	  -pa build/dev/erlang/*/ebin \
	  -pa ../oni_bitcoin/build/dev/erlang/*/ebin \
	  -pa ../oni_consensus/build/dev/erlang/*/ebin \
	  -pa ../oni_storage/build/dev/erlang/*/ebin \
	  -pa ../oni_p2p/build/dev/erlang/*/ebin \
	  -pa ../oni_rpc/build/dev/erlang/*/ebin \
	  -eval 'cli:run([<<"--testnet4">>])'

# Run node in regtest mode
run-regtest: build
	@echo "==> Starting oni node (regtest)..."
	@cd packages/oni_node && erl \
	  -noshell \
	  -pa build/dev/erlang/*/ebin \
	  -pa ../oni_bitcoin/build/dev/erlang/*/ebin \
	  -pa ../oni_consensus/build/dev/erlang/*/ebin \
	  -pa ../oni_storage/build/dev/erlang/*/ebin \
	  -pa ../oni_p2p/build/dev/erlang/*/ebin \
	  -pa ../oni_rpc/build/dev/erlang/*/ebin \
	  -eval 'cli:run([<<"--regtest">>])'

# Run test vectors
test-vectors:
	@echo "==> Running test vectors..."
	@chmod +x scripts/run_regtest_harness.sh
	@./scripts/run_regtest_harness.sh vectors

# Run differential tests against bitcoind
test-differential:
	@echo "==> Running differential tests..."
	@chmod +x scripts/run_regtest_harness.sh
	@./scripts/run_regtest_harness.sh differential

# Run E2E regtest tests (requires running node or will start one)
test-e2e:
	@echo "==> Running E2E regtest tests..."
	@chmod +x scripts/regtest_e2e_tests.sh
	@./scripts/regtest_e2e_tests.sh --skip-start

# Run E2E tests with node startup
test-e2e-full:
	@echo "==> Running full E2E regtest tests (starting node)..."
	@chmod +x scripts/regtest_e2e_tests.sh
	@./scripts/regtest_e2e_tests.sh

# Run all test suites
test-all: test test-vectors
	@echo "==> All test suites passed!"
