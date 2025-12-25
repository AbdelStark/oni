# Work Breakdown Structure (WBS)

This WBS decomposes oni into epics and work packages.

> Use this alongside `ai/backlog/backlog.yml`.

## EPIC A — Foundations
A1. Repo scaffolding and tooling  
A2. CI/CD pipeline  
A3. AI agent docs and tasking system  
A4. Supply chain controls (SBOM, dependency policy)  

## EPIC B — Bitcoin primitives (oni_bitcoin)
B1. Core types (hashes, amounts, scripts, outpoints)  
B2. Consensus serialization (tx, block, headers)  
B3. Varint/CompactSize and varstr  
B4. Encoding: base16/hex, base58check  
B5. Encoding: bech32/bech32m  
B6. Merkle tree utilities  

## EPIC C — Crypto layer
C1. SHA256/sha256d/tagged hashes  
C2. RIPEMD160 + HASH160  
C3. secp256k1 interface and verification  
C4. Reference + accelerated modes  
C5. Crypto benchmarks  

## EPIC D — Script engine (oni_consensus)
D1. Script parsing and opcode table  
D2. Legacy script evaluation  
D3. SegWit v0 evaluation  
D4. Taproot/tapscript evaluation  
D5. Script tests + fuzzing  

## EPIC E — Validation
E1. Transaction validation (stateless/contextual)  
E2. Block header validation (PoW/difficulty/time)  
E3. Block body validation (merkle/witness/weight)  
E4. Connect/disconnect logic with UTXO view  
E5. Differential harness vs Bitcoin Core  

## EPIC F — Storage (oni_storage)
F1. DB engine selection and abstraction  
F2. Block store and index  
F3. UTXO DB + caches  
F4. Undo data and reorg support  
F5. Migrations and schema versioning  
F6. Crash recovery tests  

## EPIC G — P2P (oni_p2p)
G1. Message envelope codec and framing  
G2. Handshake + feature negotiation  
G3. Peer manager + address manager  
G4. Inventory relay + request scheduling  
G5. DoS protection + per-peer limits  
G6. P2P fuzzing harness  

## EPIC H — IBD & sync
H1. Headers-first sync  
H2. Block download pipeline  
H3. Validation integration and backpressure  
H4. Reorg handling during sync  

## EPIC I — Mempool & policy
I1. Policy checks and standardness  
I2. Fee/rate logic, eviction  
I3. RBF/orphan handling  
I4. Tx relay integration  

## EPIC J — RPC & CLI
J1. JSON-RPC server + auth  
J2. RPC method implementations  
J3. CLI tooling  
J4. Admin endpoints and diagnostics  

## EPIC K — Ops readiness
K1. Logging, metrics, tracing  
K2. Health/readiness endpoints  
K3. Dashboards and alert rules  
K4. Release pipeline and containers
