# oni Bitcoin Node - Multi-stage Dockerfile
#
# Build: docker build -t oni .
# Run:   docker run -d -p 8333:8333 -p 8332:8332 -v oni-data:/data oni
#
# Environment variables:
#   ONI_NETWORK      - bitcoin network (mainnet, testnet, signet, regtest)
#   ONI_DATA_DIR     - data directory path (default: /data)
#   ONI_RPC_USER     - RPC username (required in production)
#   ONI_RPC_PASSWORD - RPC password (required in production)
#   ONI_LOG_LEVEL    - log level (trace, debug, info, warn, error)

# =============================================================================
# Stage 1: Build environment
# =============================================================================
FROM erlang:26-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    git \
    curl \
    build-base \
    openssl-dev

# Install Gleam
ARG GLEAM_VERSION=1.4.1
RUN curl -L https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-x86_64-unknown-linux-musl.tar.gz \
    | tar xzf - -C /usr/local/bin

# Set working directory
WORKDIR /build

# Copy dependency files first for better caching
COPY gleam.toml ./
COPY packages/oni_bitcoin/gleam.toml packages/oni_bitcoin/
COPY packages/oni_consensus/gleam.toml packages/oni_consensus/
COPY packages/oni_storage/gleam.toml packages/oni_storage/
COPY packages/oni_p2p/gleam.toml packages/oni_p2p/
COPY packages/oni_rpc/gleam.toml packages/oni_rpc/
COPY packages/oni_node/gleam.toml packages/oni_node/

# Download dependencies
RUN gleam deps download

# Copy source code
COPY . .

# Build release
RUN gleam build --target erlang
RUN gleam export erlang-shipment

# =============================================================================
# Stage 2: Runtime environment
# =============================================================================
FROM erlang:26-alpine AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    openssl \
    ca-certificates \
    tini

# Create non-root user for security
RUN addgroup -g 1000 oni && \
    adduser -D -u 1000 -G oni oni

# Create data directory
RUN mkdir -p /data && chown oni:oni /data

# Copy built application
COPY --from=builder /build/build/erlang-shipment /app
COPY --from=builder /build/build/erlang-shipment/entrypoint.sh /app/

# Set ownership
RUN chown -R oni:oni /app

# Switch to non-root user
USER oni

# Set working directory
WORKDIR /app

# Environment defaults
ENV ONI_NETWORK=mainnet \
    ONI_DATA_DIR=/data \
    ONI_LOG_LEVEL=info \
    ONI_RPC_PORT=8332 \
    ONI_P2P_PORT=8333

# Expose ports
# P2P network port
EXPOSE 8333
# RPC port
EXPOSE 8332
# Metrics/health port
EXPOSE 9100

# Data volume
VOLUME ["/data"]

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget -q --spider http://localhost:9100/health || exit 1

# Use tini as init system
ENTRYPOINT ["/sbin/tini", "--"]

# Start the node
CMD ["./entrypoint.sh", "run"]
