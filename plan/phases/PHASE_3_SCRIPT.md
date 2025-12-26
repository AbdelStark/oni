# Phase 3: Script engine (oni_consensus)

## Goal
Implement Bitcoin Script evaluation for legacy, SegWit v0, and Taproot.

## Deliverables
- Script parser and opcode tables
- Interpreter core with strict bounds
- Signature checking integration via crypto interface
- SegWit v0 witness program validation
- Taproot key path and tapscript validation

## Work packages (incremental)

### 3.1 Script parsing
- Parse raw script into opcodes/pushdata
- Enforce pushdata bounds
- Implement opcode metadata table (name, category, cost)

### 3.2 Interpreter core
- Stack + altstack
- Flow control (IF/ELSE/ENDIF)
- Script execution limits:
  - opcount
  - stack size
  - element size

### 3.3 Opcode groups
Implement and test groups in order:
1. push/constant
2. stack manipulation
3. arithmetic/logic
4. hashing ops
5. signature ops:
   - checksig
   - checkmultisig

### 3.4 SegWit v0
- witness stack parsing and rules
- BIP143 sighash integration
- scriptCode rules and flags

### 3.5 Taproot
- tagged hash helpers
- schnorr checks
- tapscript validation rules
- script path: control block + merkle path verification

### 3.6 Tests
- opcode group unit tests
- script vectors (valid/invalid)
- fuzz target for interpreter

## Acceptance criteria
- Interpreter matches vectors.
- Malformed scripts never crash.
- Bounds enforced and tested.
