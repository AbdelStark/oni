PACKAGES := $(shell ls -1 packages)
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

.PHONY: help fmt fmt-check check test ci clean build docs bench version info nif run run-testnet run-testnet4 run-regtest test-vectors test-differential test-all
.PHONY: watch-ibd watch-sync node-status node-stop node-logs clear-testnet4 clear-testnet clear-mainnet compare-testnet4 compare-testnet

# Log file locations
TESTNET4_LOG := /tmp/oni-testnet4.log
TESTNET_LOG := /tmp/oni-testnet.log
MAINNET_LOG := /tmp/oni-mainnet.log

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
	@echo "Monitoring:"
	@echo "  make watch-ibd         - watch IBD block progress (live)"
	@echo "  make watch-sync        - watch sync progress every 5s"
	@echo "  make node-status       - show current node status via RPC"
	@echo "  make node-logs         - show recent node logs"
	@echo "  make compare-testnet4  - compare local vs public testnet4 chain"
	@echo "  make compare-testnet   - compare local vs public testnet3 chain"
	@echo ""
	@echo "Management:"
	@echo "  make node-stop         - stop running oni node"
	@echo "  make clear-testnet4    - clear testnet4 data and restart"
	@echo "  make clear-testnet     - clear testnet3 data"
	@echo "  make clear-mainnet     - clear mainnet data"
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

# ============================================================================
# Monitoring Commands
# ============================================================================

# Watch IBD block progress (live streaming)
watch-ibd:
	@echo "==> Watching IBD progress (Ctrl+C to stop)..."
	@if [ -f $(TESTNET4_LOG) ]; then \
		tail -f $(TESTNET4_LOG) | grep --line-buffered '\[IBD\] Block'; \
	elif [ -f $(TESTNET_LOG) ]; then \
		tail -f $(TESTNET_LOG) | grep --line-buffered '\[IBD\] Block'; \
	elif [ -f $(MAINNET_LOG) ]; then \
		tail -f $(MAINNET_LOG) | grep --line-buffered '\[IBD\] Block'; \
	else \
		echo "No log file found. Start a node first with make run-testnet4"; \
	fi

# Watch sync progress every 5 seconds
watch-sync:
	@echo "==> Watching sync progress every 5s (Ctrl+C to stop)..."
	@watch -n 5 'grep "\[IBD\] Block" /tmp/oni-testnet4.log 2>/dev/null | tail -1 || echo "No IBD progress yet"'

# Show current node status via RPC
node-status:
	@echo "==> Checking node status..."
	@echo ""
	@echo "--- Testnet4 (port 48332) ---"
	@curl -s --max-time 5 http://127.0.0.1:48332 -X POST \
		-H "Content-Type: application/json" \
		-d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' 2>/dev/null | \
		jq '.result | {chain, blocks, headers, verificationprogress, initialblockdownload}' 2>/dev/null || \
		echo "Not running or not responding"
	@echo ""
	@echo "--- Testnet3 (port 18332) ---"
	@curl -s --max-time 5 http://127.0.0.1:18332 -X POST \
		-H "Content-Type: application/json" \
		-d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' 2>/dev/null | \
		jq '.result | {chain, blocks, headers, verificationprogress, initialblockdownload}' 2>/dev/null || \
		echo "Not running or not responding"
	@echo ""
	@echo "--- Mainnet (port 8332) ---"
	@curl -s --max-time 5 http://127.0.0.1:8332 -X POST \
		-H "Content-Type: application/json" \
		-d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' 2>/dev/null | \
		jq '.result | {chain, blocks, headers, verificationprogress, initialblockdownload}' 2>/dev/null || \
		echo "Not running or not responding"

# Show recent node logs
node-logs:
	@echo "==> Recent node logs..."
	@if [ -f $(TESTNET4_LOG) ]; then \
		echo "--- Testnet4 logs (last 30 lines) ---"; \
		tail -30 $(TESTNET4_LOG) | grep -v 'Sending to peer'; \
	elif [ -f $(TESTNET_LOG) ]; then \
		echo "--- Testnet3 logs (last 30 lines) ---"; \
		tail -30 $(TESTNET_LOG) | grep -v 'Sending to peer'; \
	elif [ -f $(MAINNET_LOG) ]; then \
		echo "--- Mainnet logs (last 30 lines) ---"; \
		tail -30 $(MAINNET_LOG) | grep -v 'Sending to peer'; \
	else \
		echo "No log file found. Start a node first."; \
	fi

# Compare local vs public testnet4 chain
compare-testnet4:
	@echo "==> Comparing local testnet4 with public chain..."
	@uv run scripts/btc_rpc.py compare --network testnet4

# Compare local vs public testnet3 chain
compare-testnet:
	@echo "==> Comparing local testnet3 with public chain..."
	@uv run scripts/btc_rpc.py compare --network testnet3

# ============================================================================
# Management Commands
# ============================================================================

# Stop running oni node
node-stop:
	@echo "==> Stopping oni node..."
	@pkill -f 'beam.*oni' 2>/dev/null && echo "Node stopped" || echo "No node running"

# Clear testnet4 data and optionally restart
clear-testnet4:
	@echo "==> Clearing testnet4 data..."
	@rm -rf ~/.oni/testnet4
	@echo "Testnet4 data cleared from ~/.oni/testnet4"

# Clear testnet3 data
clear-testnet:
	@echo "==> Clearing testnet3 data..."
	@rm -rf ~/.oni/testnet3
	@echo "Testnet3 data cleared from ~/.oni/testnet3"

# Clear mainnet data
clear-mainnet:
	@echo "==> Clearing mainnet data..."
	@rm -rf ~/.oni/mainnet
	@echo "Mainnet data cleared from ~/.oni/mainnet"

# Fresh testnet4 start (clear + run)
fresh-testnet4: node-stop clear-testnet4
	@echo "==> Starting fresh testnet4 sync..."
	@$(MAKE) run-testnet4
