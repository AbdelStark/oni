# Script Engine Patterns

Bitcoin Script evaluation and validation.

## Location

- Package: `packages/oni_consensus`
- Key files: `script.gleam`, `opcodes.gleam`, `validation.gleam`

## Architecture

### Stack Machine
- Main stack + alt stack
- Opcode dispatch loop
- Error taxonomy with specific failure types

### Opcode Groups
- **Push**: OP_0 through OP_16, OP_PUSHDATA
- **Flow control**: IF/ELSE/ENDIF/NOTIF
- **Stack ops**: DUP, DROP, SWAP, ROT, etc.
- **Arithmetic**: ADD, SUB, MUL (disabled), etc.
- **Crypto**: HASH160, SHA256, CHECKSIG, CHECKMULTISIG
- **Locktime**: CHECKLOCKTIMEVERIFY (BIP65), CHECKSEQUENCEVERIFY (BIP112)

## Sighash Types

| Type | Value | Behavior |
|------|-------|----------|
| ALL | 0x01 | Sign all inputs and outputs |
| NONE | 0x02 | Sign inputs only |
| SINGLE | 0x03 | Sign corresponding output |
| ANYONECANPAY | 0x80 | Modifier: sign only this input |

## Pitfalls

| Issue | Detail |
|-------|--------|
| Disabled opcodes | OP_MUL, OP_DIV, etc. fail immediately |
| NULLDUMMY | Extra stack item in CHECKMULTISIG must be empty |
| Minimal encoding | Script numbers must be minimally encoded |
| Stack limits | Max 1000 elements, 520 bytes per element |
| Op count | Max 201 non-push operations |

## Code References

- Opcodes: `packages/oni_consensus/src/opcodes.gleam`
- Interpreter: `packages/oni_consensus/src/script.gleam`
- Sighash: `packages/oni_consensus/src/validation.gleam`
- Test vectors: `test_vectors/script_tests.json`
