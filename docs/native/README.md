# Native code (NIFs) and cryptography

oni may use native code (Rust/C) for performance-critical cryptography and/or storage.

## Principles

- Keep native surface minimal.
- Prefer audited libraries (libsecp256k1).
- Treat native code as unsafe:
  - fuzz boundaries
  - isolate failures
  - document build steps
- Ensure native work does not block BEAM schedulers (dirty NIF or external process).

## Layout (planned)

- `native/secp256k1_nif/` — signature verification and pubkey parsing
- `native/hash_nif/` — optional accelerated hashing (if needed)

Each native component must include:
- reproducible build steps
- CI integration
- version pinning of upstream libraries
