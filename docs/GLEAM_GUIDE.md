# Gleam guide for oni

This document captures Gleam-specific implementation guidance for a Bitcoin node.

## 1. Why Gleam/OTP fits this project

- OTP supervision gives fault tolerance for long-running networked systems.
- BEAM concurrency is well-suited for managing thousands of peer connections.
- Gleam’s static typing helps keep consensus logic precise and auditable.

## 2. Key Gleam features we will lean on

### 2.1 Bit arrays / binaries
Bitcoin is a binary protocol. oni should:
- parse network messages and consensus structures using BitArray/binary operations,
- avoid copying large payloads,
- validate length prefixes before slicing.

### 2.2 Externals (FFI)
oni will likely rely on existing Erlang libraries for:
- networking and HTTP servers,
- telemetry and tracing exporters,
- possibly storage engines and/or crypto backends.

Guidelines:
- keep externals small and typed
- isolate externals behind module boundaries (`oni_* / internal/ffi/*`)
- add property tests for FFI boundaries

### 2.3 Including Erlang sources
Gleam projects can include `.erl` files in `src/` for small glue layers:
- application start modules
- NIF loading stubs
- thin wrappers around Erlang libraries

Keep such files minimal and well-documented.

### 2.4 OTP actors and supervisors
Use OTP patterns for:
- per-peer connection processes
- validation worker pools
- chainstate authority process

Design guidelines:
- avoid “god processes”
- define message types explicitly
- keep state transitions total and testable

## 3. Project structure conventions

- Public API in `src/<pkg>.gleam`
- Internal modules in `src/<pkg>/internal/*`
- Explicitly document which modules are stable vs internal.

## 4. Build and deployment

- Use `gleam export erlang-shipment` as the first deployment target.
- Containerize with multi-stage builds.
- Keep runtime image small; ship only the built artifact + runtime deps.

## 5. Testing in Gleam

- Use gleeunit for unit tests.
- For property tests/fuzzing:
  - prefer a dedicated harness that calls pure decode/verify functions
  - consider interfacing with BEAM property testing libraries if needed (via externals)

## 6. Performance notes

- Avoid repeatedly concatenating binaries; prefer iolists or pre-sized buffers when possible.
- Treat crypto as a hot path; ensure it does not block schedulers.
- Use ETS for bounded caches with clear eviction and observability.
