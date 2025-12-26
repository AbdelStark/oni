# References

This project intentionally relies on canonical sources.

## Gleam / BEAM / OTP

- Gleam documentation: https://gleam.run/documentation/
- gleam.toml reference: https://gleam.run/writing-gleam/gleam-toml/
- Gleam command line reference: https://gleam.run/command-line-reference/
- Gleam OTP docs: https://hexdocs.pm/gleam_otp/
- Gleam stdlib docs (bit arrays, etc): https://hexdocs.pm/gleam_stdlib/
- Gleam deployment (Linux server / erlang-shipment): https://gleam.run/deployment/linux-server/
- Gleam SBOM guide (ORT): https://gleam.run/documentation/source-bill-of-materials
- Externals / FFI:
  - Gleam externals guide: https://gleam.run/documentation/externals/  (or latest official link)
  - “Exploring the Gleam FFI” (community): https://www.jonashietala.se/blog/2024/01/11/exploring_the_gleam_ffi

## Bitcoin

- Bitcoin Core repository: https://github.com/bitcoin/bitcoin
- BIPs repository: https://github.com/bitcoin/bips
- Key BIPs to implement (non-exhaustive):
  - BIP32 (HD wallets), BIP39 (mnemonic), BIP44 (derivation paths)
  - BIP141/143/144 (SegWit)
  - BIP173 (Bech32), BIP350 (Bech32m)
  - BIP174 (PSBT)
  - BIP340/341/342 (Taproot)
  - BIP152 (Compact blocks)

## Inspiration

- rust-bitcoin org: https://github.com/rust-bitcoin
