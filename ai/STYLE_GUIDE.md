# Gleam style guide (oni)

## General
- Use `gleam format` and don’t hand-format.
- Prefer small modules with single responsibility.
- Keep public API minimal; hide internals in `internal/` modules.

## Types
- Use opaque types for consensus hashes and key material to prevent misuse.
- Avoid `Int` for fixed-width protocol integers at boundaries; provide codec helpers that enforce ranges.

## Errors
- Use explicit error types, not strings.
- Prefer `Result(value, ErrorType)` for fallible operations.
- Never crash on malformed external input.

## Binaries / BitArray
- Prefer parsing via bit arrays/binaries without copying.
- Validate length prefixes before slicing/allocating.
- Keep endian conversions explicit and tested.

## Naming
- `snake_case` functions
- `PascalCase` types and constructors
- Use `*_bytes`, `*_hex`, `*_hash` suffixes for clarity

## Testing
- Each module should have:
  - unit tests for normal cases
  - unit tests for edge cases
  - unit tests for invalid inputs
- Consensus code must include vectors and differential checks.
