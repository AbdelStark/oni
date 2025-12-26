# Skill: Script interpreter implementation

## Goal
Implement Bitcoin Script evaluation with exact semantics and strict bounds.

## Where
- Package: `packages/oni_consensus`
- Modules (planned):
  - `oni_consensus/script/*`
  - `oni_consensus/sighash/*`

## Steps
1. Implement stack machine core
   - main stack + alt stack
   - opcode dispatch
   - error taxonomy
2. Implement numeric encoding rules
   - minimal encoding where required
   - integer range and overflow behavior
3. Implement opcode groups incrementally
   - pushes and flow control
   - stack manipulation
   - arithmetic/logic
   - crypto ops (hashes, checksig)
4. Integrate signature verification via crypto interface
   - never allow interpreter to call raw NIF directly
5. SegWit v0
   - witness stack rules
   - scriptCode semantics
6. Taproot
   - schnorr verification
   - tapscript versioning and rules

## Testing
- Use valid/invalid vectors per opcode group.
- Add fuzz target focused on interpreter input bytes + witness stack.
- Differential tests vs Bitcoin Core for selected cases.

## Gotchas
- Disabled opcodes and “softfork” behavior changes by activation.
- CHECKMULTISIG consumes an extra stack item (“NULLDUMMY” rules differ by flags).
- Signature encoding rules (DER) vs schnorr strictness.
- Max stack element size and op count limits.

## Acceptance checklist
- [ ] Vectors added for each opcode group
- [ ] Interpreter is total (never crashes)
- [ ] Bounds enforced (stack, element size, op count)
- [ ] Differential harness covers core cases
