# Glossary

- **BEAM**: Erlang VM runtime used by Erlang/Elixir/Gleam.
- **BIP**: Bitcoin Improvement Proposal.
- **Chainstate**: Active chain + UTXO set state machine.
- **Consensus**: Validation rules that define Bitcoin correctness.
- **Policy**: Local node rules (mempool acceptance/relay), not consensus.
- **IBD**: Initial Block Download.
- **UTXO**: Unspent Transaction Output.
- **Outpoint**: (txid, vout) pointer to a UTXO.
- **Mempool**: Set of unconfirmed transactions accepted by node policy.
- **Reorg**: Chain reorganization when a better chain is found.
- **Witness**: SegWit data separate from tx serialization for txid.
- **Txid / Wtxid**: Transaction identifiers (with/without witness).
- **Taproot/Tapscript**: SegWit v1 functionality enabling schnorr and new script version.
- **OTP**: Open Telecom Platform; Erlang’s design principles and libraries for fault tolerance.
