# Consensus specification (target)

This document defines the **consensus scope** of oni. The intent is to mirror Bitcoin Core consensus semantics.

> This is not a replacement for Bitcoin Core or the BIPs.  
> It is a **checklist** of what oni must implement and how we will structure the implementation.

## 1. Definitions

- **Consensus**: rules that determine whether a block/transaction is valid and part of the canonical chain.
- **Policy**: local node rules about what to relay/mine/accept in mempool. Policy can differ between nodes.
- **Chainstate**: active chain + UTXO set.

oni must keep these concerns separate in code.

## 2. Consensus-critical modules

The consensus engine should be split into these conceptual modules:

1. **Consensus serialization**
   - Exactly match Bitcoin’s canonical encoding for blocks and transactions.
   - Implement CompactSize/varint, varstr, etc.

2. **Hashing**
   - sha256d for PoW and TXIDs
   - wtxid, witness commitment computation
   - merkle root and witness merkle root

3. **Sighash**
   - Legacy (pre-segwit) scriptCode behavior
   - BIP143 (SegWit v0) digest
   - Taproot (BIP341) digest (key path and script path)

4. **Script**
   - Script parsing and evaluation engine
   - Exact stack / altstack semantics
   - Disabled opcodes and minimal push rules as required by consensus
   - Signature op counting and limits
   - SegWit script evaluation and witness stack validation
   - Taproot script evaluation (Tapscript)

5. **Transaction checks**
   - Context-free checks: sizes, counts, numeric bounds
   - Coinbases, null prevouts, scriptsig size bounds, etc.
   - Locktime and sequence rules (BIP68/112/113 family)
   - Amount ranges and sum overflow prevention

6. **Block header checks**
   - Version bits / softfork activation rules (BIP9 style)
   - Difficulty adjustment rules (retarget, testnet special rules)
   - Median time past checks
   - Proof-of-work checks (target encoding, sha256d(header) <= target)

7. **Block body checks**
   - Merkle root matches
   - Witness commitment rules (segwit)
   - Weight limits
   - Signature operation limits (legacy + witness)
   - Coinbase maturity enforcement (via UTXO rules, not block checks)

8. **UTXO transition**
   - ConnectBlock: spend inputs, create outputs, update coinbase, update undo data
   - DisconnectBlock: apply undo data and restore UTXO set
   - Deterministic DB commit semantics

## 3. Required feature set (mainnet ruleset)

oni must implement the modern Bitcoin ruleset, including at minimum:

- P2PKH/P2SH legacy validation
- SegWit v0 (P2WPKH / P2WSH, witness program rules)
- Taproot v1 (P2TR, schnorr signatures, tapscript)

Additionally, the historical softforks that affect validation (e.g. strict DER, CLTV, CSV) must be respected based on the chain height/time they activated.

## 4. Validation layering

oni will implement validation as layered stages:

### 4.1 Stateless / context-free
- Structure validation: tx format, scripts length bounds, no negative outputs, etc.
- Basic script parse checks (without UTXO context).

### 4.2 Contextual
- UTXO lookups for inputs
- Script evaluation with correct flags at that height
- Locktime/sequence checks using block height/time context

### 4.3 Chain-level
- Difficulty / PoW checks using previous blocks
- Versionbits activation state
- Reorg and chainwork selection rules

## 5. Script engine design requirements

- The script interpreter must be:
  - **Deterministic**
  - **Total** over inputs (always returns Ok/Err; no crashes from malformed scripts)
  - **Memory safe** and bounded
- Every opcode is unit-tested with:
  - Known-good vectors
  - Edge cases
  - Randomized tests where applicable
- Signature verification must be separated as an interface so it can be swapped between:
  - pure/reference implementation (for differential testing)
  - accelerated implementation (native/NIF)

## 6. Consensus vs policy flags

We model script verification flags as:
- consensus-required flags (must match Bitcoin Core’s for that height)
- policy flags (e.g. standardness rules)

Policy flags live outside `oni_consensus` and must not affect block validation.

## 7. Differential testing strategy

oni’s consensus engine must be continuously validated against Bitcoin Core by:
- test vectors (script_tests, tx_valid, tx_invalid)
- property tests where we can generate txs/blocks
- “differential harness” that asks Bitcoin Core to validate artifacts and compares results

## 8. Guardrails

- No “fast path” in consensus without:
  - a correctness proof in the form of tests and/or a reference cross-check
  - fuzz coverage
  - explicit review by a “consensus owner” (human or designated code owner)
