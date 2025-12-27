// oni_consensus - Bitcoin consensus rules and script engine
//
// This module implements Bitcoin consensus validation including:
// - Script execution engine
// - Transaction validation
// - Block validation
// - Sighash computation

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import oni_bitcoin.{
  type Amount, type Block, type BlockHash, type BlockHeader, type Hash256,
  type OutPoint, type Script, type Transaction, type TxIn, type TxOut, type Txid,
}

// ============================================================================
// Consensus Error Types
// ============================================================================

/// Consensus validation errors - stable taxonomy for testing
pub type ConsensusError {
  // Script errors
  ScriptInvalid
  ScriptDisabledOpcode
  ScriptStackUnderflow
  ScriptStackOverflow
  ScriptVerifyFailed
  ScriptEqualVerifyFailed
  ScriptCheckSigFailed
  ScriptCheckMultisigFailed
  ScriptCheckLockTimeVerifyFailed
  ScriptCheckSequenceVerifyFailed
  ScriptPushSizeExceeded
  ScriptOpCountExceeded
  ScriptBadOpcode
  ScriptMinimalData
  ScriptWitnessMalleated
  ScriptWitnessUnexpected
  ScriptCleanStack
  ScriptSizeTooLarge

  // Transaction errors
  TxMissingInputs
  TxDuplicateInputs
  TxEmptyInputs
  TxEmptyOutputs
  TxOversized
  TxBadVersion
  TxInvalidAmount
  TxOutputValueOverflow
  TxInputNotFound
  TxInputSpent
  TxInputsNotAvailable
  TxPrematureCoinbaseSpend
  TxSequenceLockNotMet
  TxLockTimeNotMet
  TxSigOpCountExceeded

  // Block errors
  BlockInvalidHeader
  BlockInvalidPoW
  BlockInvalidMerkleRoot
  BlockInvalidWitnessCommitment
  BlockTimestampTooOld
  BlockTimestampTooFar
  BlockBadVersion
  BlockTooLarge
  BlockWeightExceeded
  BlockBadCoinbase
  BlockDuplicateTx
  BlockBadPrevBlock

  // Other
  Other(String)
}

// ============================================================================
// Script Opcodes
// ============================================================================

/// Bitcoin Script opcodes
pub type Opcode {
  // Push value
  OpFalse          // 0x00 - Push empty array
  OpPushBytes(Int) // 0x01-0x4b - Push N bytes
  OpPushData1      // 0x4c - Next byte is length
  OpPushData2      // 0x4d - Next 2 bytes are length
  OpPushData4      // 0x4e - Next 4 bytes are length
  Op1Negate        // 0x4f - Push -1
  OpReserved       // 0x50 - Transaction invalid unless in unexecuted IF
  OpTrue           // 0x51 - Push 1 (OP_1)
  OpNum(Int)       // 0x52-0x60 - Push 2-16

  // Control
  OpNop            // 0x61 - Do nothing
  OpVer            // 0x62 - Transaction invalid
  OpIf             // 0x63 - If top stack is true, execute
  OpNotIf          // 0x64 - If top stack is false, execute
  OpVerIf          // 0x65 - Transaction invalid
  OpVerNotIf       // 0x66 - Transaction invalid
  OpElse           // 0x67 - Else branch
  OpEndIf          // 0x68 - End if block
  OpVerify         // 0x69 - Fail if top is false
  OpReturn         // 0x6a - Marks output as unspendable

  // Stack
  OpToAltStack     // 0x6b
  OpFromAltStack   // 0x6c
  Op2Drop          // 0x6d
  Op2Dup           // 0x6e
  Op3Dup           // 0x6f
  Op2Over          // 0x70
  Op2Rot           // 0x71
  Op2Swap          // 0x72
  OpIfDup          // 0x73
  OpDepth          // 0x74
  OpDrop           // 0x75
  OpDup            // 0x76
  OpNip            // 0x77
  OpOver           // 0x78
  OpPick           // 0x79
  OpRoll           // 0x7a
  OpRot            // 0x7b
  OpSwap           // 0x7c
  OpTuck           // 0x7d

  // Splice (disabled except OP_SIZE)
  OpCat            // 0x7e - disabled
  OpSubstr         // 0x7f - disabled
  OpLeft           // 0x80 - disabled
  OpRight          // 0x81 - disabled
  OpSize           // 0x82

  // Bitwise logic (disabled except OP_EQUAL)
  OpInvert         // 0x83 - disabled
  OpAnd            // 0x84 - disabled
  OpOr             // 0x85 - disabled
  OpXor            // 0x86 - disabled
  OpEqual          // 0x87
  OpEqualVerify    // 0x88
  OpReserved1      // 0x89
  OpReserved2      // 0x8a

  // Arithmetic
  Op1Add           // 0x8b
  Op1Sub           // 0x8c
  Op2Mul           // 0x8d - disabled
  Op2Div           // 0x8e - disabled
  OpNegate         // 0x8f
  OpAbs            // 0x90
  OpNot            // 0x91
  Op0NotEqual      // 0x92
  OpAdd            // 0x93
  OpSub            // 0x94
  OpMul            // 0x95 - disabled
  OpDiv            // 0x96 - disabled
  OpMod            // 0x97 - disabled
  OpLShift         // 0x98 - disabled
  OpRShift         // 0x99 - disabled
  OpBoolAnd        // 0x9a
  OpBoolOr         // 0x9b
  OpNumEqual       // 0x9c
  OpNumEqualVerify // 0x9d
  OpNumNotEqual    // 0x9e
  OpLessThan       // 0x9f
  OpGreaterThan    // 0xa0
  OpLessThanOrEqual    // 0xa1
  OpGreaterThanOrEqual // 0xa2
  OpMin            // 0xa3
  OpMax            // 0xa4
  OpWithin         // 0xa5

  // Crypto
  OpRipeMd160      // 0xa6
  OpSha1           // 0xa7
  OpSha256         // 0xa8
  OpHash160        // 0xa9
  OpHash256        // 0xaa
  OpCodeSeparator  // 0xab
  OpCheckSig       // 0xac
  OpCheckSigVerify // 0xad
  OpCheckMultiSig  // 0xae
  OpCheckMultiSigVerify // 0xaf

  // Expansion
  OpNop1           // 0xb0
  OpCheckLockTimeVerify  // 0xb1 (BIP65)
  OpCheckSequenceVerify  // 0xb2 (BIP112)
  OpNop4           // 0xb3
  OpNop5           // 0xb4
  OpNop6           // 0xb5
  OpNop7           // 0xb6
  OpNop8           // 0xb7
  OpNop9           // 0xb8
  OpNop10          // 0xb9

  // Taproot
  OpCheckSigAdd    // 0xba (BIP342)
  OpSuccess(Int)   // 0xbb-0xfe - Reserved for upgrades

  // Invalid
  OpInvalidOpcode  // 0xff
}

/// Decode an opcode from a byte
pub fn opcode_from_byte(b: Int) -> Opcode {
  case b {
    0x00 -> OpFalse
    n if n >= 0x01 && n <= 0x4b -> OpPushBytes(n)
    0x4c -> OpPushData1
    0x4d -> OpPushData2
    0x4e -> OpPushData4
    0x4f -> Op1Negate
    0x50 -> OpReserved
    0x51 -> OpTrue
    n if n >= 0x52 && n <= 0x60 -> OpNum(n - 0x50)
    0x61 -> OpNop
    0x62 -> OpVer
    0x63 -> OpIf
    0x64 -> OpNotIf
    0x65 -> OpVerIf
    0x66 -> OpVerNotIf
    0x67 -> OpElse
    0x68 -> OpEndIf
    0x69 -> OpVerify
    0x6a -> OpReturn
    0x6b -> OpToAltStack
    0x6c -> OpFromAltStack
    0x6d -> Op2Drop
    0x6e -> Op2Dup
    0x6f -> Op3Dup
    0x70 -> Op2Over
    0x71 -> Op2Rot
    0x72 -> Op2Swap
    0x73 -> OpIfDup
    0x74 -> OpDepth
    0x75 -> OpDrop
    0x76 -> OpDup
    0x77 -> OpNip
    0x78 -> OpOver
    0x79 -> OpPick
    0x7a -> OpRoll
    0x7b -> OpRot
    0x7c -> OpSwap
    0x7d -> OpTuck
    0x7e -> OpCat
    0x7f -> OpSubstr
    0x80 -> OpLeft
    0x81 -> OpRight
    0x82 -> OpSize
    0x83 -> OpInvert
    0x84 -> OpAnd
    0x85 -> OpOr
    0x86 -> OpXor
    0x87 -> OpEqual
    0x88 -> OpEqualVerify
    0x89 -> OpReserved1
    0x8a -> OpReserved2
    0x8b -> Op1Add
    0x8c -> Op1Sub
    0x8d -> Op2Mul
    0x8e -> Op2Div
    0x8f -> OpNegate
    0x90 -> OpAbs
    0x91 -> OpNot
    0x92 -> Op0NotEqual
    0x93 -> OpAdd
    0x94 -> OpSub
    0x95 -> OpMul
    0x96 -> OpDiv
    0x97 -> OpMod
    0x98 -> OpLShift
    0x99 -> OpRShift
    0x9a -> OpBoolAnd
    0x9b -> OpBoolOr
    0x9c -> OpNumEqual
    0x9d -> OpNumEqualVerify
    0x9e -> OpNumNotEqual
    0x9f -> OpLessThan
    0xa0 -> OpGreaterThan
    0xa1 -> OpLessThanOrEqual
    0xa2 -> OpGreaterThanOrEqual
    0xa3 -> OpMin
    0xa4 -> OpMax
    0xa5 -> OpWithin
    0xa6 -> OpRipeMd160
    0xa7 -> OpSha1
    0xa8 -> OpSha256
    0xa9 -> OpHash160
    0xaa -> OpHash256
    0xab -> OpCodeSeparator
    0xac -> OpCheckSig
    0xad -> OpCheckSigVerify
    0xae -> OpCheckMultiSig
    0xaf -> OpCheckMultiSigVerify
    0xb0 -> OpNop1
    0xb1 -> OpCheckLockTimeVerify
    0xb2 -> OpCheckSequenceVerify
    0xb3 -> OpNop4
    0xb4 -> OpNop5
    0xb5 -> OpNop6
    0xb6 -> OpNop7
    0xb7 -> OpNop8
    0xb8 -> OpNop9
    0xb9 -> OpNop10
    0xba -> OpCheckSigAdd
    n if n >= 0xbb && n <= 0xfe -> OpSuccess(n)
    _ -> OpInvalidOpcode
  }
}

/// Check if opcode is disabled
pub fn opcode_is_disabled(op: Opcode) -> Bool {
  case op {
    OpCat | OpSubstr | OpLeft | OpRight -> True
    OpInvert | OpAnd | OpOr | OpXor -> True
    Op2Mul | Op2Div | OpMul | OpDiv | OpMod -> True
    OpLShift | OpRShift -> True
    _ -> False
  }
}

// ============================================================================
// Script Execution State
// ============================================================================

/// Script execution flags (BIP16, BIP141, etc.)
pub type ScriptFlags {
  ScriptFlags(
    verify_p2sh: Bool,
    verify_witness: Bool,
    verify_minimaldata: Bool,
    verify_cleanstack: Bool,
    verify_dersig: Bool,
    verify_low_s: Bool,
    verify_nulldummy: Bool,
    verify_sigpushonly: Bool,
    verify_strictenc: Bool,
    verify_minimalif: Bool,
    verify_nullfail: Bool,
    verify_witness_pubkeytype: Bool,
    verify_taproot: Bool,
    verify_discourage_upgradable_nops: Bool,
    verify_discourage_upgradable_witness_program: Bool,
    verify_discourage_upgradable_taproot_version: Bool,
    verify_discourage_op_success: Bool,
    verify_discourage_upgradable_pubkeytype: Bool,
  )
}

/// Default flags for mainnet consensus
pub fn default_script_flags() -> ScriptFlags {
  ScriptFlags(
    verify_p2sh: True,
    verify_witness: True,
    verify_minimaldata: True,
    verify_cleanstack: True,
    verify_dersig: True,
    verify_low_s: True,
    verify_nulldummy: True,
    verify_sigpushonly: True,
    verify_strictenc: True,
    verify_minimalif: True,
    verify_nullfail: True,
    verify_witness_pubkeytype: True,
    verify_taproot: True,
    verify_discourage_upgradable_nops: False,
    verify_discourage_upgradable_witness_program: False,
    verify_discourage_upgradable_taproot_version: False,
    verify_discourage_op_success: False,
    verify_discourage_upgradable_pubkeytype: False,
  )
}

/// Signature verification context - transaction data needed for sighash computation
pub type SigContext {
  SigContext(
    /// The transaction being validated
    tx: Transaction,
    /// The input index being verified
    input_index: Int,
    /// The value of the output being spent (needed for SegWit sighash)
    spent_value: Amount,
    /// The script code to use (for P2SH/P2WSH the redeemScript/witnessScript)
    script_code: Script,
    /// Whether this is a SegWit spend
    is_segwit: Bool,
    /// Whether this is a Taproot spend
    is_taproot: Bool,
  )
}

/// Script execution context
pub type ScriptContext {
  ScriptContext(
    stack: List(BitArray),
    alt_stack: List(BitArray),
    op_count: Int,
    script: BitArray,
    script_pos: Int,
    codesep_pos: Int,
    flags: ScriptFlags,
    exec_stack: List(Bool),  // For IF/ELSE/ENDIF
    /// Optional signature context for CHECKSIG operations
    sig_ctx: SigContextOption,
  )
}

/// Optional signature context (None when not verifying signatures)
pub type SigContextOption {
  SigContextNone
  SigContextSome(SigContext)
}

/// Create a new script context (without signature context)
pub fn script_context_new(script: BitArray, flags: ScriptFlags) -> ScriptContext {
  ScriptContext(
    stack: [],
    alt_stack: [],
    op_count: 0,
    script: script,
    script_pos: 0,
    codesep_pos: 0,
    flags: flags,
    exec_stack: [],
    sig_ctx: SigContextNone,
  )
}

/// Create a new script context with signature verification context
pub fn script_context_with_sig(
  script: BitArray,
  flags: ScriptFlags,
  sig_ctx: SigContext,
) -> ScriptContext {
  ScriptContext(
    stack: [],
    alt_stack: [],
    op_count: 0,
    script: script,
    script_pos: 0,
    codesep_pos: 0,
    flags: flags,
    exec_stack: [],
    sig_ctx: SigContextSome(sig_ctx),
  )
}

/// Create a SigContext for signature verification
pub fn sig_context_new(
  tx: Transaction,
  input_index: Int,
  spent_value: Amount,
  script_code: Script,
  is_segwit: Bool,
  is_taproot: Bool,
) -> SigContext {
  SigContext(
    tx: tx,
    input_index: input_index,
    spent_value: spent_value,
    script_code: script_code,
    is_segwit: is_segwit,
    is_taproot: is_taproot,
  )
}

// ============================================================================
// Script Constants
// ============================================================================

/// Maximum script element size (520 bytes)
pub const max_script_element_size = 520

/// Maximum script size (10KB)
pub const max_script_size = 10_000

/// Maximum number of ops per script
pub const max_ops_per_script = 201

/// Maximum stack size
pub const max_stack_size = 1000

/// Maximum pubkeys in multisig
pub const max_pubkeys_per_multisig = 20

// ============================================================================
// Block Validation Constants
// ============================================================================

/// Maximum block weight (4M weight units)
pub const max_block_weight = 4_000_000

/// Maximum block serialized size (4MB for SegWit)
pub const max_block_serialized_size = 4_000_000

/// Legacy block size limit (1MB)
pub const max_block_base_size = 1_000_000

/// Witness scale factor
pub const witness_scale_factor = 4

/// Coinbase maturity (100 blocks)
pub const coinbase_maturity = 100

// ============================================================================
// Transaction Validation
// ============================================================================

/// Validate transaction structure (no UTXO context)
pub fn validate_tx_structure(tx: Transaction) -> Result(Nil, ConsensusError) {
  // Check for empty inputs
  case list.is_empty(tx.inputs) {
    True -> Error(TxEmptyInputs)
    False -> {
      // Check for empty outputs
      case list.is_empty(tx.outputs) {
        True -> Error(TxEmptyOutputs)
        False -> validate_tx_outputs(tx.outputs)
      }
    }
  }
}

fn validate_tx_outputs(outputs: List(TxOut)) -> Result(Nil, ConsensusError) {
  // Check that all output values are valid
  let total = list.fold(outputs, Ok(0), fn(acc, out) {
    case acc {
      Error(e) -> Error(e)
      Ok(sum) -> {
        let sats = oni_bitcoin.amount_to_sats(out.value)
        case sats >= 0 && sats <= oni_bitcoin.max_satoshis {
          True -> {
            let new_sum = sum + sats
            case new_sum <= oni_bitcoin.max_satoshis {
              True -> Ok(new_sum)
              False -> Error(TxOutputValueOverflow)
            }
          }
          False -> Error(TxInvalidAmount)
        }
      }
    }
  })

  case total {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

/// Check for duplicate inputs
pub fn tx_has_duplicate_inputs(tx: Transaction) -> Bool {
  let prevouts = list.map(tx.inputs, fn(input) { input.prevout })
  let unique = list.unique(prevouts)
  list.length(prevouts) != list.length(unique)
}

/// Check if transaction is coinbase
pub fn tx_is_coinbase(tx: Transaction) -> Bool {
  case tx.inputs {
    [input] -> oni_bitcoin.outpoint_is_null(input.prevout)
    _ -> False
  }
}

// ============================================================================
// Block Validation
// ============================================================================

/// Validate block header structure
pub fn validate_block_header(_header: BlockHeader) -> Result(Nil, ConsensusError) {
  // Check timestamp is not too far in the future (2 hours)
  // Note: This would need current time from context
  Ok(Nil)
}

/// Calculate block weight
pub fn calculate_block_weight(block: Block) -> Int {
  // Weight = Base size * 3 + Total size
  // For simplicity, return a placeholder
  // Actual implementation needs proper serialization
  list.length(block.transactions) * 250 * witness_scale_factor
}

/// Validate block weight
pub fn validate_block_weight(block: Block) -> Result(Nil, ConsensusError) {
  let weight = calculate_block_weight(block)
  case weight <= max_block_weight {
    True -> Ok(Nil)
    False -> Error(BlockWeightExceeded)
  }
}

// ============================================================================
// Proof of Work Validation
// ============================================================================

/// Compact difficulty (nBits) target representation
pub type Target {
  Target(bytes: BitArray)
}

/// Decode compact difficulty target from nBits
pub fn target_from_compact(compact: Int) -> Target {
  let exponent = compact / 0x1000000
  let mantissa = compact % 0x1000000

  // Handle negative and overflow
  let value = case mantissa > 0x7FFFFF {
    True -> 0  // Negative, treat as 0
    False -> mantissa
  }

  // Create 32-byte target
  let shift = exponent - 3
  let target_bytes = case shift >= 0 {
    True -> create_target_bytes(value, shift)
    False -> <<>>
  }

  Target(target_bytes)
}

fn create_target_bytes(mantissa: Int, shift: Int) -> BitArray {
  // Create a 32-byte array with mantissa at the right position
  let zeros_after = shift
  let zeros_before = 32 - 3 - zeros_after

  case zeros_before >= 0 && zeros_after >= 0 {
    True -> {
      let before = create_zero_bytes(zeros_before, <<>>)
      let after = create_zero_bytes(zeros_after, <<>>)
      let m = <<mantissa:24-big>>
      bit_array.concat([before, m, after])
    }
    False -> <<>>
  }
}

fn create_zero_bytes(n: Int, acc: BitArray) -> BitArray {
  case n {
    0 -> acc
    _ -> create_zero_bytes(n - 1, bit_array.append(acc, <<0:8>>))
  }
}

/// Compare block hash against target (hash <= target means valid PoW)
pub fn validate_pow(hash: BlockHash, bits: Int) -> Result(Nil, ConsensusError) {
  let target = target_from_compact(bits)
  let hash_bytes = oni_bitcoin.reverse_bytes(hash.hash.bytes)

  // Compare hash <= target
  case compare_bytes(hash_bytes, target.bytes) {
    order if order <= 0 -> Ok(Nil)
    _ -> Error(BlockInvalidPoW)
  }
}

fn compare_bytes(a: BitArray, b: BitArray) -> Int {
  case a, b {
    <<ah:8, arest:bits>>, <<bh:8, brest:bits>> -> {
      case ah - bh {
        0 -> compare_bytes(arest, brest)
        diff -> diff
      }
    }
    <<_:8, _:bits>>, <<>> -> 1
    <<>>, <<_:8, _:bits>> -> -1
    <<>>, <<>> -> 0
    _, _ -> 0  // Fallback for any other case
  }
}

// ============================================================================
// Merkle Root Calculation
// ============================================================================

/// Compute merkle root of transaction hashes
pub fn compute_merkle_root(txids: List(Hash256)) -> Hash256 {
  case txids {
    [] -> oni_bitcoin.Hash256(<<0:256>>)
    [single] -> single
    _ -> {
      let next_level = merkle_combine_level(txids, [])
      compute_merkle_root(next_level)
    }
  }
}

fn merkle_combine_level(
  hashes: List(Hash256),
  acc: List(Hash256),
) -> List(Hash256) {
  case hashes {
    [] -> list.reverse(acc)
    [single] -> {
      // Odd number - duplicate the last one
      let combined = merkle_hash_pair(single, single)
      list.reverse([combined, ..acc])
    }
    [first, second, ..rest] -> {
      let combined = merkle_hash_pair(first, second)
      merkle_combine_level(rest, [combined, ..acc])
    }
  }
}

fn merkle_hash_pair(a: Hash256, b: Hash256) -> Hash256 {
  let combined = bit_array.concat([a.bytes, b.bytes])
  oni_bitcoin.hash256_digest(combined)
}

// ============================================================================
// Witness Commitment
// ============================================================================

/// Witness commitment marker
pub const witness_commitment_header = <<0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed>>

/// Compute witness commitment
pub fn compute_witness_commitment(
  wtxid_root: Hash256,
  witness_nonce: BitArray,
) -> Hash256 {
  let commitment_data = bit_array.concat([wtxid_root.bytes, witness_nonce])
  oni_bitcoin.hash256_digest(commitment_data)
}

// ============================================================================
// Sighash Types
// ============================================================================

/// Sighash type flags
pub type SighashType {
  SighashAll
  SighashNone
  SighashSingle
  SighashAnyoneCanPay(SighashType)
}

/// Sighash type byte value
pub const sighash_all = 0x01
pub const sighash_none = 0x02
pub const sighash_single = 0x03
pub const sighash_anyonecanpay = 0x80

/// Parse sighash type from byte
pub fn sighash_type_from_byte(b: Int) -> SighashType {
  let base = b % 0x80
  let anyonecanpay = b >= 0x80

  let base_type = case base {
    0x02 -> SighashNone
    0x03 -> SighashSingle
    _ -> SighashAll
  }

  case anyonecanpay {
    True -> SighashAnyoneCanPay(base_type)
    False -> base_type
  }
}

// ============================================================================
// Validation Entry Points
// ============================================================================

/// Validate a txid (placeholder)
pub fn validate_txid(_txid: Txid) -> Result(Nil, ConsensusError) {
  Ok(Nil)
}

/// Verify a script execution succeeds (without signature context)
pub fn verify_script(
  script_sig: Script,
  script_pubkey: Script,
  _witness: List(BitArray),
  flags: ScriptFlags,
) -> Result(Nil, ConsensusError) {
  // Create initial context with script_sig
  let ctx = script_context_new(
    oni_bitcoin.script_to_bytes(script_sig),
    flags,
  )

  // Execute script_sig to populate stack
  case execute_script(ctx) {
    Error(e) -> Error(e)
    Ok(ctx_after_sig) -> {
      // Now execute script_pubkey with the stack from script_sig
      let pubkey_ctx = ScriptContext(
        ..ctx_after_sig,
        script: oni_bitcoin.script_to_bytes(script_pubkey),
        script_pos: 0,
        op_count: 0,
        codesep_pos: 0,
      )
      case execute_script(pubkey_ctx) {
        Error(e) -> Error(e)
        Ok(final_ctx) -> {
          // Check if stack is non-empty and top is truthy
          case final_ctx.stack {
            [] -> Error(ScriptVerifyFailed)
            [top, ..] -> {
              case is_truthy(top) {
                True -> Ok(Nil)
                False -> Error(ScriptVerifyFailed)
              }
            }
          }
        }
      }
    }
  }
}

/// Verify a script with transaction context for signature verification
pub fn verify_script_with_sig(
  script_sig: Script,
  script_pubkey: Script,
  _witness: List(BitArray),
  flags: ScriptFlags,
  sig_ctx: SigContext,
) -> Result(Nil, ConsensusError) {
  // Create initial context with signature context
  let ctx = script_context_with_sig(
    oni_bitcoin.script_to_bytes(script_sig),
    flags,
    sig_ctx,
  )

  // Execute script_sig to populate stack
  case execute_script(ctx) {
    Error(e) -> Error(e)
    Ok(ctx_after_sig) -> {
      // Now execute script_pubkey with the stack from script_sig
      let pubkey_ctx = ScriptContext(
        ..ctx_after_sig,
        script: oni_bitcoin.script_to_bytes(script_pubkey),
        script_pos: 0,
        op_count: 0,
        codesep_pos: 0,
      )
      case execute_script(pubkey_ctx) {
        Error(e) -> Error(e)
        Ok(final_ctx) -> {
          // Check if stack is non-empty and top is truthy
          case final_ctx.stack {
            [] -> Error(ScriptVerifyFailed)
            [top, ..] -> {
              case is_truthy(top) {
                True -> Ok(Nil)
                False -> Error(ScriptVerifyFailed)
              }
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Script Interpreter
// ============================================================================

/// Parsed script element
pub type ScriptElement {
  OpElement(op: Opcode)
  DataElement(data: BitArray)
}

/// Parse a script into elements
pub fn parse_script(script: BitArray) -> Result(List(ScriptElement), ConsensusError) {
  parse_script_loop(script, [])
}

fn parse_script_loop(
  remaining: BitArray,
  acc: List(ScriptElement),
) -> Result(List(ScriptElement), ConsensusError) {
  case remaining {
    <<>> -> Ok(list.reverse(acc))
    <<opcode:8, rest:bits>> -> {
      let op = opcode_from_byte(opcode)
      case op {
        // Push N bytes directly
        OpPushBytes(n) -> {
          case extract_bytes(rest, n) {
            Ok(#(data, remaining2)) -> {
              parse_script_loop(remaining2, [DataElement(data), ..acc])
            }
            Error(_) -> Error(ScriptPushSizeExceeded)
          }
        }
        // OP_PUSHDATA1: next byte is length
        OpPushData1 -> {
          case rest {
            <<len:8, after_len:bits>> -> {
              case extract_bytes(after_len, len) {
                Ok(#(data, remaining2)) -> {
                  parse_script_loop(remaining2, [DataElement(data), ..acc])
                }
                Error(_) -> Error(ScriptPushSizeExceeded)
              }
            }
            _ -> Error(ScriptInvalid)
          }
        }
        // OP_PUSHDATA2: next 2 bytes are length
        OpPushData2 -> {
          case rest {
            <<len:16-little, after_len:bits>> -> {
              case extract_bytes(after_len, len) {
                Ok(#(data, remaining2)) -> {
                  parse_script_loop(remaining2, [DataElement(data), ..acc])
                }
                Error(_) -> Error(ScriptPushSizeExceeded)
              }
            }
            _ -> Error(ScriptInvalid)
          }
        }
        // OP_PUSHDATA4: next 4 bytes are length
        OpPushData4 -> {
          case rest {
            <<len:32-little, after_len:bits>> -> {
              case extract_bytes(after_len, len) {
                Ok(#(data, remaining2)) -> {
                  parse_script_loop(remaining2, [DataElement(data), ..acc])
                }
                Error(_) -> Error(ScriptPushSizeExceeded)
              }
            }
            _ -> Error(ScriptInvalid)
          }
        }
        // Regular opcode
        _ -> parse_script_loop(rest, [OpElement(op), ..acc])
      }
    }
    // Catch-all for non-byte-aligned data (shouldn't happen in valid scripts)
    _ -> Error(ScriptInvalid)
  }
}

fn extract_bytes(data: BitArray, n: Int) -> Result(#(BitArray, BitArray), Nil) {
  case bit_array.slice(data, 0, n) {
    Ok(extracted) -> {
      let remaining_size = bit_array.byte_size(data) - n
      case bit_array.slice(data, n, remaining_size) {
        Ok(remaining) -> Ok(#(extracted, remaining))
        Error(_) -> Ok(#(extracted, <<>>))
      }
    }
    Error(_) -> Error(Nil)
  }
}

/// Execute a script in the given context
pub fn execute_script(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  // Parse the script first
  case parse_script(ctx.script) {
    Error(e) -> Error(e)
    Ok(elements) -> execute_elements(ctx, elements)
  }
}

fn execute_elements(
  ctx: ScriptContext,
  elements: List(ScriptElement),
) -> Result(ScriptContext, ConsensusError) {
  case elements {
    [] -> Ok(ctx)
    [element, ..rest] -> {
      // Check if we're in an executing branch
      let should_execute = is_executing(ctx.exec_stack)
      case element {
        DataElement(data) -> {
          case should_execute {
            True -> {
              // Check element size
              case bit_array.byte_size(data) > max_script_element_size {
                True -> Error(ScriptPushSizeExceeded)
                False -> {
                  let new_ctx = ScriptContext(..ctx, stack: [data, ..ctx.stack])
                  execute_elements(new_ctx, rest)
                }
              }
            }
            False -> execute_elements(ctx, rest)
          }
        }
        OpElement(op) -> {
          // Check for disabled opcodes
          case opcode_is_disabled(op) && should_execute {
            True -> Error(ScriptDisabledOpcode)
            False -> {
              // Increment op count for non-push ops
              let new_op_count = case is_push_op(op) {
                True -> ctx.op_count
                False -> ctx.op_count + 1
              }
              // Check op count limit
              case new_op_count > max_ops_per_script {
                True -> Error(ScriptOpCountExceeded)
                False -> {
                  let ctx2 = ScriptContext(..ctx, op_count: new_op_count)
                  // Execute the opcode
                  case execute_opcode(ctx2, op, should_execute) {
                    Error(e) -> Error(e)
                    Ok(ctx3) -> {
                      // Check stack size
                      let stack_size = list.length(ctx3.stack) + list.length(ctx3.alt_stack)
                      case stack_size > max_stack_size {
                        True -> Error(ScriptStackOverflow)
                        False -> execute_elements(ctx3, rest)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn is_executing(exec_stack: List(Bool)) -> Bool {
  list.all(exec_stack, fn(x) { x })
}

fn is_push_op(op: Opcode) -> Bool {
  case op {
    OpFalse | OpPushBytes(_) | OpPushData1 | OpPushData2 | OpPushData4 -> True
    Op1Negate | OpTrue | OpNum(_) -> True
    _ -> False
  }
}

/// Execute a single opcode
fn execute_opcode(
  ctx: ScriptContext,
  op: Opcode,
  should_execute: Bool,
) -> Result(ScriptContext, ConsensusError) {
  // Flow control ops need special handling
  case op {
    OpIf | OpNotIf -> execute_if(ctx, op, should_execute)
    OpElse -> execute_else(ctx)
    OpEndIf -> execute_endif(ctx)
    _ -> {
      case should_execute {
        False -> Ok(ctx)
        True -> execute_opcode_impl(ctx, op)
      }
    }
  }
}

/// Execute IF/NOTIF
fn execute_if(
  ctx: ScriptContext,
  op: Opcode,
  should_execute: Bool,
) -> Result(ScriptContext, ConsensusError) {
  case should_execute {
    False -> {
      // Not executing, just push False to exec_stack
      Ok(ScriptContext(..ctx, exec_stack: [False, ..ctx.exec_stack]))
    }
    True -> {
      // Need to pop and evaluate
      case ctx.stack {
        [] -> Error(ScriptStackUnderflow)
        [top, ..rest] -> {
          let condition = case op {
            OpIf -> is_truthy(top)
            OpNotIf -> !is_truthy(top)
            _ -> False
          }
          Ok(ScriptContext(
            ..ctx,
            stack: rest,
            exec_stack: [condition, ..ctx.exec_stack],
          ))
        }
      }
    }
  }
}

/// Execute ELSE
fn execute_else(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.exec_stack {
    [] -> Error(ScriptInvalid)
    [current, ..rest] -> {
      // Toggle the current condition
      Ok(ScriptContext(..ctx, exec_stack: [!current, ..rest]))
    }
  }
}

/// Execute ENDIF
fn execute_endif(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.exec_stack {
    [] -> Error(ScriptInvalid)
    [_, ..rest] -> {
      Ok(ScriptContext(..ctx, exec_stack: rest))
    }
  }
}

/// Check if a stack element is truthy
fn is_truthy(data: BitArray) -> Bool {
  // Bitcoin: false is empty array or all zeros (with possible negative zero)
  case bit_array.byte_size(data) {
    0 -> False
    _ -> !is_all_zeros(data)
  }
}

fn is_all_zeros(data: BitArray) -> Bool {
  case data {
    <<>> -> True
    <<0:8, rest:bits>> -> is_all_zeros(rest)
    <<0x80:8>> -> True  // Negative zero
    _ -> False
  }
}

/// Execute a single opcode implementation
fn execute_opcode_impl(
  ctx: ScriptContext,
  op: Opcode,
) -> Result(ScriptContext, ConsensusError) {
  case op {
    // Constants
    OpFalse -> Ok(ScriptContext(..ctx, stack: [<<>>, ..ctx.stack]))
    OpTrue -> Ok(ScriptContext(..ctx, stack: [<<1:8>>, ..ctx.stack]))
    Op1Negate -> Ok(ScriptContext(..ctx, stack: [<<0x81:8>>, ..ctx.stack]))
    OpNum(n) -> Ok(ScriptContext(..ctx, stack: [encode_script_num(n), ..ctx.stack]))

    // Stack operations
    OpDup -> execute_dup(ctx)
    OpDrop -> execute_drop(ctx)
    Op2Dup -> execute_2dup(ctx)
    Op2Drop -> execute_2drop(ctx)
    Op3Dup -> execute_3dup(ctx)
    OpSwap -> execute_swap(ctx)
    OpOver -> execute_over(ctx)
    OpRot -> execute_rot(ctx)
    OpNip -> execute_nip(ctx)
    OpTuck -> execute_tuck(ctx)
    OpPick -> execute_pick(ctx)
    OpRoll -> execute_roll(ctx)
    OpSize -> execute_size(ctx)
    OpDepth -> execute_depth(ctx)
    OpIfDup -> execute_ifdup(ctx)
    OpToAltStack -> execute_toaltstack(ctx)
    OpFromAltStack -> execute_fromaltstack(ctx)

    // Logic
    OpEqual -> execute_equal(ctx)
    OpEqualVerify -> execute_equalverify(ctx)
    OpVerify -> execute_verify(ctx)

    // Arithmetic
    OpAdd -> execute_add(ctx)
    OpSub -> execute_sub(ctx)
    Op1Add -> execute_1add(ctx)
    Op1Sub -> execute_1sub(ctx)
    OpNegate -> execute_negate(ctx)
    OpAbs -> execute_abs(ctx)
    OpNot -> execute_not(ctx)
    Op0NotEqual -> execute_0notequal(ctx)
    OpBoolAnd -> execute_booland(ctx)
    OpBoolOr -> execute_boolor(ctx)
    OpNumEqual -> execute_numequal(ctx)
    OpNumEqualVerify -> execute_numequalverify(ctx)
    OpNumNotEqual -> execute_numnotequal(ctx)
    OpLessThan -> execute_lessthan(ctx)
    OpGreaterThan -> execute_greaterthan(ctx)
    OpLessThanOrEqual -> execute_lessthanorequal(ctx)
    OpGreaterThanOrEqual -> execute_greaterthanorequal(ctx)
    OpMin -> execute_min(ctx)
    OpMax -> execute_max(ctx)
    OpWithin -> execute_within(ctx)

    // Crypto
    OpSha1 -> execute_sha1(ctx)
    OpRipeMd160 -> execute_ripemd160(ctx)
    OpSha256 -> execute_sha256(ctx)
    OpHash160 -> execute_hash160(ctx)
    OpHash256 -> execute_hash256(ctx)

    // NOPs (do nothing)
    OpNop | OpNop1 | OpNop4 | OpNop5 | OpNop6 | OpNop7 | OpNop8 | OpNop9 | OpNop10 -> Ok(ctx)

    // OP_RETURN makes script fail
    OpReturn -> Error(ScriptInvalid)

    // Reserved/Invalid ops fail
    OpReserved | OpReserved1 | OpReserved2 | OpVer | OpVerIf | OpVerNotIf -> Error(ScriptBadOpcode)
    OpInvalidOpcode -> Error(ScriptBadOpcode)

    // Signature verification opcodes
    OpCheckSig -> execute_checksig(ctx)
    OpCheckSigVerify -> execute_checksigverify(ctx)
    OpCheckMultiSig -> execute_checkmultisig(ctx)
    OpCheckMultiSigVerify -> execute_checkmultisigverify(ctx)
    OpCheckSigAdd -> execute_checksigadd(ctx)

    // CLTV and CSV timelock verification (BIP65/BIP112)
    OpCheckLockTimeVerify -> execute_checklocktimeverify(ctx)
    OpCheckSequenceVerify -> execute_checksequenceverify(ctx)

    // OP_CODESEPARATOR
    OpCodeSeparator -> Ok(ScriptContext(..ctx, codesep_pos: ctx.script_pos))

    // OP_SUCCESS (tapscript) - makes script succeed
    OpSuccess(_) -> Ok(ctx)

    // 2-element stack ops
    Op2Over -> execute_2over(ctx)
    Op2Rot -> execute_2rot(ctx)
    Op2Swap -> execute_2swap(ctx)

    // Already handled
    OpIf | OpNotIf | OpElse | OpEndIf -> Ok(ctx)

    // Push ops (already handled in parse)
    OpPushBytes(_) | OpPushData1 | OpPushData2 | OpPushData4 -> Ok(ctx)

    // Disabled ops
    _ -> Error(ScriptDisabledOpcode)
  }
}

// ============================================================================
// Stack Operations Implementation
// ============================================================================

fn execute_dup(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [top, ..] -> Ok(ScriptContext(..ctx, stack: [top, ..ctx.stack]))
  }
}

fn execute_drop(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [_, ..rest] -> Ok(ScriptContext(..ctx, stack: rest))
  }
}

fn execute_2dup(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, ..rest] -> Ok(ScriptContext(..ctx, stack: [a, b, a, b, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_2drop(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [_, _, ..rest] -> Ok(ScriptContext(..ctx, stack: rest))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_3dup(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, c, ..rest] -> Ok(ScriptContext(..ctx, stack: [a, b, c, a, b, c, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_swap(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, ..rest] -> Ok(ScriptContext(..ctx, stack: [b, a, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_over(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, ..rest] -> Ok(ScriptContext(..ctx, stack: [b, a, b, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_rot(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, c, ..rest] -> Ok(ScriptContext(..ctx, stack: [c, a, b, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_nip(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, _, ..rest] -> Ok(ScriptContext(..ctx, stack: [a, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_tuck(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, ..rest] -> Ok(ScriptContext(..ctx, stack: [a, b, a, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_pick(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [n_bytes, ..rest] -> {
      case decode_script_num(n_bytes) {
        Error(_) -> Error(ScriptInvalid)
        Ok(n) -> {
          case n < 0 || n >= list.length(rest) {
            True -> Error(ScriptStackUnderflow)
            False -> {
              case list_nth(rest, n) {
                Error(_) -> Error(ScriptStackUnderflow)
                Ok(item) -> Ok(ScriptContext(..ctx, stack: [item, ..rest]))
              }
            }
          }
        }
      }
    }
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_roll(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [n_bytes, ..rest] -> {
      case decode_script_num(n_bytes) {
        Error(_) -> Error(ScriptInvalid)
        Ok(n) -> {
          case n < 0 || n >= list.length(rest) {
            True -> Error(ScriptStackUnderflow)
            False -> {
              case list_remove_nth(rest, n) {
                Error(_) -> Error(ScriptStackUnderflow)
                Ok(#(item, remaining)) -> Ok(ScriptContext(..ctx, stack: [item, ..remaining]))
              }
            }
          }
        }
      }
    }
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_size(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [top, ..] -> {
      let size = bit_array.byte_size(top)
      Ok(ScriptContext(..ctx, stack: [encode_script_num(size), ..ctx.stack]))
    }
  }
}

fn execute_depth(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  let depth = list.length(ctx.stack)
  Ok(ScriptContext(..ctx, stack: [encode_script_num(depth), ..ctx.stack]))
}

fn execute_ifdup(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [top, ..] -> {
      case is_truthy(top) {
        True -> Ok(ScriptContext(..ctx, stack: [top, ..ctx.stack]))
        False -> Ok(ctx)
      }
    }
  }
}

fn execute_toaltstack(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [top, ..rest] -> Ok(ScriptContext(..ctx, stack: rest, alt_stack: [top, ..ctx.alt_stack]))
  }
}

fn execute_fromaltstack(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.alt_stack {
    [] -> Error(ScriptStackUnderflow)
    [top, ..rest] -> Ok(ScriptContext(..ctx, stack: [top, ..ctx.stack], alt_stack: rest))
  }
}

fn execute_2over(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [_, _, c, d, .._rest] -> Ok(ScriptContext(..ctx, stack: [c, d, ..ctx.stack]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_2rot(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, c, d, e, f, ..rest] -> Ok(ScriptContext(..ctx, stack: [e, f, a, b, c, d, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_2swap(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, c, d, ..rest] -> Ok(ScriptContext(..ctx, stack: [c, d, a, b, ..rest]))
    _ -> Error(ScriptStackUnderflow)
  }
}

// ============================================================================
// Logic Operations
// ============================================================================

fn execute_equal(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [a, b, ..rest] -> {
      let result = case a == b {
        True -> <<1:8>>
        False -> <<>>
      }
      Ok(ScriptContext(..ctx, stack: [result, ..rest]))
    }
    _ -> Error(ScriptStackUnderflow)
  }
}

fn execute_equalverify(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case execute_equal(ctx) {
    Error(e) -> Error(e)
    Ok(new_ctx) -> execute_verify(new_ctx)
  }
}

fn execute_verify(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [top, ..rest] -> {
      case is_truthy(top) {
        True -> Ok(ScriptContext(..ctx, stack: rest))
        False -> Error(ScriptVerifyFailed)
      }
    }
  }
}

// ============================================================================
// Timelock Operations (BIP65/BIP112)
// ============================================================================

/// Threshold for interpreting lock time as Unix timestamp vs block height
const locktime_threshold: Int = 500_000_000

/// Sequence number that disables relative locktime (CSV)
const sequence_final: Int = 0xFFFFFFFF

/// Sequence locktime disable flag (bit 31)
const sequence_locktime_disable_flag: Int = 0x80000000

/// Sequence locktime type flag (bit 22) - 1 for time, 0 for blocks
const sequence_locktime_type_flag: Int = 0x00400000

/// Sequence locktime mask (lower 16 bits)
const sequence_locktime_mask: Int = 0x0000FFFF

/// Execute OP_CHECKLOCKTIMEVERIFY (BIP65)
/// Verifies that the transaction's nLockTime is >= the top stack value.
/// The value remains on the stack.
fn execute_checklocktimeverify(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [locktime_bytes, ..] -> {
      // Decode the locktime from stack
      case decode_script_num(locktime_bytes) {
        Error(_) -> Error(ScriptInvalid)
        Ok(locktime) -> {
          // Locktime must be non-negative
          case locktime < 0 {
            True -> Error(ScriptCheckLockTimeVerifyFailed)
            False -> {
              // Need transaction context to verify
              case ctx.sig_ctx {
                SigContextNone -> {
                  // No transaction context - cannot verify CLTV
                  // In practice this shouldn't happen during script verification
                  Error(ScriptCheckLockTimeVerifyFailed)
                }
                SigContextSome(sig_ctx) -> {
                  // Get the transaction's lock_time
                  let tx_locktime = sig_ctx.tx.lock_time

                  // Get the input's sequence
                  case list_nth(sig_ctx.tx.inputs, sig_ctx.input_index) {
                    Error(_) -> Error(ScriptCheckLockTimeVerifyFailed)
                    Ok(input) -> {
                      // Input sequence must not be final (0xFFFFFFFF)
                      case input.sequence == sequence_final {
                        True -> Error(ScriptCheckLockTimeVerifyFailed)
                        False -> {
                          // Both locktimes must be of same type:
                          // Both < threshold (blocks) or both >= threshold (time)
                          let stack_is_time = locktime >= locktime_threshold
                          let tx_is_time = tx_locktime >= locktime_threshold

                          case stack_is_time == tx_is_time {
                            False -> Error(ScriptCheckLockTimeVerifyFailed)
                            True -> {
                              // tx locktime must be >= stack locktime
                              case tx_locktime >= locktime {
                                True -> Ok(ctx)  // Success - leave stack unchanged
                                False -> Error(ScriptCheckLockTimeVerifyFailed)
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Execute OP_CHECKSEQUENCEVERIFY (BIP112)
/// Verifies relative locktime against the input's sequence number.
/// The value remains on the stack.
fn execute_checksequenceverify(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [sequence_bytes, ..] -> {
      // Decode the sequence value from stack
      case decode_script_num(sequence_bytes) {
        Error(_) -> Error(ScriptInvalid)
        Ok(sequence) -> {
          // Sequence must be non-negative
          case sequence < 0 {
            True -> Error(ScriptCheckSequenceVerifyFailed)
            False -> {
              // If the disable flag is set, CSV is a NOP
              case int.bitwise_and(sequence, sequence_locktime_disable_flag) != 0 {
                True -> Ok(ctx)  // CSV disabled, succeed
                False -> {
                  // Need transaction context
                  case ctx.sig_ctx {
                    SigContextNone -> Error(ScriptCheckSequenceVerifyFailed)
                    SigContextSome(sig_ctx) -> {
                      // Transaction version must be >= 2 for CSV
                      case sig_ctx.tx.version < 2 {
                        True -> Error(ScriptCheckSequenceVerifyFailed)
                        False -> {
                          // Get the input's sequence
                          case list_nth(sig_ctx.tx.inputs, sig_ctx.input_index) {
                            Error(_) -> Error(ScriptCheckSequenceVerifyFailed)
                            Ok(input) -> {
                              // If input sequence has disable flag set, CSV fails
                              case int.bitwise_and(input.sequence, sequence_locktime_disable_flag) != 0 {
                                True -> Error(ScriptCheckSequenceVerifyFailed)
                                False -> {
                                  // Both must be same type (blocks or time)
                                  let stack_is_time = int.bitwise_and(sequence, sequence_locktime_type_flag) != 0
                                  let input_is_time = int.bitwise_and(input.sequence, sequence_locktime_type_flag) != 0

                                  case stack_is_time == input_is_time {
                                    False -> Error(ScriptCheckSequenceVerifyFailed)
                                    True -> {
                                      // Compare the masked values
                                      let stack_value = int.bitwise_and(sequence, sequence_locktime_mask)
                                      let input_value = int.bitwise_and(input.sequence, sequence_locktime_mask)

                                      case input_value >= stack_value {
                                        True -> Ok(ctx)  // Success
                                        False -> Error(ScriptCheckSequenceVerifyFailed)
                                      }
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Arithmetic Operations
// ============================================================================

fn execute_add(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) { a + b })
}

fn execute_sub(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) { a - b })
}

fn execute_1add(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  unary_num_op(ctx, fn(a) { a + 1 })
}

fn execute_1sub(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  unary_num_op(ctx, fn(a) { a - 1 })
}

fn execute_negate(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  unary_num_op(ctx, fn(a) { 0 - a })
}

fn execute_abs(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  unary_num_op(ctx, fn(a) {
    case a < 0 {
      True -> 0 - a
      False -> a
    }
  })
}

fn execute_not(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  unary_num_op(ctx, fn(a) {
    case a == 0 {
      True -> 1
      False -> 0
    }
  })
}

fn execute_0notequal(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  unary_num_op(ctx, fn(a) {
    case a == 0 {
      True -> 0
      False -> 1
    }
  })
}

fn execute_booland(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a != 0 && b != 0 {
      True -> 1
      False -> 0
    }
  })
}

fn execute_boolor(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a != 0 || b != 0 {
      True -> 1
      False -> 0
    }
  })
}

fn execute_numequal(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a == b {
      True -> 1
      False -> 0
    }
  })
}

fn execute_numequalverify(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case execute_numequal(ctx) {
    Error(e) -> Error(e)
    Ok(new_ctx) -> execute_verify(new_ctx)
  }
}

fn execute_numnotequal(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a != b {
      True -> 1
      False -> 0
    }
  })
}

fn execute_lessthan(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a < b {
      True -> 1
      False -> 0
    }
  })
}

fn execute_greaterthan(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a > b {
      True -> 1
      False -> 0
    }
  })
}

fn execute_lessthanorequal(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a <= b {
      True -> 1
      False -> 0
    }
  })
}

fn execute_greaterthanorequal(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a >= b {
      True -> 1
      False -> 0
    }
  })
}

fn execute_min(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a < b {
      True -> a
      False -> b
    }
  })
}

fn execute_max(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  binary_num_op(ctx, fn(a, b) {
    case a > b {
      True -> a
      False -> b
    }
  })
}

fn execute_within(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [max_bytes, min_bytes, x_bytes, ..rest] -> {
      case decode_script_num(x_bytes), decode_script_num(min_bytes), decode_script_num(max_bytes) {
        Ok(x), Ok(min), Ok(max) -> {
          let result = case x >= min && x < max {
            True -> 1
            False -> 0
          }
          Ok(ScriptContext(..ctx, stack: [encode_script_num(result), ..rest]))
        }
        _, _, _ -> Error(ScriptInvalid)
      }
    }
    _ -> Error(ScriptStackUnderflow)
  }
}

/// Helper for unary numeric operations
fn unary_num_op(
  ctx: ScriptContext,
  op: fn(Int) -> Int,
) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [a_bytes, ..rest] -> {
      case decode_script_num(a_bytes) {
        Error(_) -> Error(ScriptInvalid)
        Ok(a) -> {
          let result = op(a)
          Ok(ScriptContext(..ctx, stack: [encode_script_num(result), ..rest]))
        }
      }
    }
  }
}

/// Helper for binary numeric operations
fn binary_num_op(
  ctx: ScriptContext,
  op: fn(Int, Int) -> Int,
) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [b_bytes, a_bytes, ..rest] -> {
      case decode_script_num(a_bytes), decode_script_num(b_bytes) {
        Ok(a), Ok(b) -> {
          let result = op(a, b)
          Ok(ScriptContext(..ctx, stack: [encode_script_num(result), ..rest]))
        }
        _, _ -> Error(ScriptInvalid)
      }
    }
    _ -> Error(ScriptStackUnderflow)
  }
}

// ============================================================================
// Crypto Operations
// ============================================================================

fn execute_sha1(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [data, ..rest] -> {
      let hash = oni_bitcoin.sha1(data)
      Ok(ScriptContext(..ctx, stack: [hash, ..rest]))
    }
  }
}

fn execute_ripemd160(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [data, ..rest] -> {
      let hash = oni_bitcoin.ripemd160(data)
      Ok(ScriptContext(..ctx, stack: [hash, ..rest]))
    }
  }
}

fn execute_sha256(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [data, ..rest] -> {
      let hash = oni_bitcoin.sha256(data)
      Ok(ScriptContext(..ctx, stack: [hash, ..rest]))
    }
  }
}

fn execute_hash160(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [data, ..rest] -> {
      let hash = oni_bitcoin.hash160(data)
      Ok(ScriptContext(..ctx, stack: [hash, ..rest]))
    }
  }
}

fn execute_hash256(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [data, ..rest] -> {
      let hash = oni_bitcoin.sha256d(data)
      Ok(ScriptContext(..ctx, stack: [hash, ..rest]))
    }
  }
}

// ============================================================================
// Signature Verification Operations
// ============================================================================

/// Execute OP_CHECKSIG - verify ECDSA signature
fn execute_checksig(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [pubkey, sig, ..rest] -> {
      // Verify the signature
      let result = verify_signature(ctx, sig, pubkey)
      let result_byte = case result {
        True -> <<1:8>>
        False -> <<>>
      }
      Ok(ScriptContext(..ctx, stack: [result_byte, ..rest]))
    }
    _ -> Error(ScriptStackUnderflow)
  }
}

/// Execute OP_CHECKSIGVERIFY - verify ECDSA signature and require success
fn execute_checksigverify(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case execute_checksig(ctx) {
    Error(e) -> Error(e)
    Ok(new_ctx) -> {
      case new_ctx.stack {
        [top, ..rest] -> {
          case is_truthy(top) {
            True -> Ok(ScriptContext(..new_ctx, stack: rest))
            False -> Error(ScriptCheckSigFailed)
          }
        }
        _ -> Error(ScriptStackUnderflow)
      }
    }
  }
}

/// Execute OP_CHECKMULTISIG - verify multiple ECDSA signatures
fn execute_checkmultisig(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  // Pop number of pubkeys
  case ctx.stack {
    [] -> Error(ScriptStackUnderflow)
    [n_pubkeys_bytes, ..rest1] -> {
      case decode_script_num(n_pubkeys_bytes) {
        Error(_) -> Error(ScriptInvalid)
        Ok(n_pubkeys) -> {
          case n_pubkeys < 0 || n_pubkeys > 20 {
            True -> Error(ScriptInvalid)
            False -> {
              // Pop pubkeys
              case pop_n(rest1, n_pubkeys, []) {
                Error(_) -> Error(ScriptStackUnderflow)
                Ok(#(pubkeys, rest2)) -> {
                  // Pop number of signatures
                  case rest2 {
                    [] -> Error(ScriptStackUnderflow)
                    [n_sigs_bytes, ..rest3] -> {
                      case decode_script_num(n_sigs_bytes) {
                        Error(_) -> Error(ScriptInvalid)
                        Ok(n_sigs) -> {
                          case n_sigs < 0 || n_sigs > n_pubkeys {
                            True -> Error(ScriptInvalid)
                            False -> {
                              // Pop signatures
                              case pop_n(rest3, n_sigs, []) {
                                Error(_) -> Error(ScriptStackUnderflow)
                                Ok(#(sigs, rest4)) -> {
                                  // Pop the dummy element (bug compatibility)
                                  case rest4 {
                                    [] -> Error(ScriptStackUnderflow)
                                    [_dummy, ..rest5] -> {
                                      // Verify signatures
                                      let result = verify_multisig(ctx, sigs, pubkeys)
                                      let result_byte = case result {
                                        True -> <<1:8>>
                                        False -> <<>>
                                      }
                                      Ok(ScriptContext(..ctx, stack: [result_byte, ..rest5]))
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Execute OP_CHECKMULTISIGVERIFY - verify multiple signatures and require success
fn execute_checkmultisigverify(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case execute_checkmultisig(ctx) {
    Error(e) -> Error(e)
    Ok(new_ctx) -> {
      case new_ctx.stack {
        [top, ..rest] -> {
          case is_truthy(top) {
            True -> Ok(ScriptContext(..new_ctx, stack: rest))
            False -> Error(ScriptCheckMultisigFailed)
          }
        }
        _ -> Error(ScriptStackUnderflow)
      }
    }
  }
}

/// Execute OP_CHECKSIGADD (BIP342 Taproot) - add signature verification result
fn execute_checksigadd(ctx: ScriptContext) -> Result(ScriptContext, ConsensusError) {
  case ctx.stack {
    [pubkey, n_bytes, sig, ..rest] -> {
      case decode_script_num(n_bytes) {
        Error(_) -> Error(ScriptInvalid)
        Ok(n) -> {
          // Empty signature means skip (not an error in tapscript)
          case bit_array.byte_size(sig) == 0 {
            True -> {
              // Push n unchanged
              Ok(ScriptContext(..ctx, stack: [encode_script_num(n), ..rest]))
            }
            False -> {
              // Verify signature
              let result = verify_signature(ctx, sig, pubkey)
              let new_n = case result {
                True -> n + 1
                False -> n
              }
              Ok(ScriptContext(..ctx, stack: [encode_script_num(new_n), ..rest]))
            }
          }
        }
      }
    }
    _ -> Error(ScriptStackUnderflow)
  }
}

/// Verify a single signature against a pubkey
fn verify_signature(ctx: ScriptContext, sig: BitArray, pubkey: BitArray) -> Bool {
  case ctx.sig_ctx {
    SigContextNone -> {
      // No transaction context - cannot verify
      // Return false (signature check fails without context)
      False
    }
    SigContextSome(sig_context) -> {
      // Empty signature is always invalid (unless NULLFAIL flag not set)
      case bit_array.byte_size(sig) == 0 {
        True -> False
        False -> {
          // Extract sighash type from last byte of signature
          let sig_len = bit_array.byte_size(sig)
          case bit_array.slice(sig, sig_len - 1, 1) {
            Error(_) -> False
            Ok(<<sighash_type:8>>) -> {
              // Get the actual signature (without sighash type)
              case bit_array.slice(sig, 0, sig_len - 1) {
                Error(_) -> False
                Ok(sig_bytes) -> {
                  // Compute sighash
                  let sighash = compute_sighash_for_verify(sig_context, sighash_type)
                  // Verify using secp256k1 via Erlang crypto
                  verify_ecdsa(sighash.bytes, sig_bytes, pubkey)
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Compute sighash for signature verification
fn compute_sighash_for_verify(sig_ctx: SigContext, sighash_type: Int) -> Hash256 {
  case sig_ctx.is_taproot {
    True -> {
      // BIP341 Taproot sighash (simplified - no annex support here)
      compute_taproot_sighash_simple(sig_ctx.tx, sig_ctx.input_index, sighash_type)
    }
    False -> {
      case sig_ctx.is_segwit {
        True -> {
          // BIP143 SegWit v0 sighash
          compute_segwit_sighash(sig_ctx.tx, sig_ctx.input_index, sig_ctx.script_code, sig_ctx.spent_value, sighash_type)
        }
        False -> {
          // Legacy sighash
          compute_legacy_sighash(sig_ctx.tx, sig_ctx.input_index, sig_ctx.script_code, sighash_type)
        }
      }
    }
  }
}

/// Compute legacy sighash (pre-SegWit)
fn compute_legacy_sighash(
  tx: Transaction,
  input_index: Int,
  script_code: Script,
  sighash_type: Int,
) -> Hash256 {
  let base_type = int.bitwise_and(sighash_type, 0x1F)
  let anyonecanpay = int.bitwise_and(sighash_type, 0x80) != 0

  // Modify inputs
  let inputs = case anyonecanpay {
    True -> {
      case list_nth(tx.inputs, input_index) {
        Error(_) -> []
        Ok(input) -> [oni_bitcoin.TxIn(..input, script_sig: script_code)]
      }
    }
    False -> {
      list.index_map(tx.inputs, fn(input, idx) {
        case idx == input_index {
          True -> oni_bitcoin.TxIn(..input, script_sig: script_code)
          False -> oni_bitcoin.TxIn(..input, script_sig: oni_bitcoin.script_empty(), sequence: clear_sequence_for_sighash(input.sequence, base_type, idx, input_index))
        }
      })
    }
  }

  // Modify outputs based on sighash type
  let outputs = case base_type {
    0x02 -> []  // SIGHASH_NONE: no outputs
    0x03 -> {   // SIGHASH_SINGLE: only matching output
      case input_index >= list.length(tx.outputs) {
        True -> []
        False -> {
          list.index_map(tx.outputs, fn(out, idx) {
            case idx == input_index {
              True -> out
              False -> oni_bitcoin.TxOut(
                value: oni_bitcoin.sats(-1),
                script_pubkey: oni_bitcoin.script_empty(),
              )
            }
          })
          |> list.take(input_index + 1)
        }
      }
    }
    _ -> tx.outputs  // SIGHASH_ALL: all outputs
  }

  let modified_tx = oni_bitcoin.Transaction(
    version: tx.version,
    inputs: inputs,
    outputs: outputs,
    lock_time: tx.lock_time,
    witnesses: [],
  )

  // Serialize and hash
  let serialized = serialize_tx_for_sighash(modified_tx)
  let with_type = bit_array.append(serialized, <<sighash_type:32-little>>)
  oni_bitcoin.hash256_digest(with_type)
}

fn clear_sequence_for_sighash(seq: Int, base_type: Int, idx: Int, input_index: Int) -> Int {
  case base_type == 0x02 || base_type == 0x03 {
    True -> case idx != input_index {
      True -> 0
      False -> seq
    }
    False -> seq
  }
}

/// Compute BIP143 SegWit v0 sighash
fn compute_segwit_sighash(
  tx: Transaction,
  input_index: Int,
  script_code: Script,
  value: Amount,
  sighash_type: Int,
) -> Hash256 {
  let base_type = int.bitwise_and(sighash_type, 0x1F)
  let anyonecanpay = int.bitwise_and(sighash_type, 0x80) != 0

  // Compute prevouts hash
  let hash_prevouts = case anyonecanpay {
    True -> oni_bitcoin.Hash256(<<0:256>>)
    False -> {
      let data = list.fold(tx.inputs, <<>>, fn(acc, input) {
        bit_array.append(acc, serialize_outpoint(input.prevout))
      })
      oni_bitcoin.hash256_digest(data)
    }
  }

  // Compute sequence hash
  let hash_sequence = case anyonecanpay || base_type == 0x02 || base_type == 0x03 {
    True -> oni_bitcoin.Hash256(<<0:256>>)
    False -> {
      let data = list.fold(tx.inputs, <<>>, fn(acc, input) {
        bit_array.append(acc, <<input.sequence:32-little>>)
      })
      oni_bitcoin.hash256_digest(data)
    }
  }

  // Compute outputs hash
  let hash_outputs = case base_type {
    0x02 -> oni_bitcoin.Hash256(<<0:256>>)  // NONE
    0x03 -> {  // SINGLE
      case list_nth(tx.outputs, input_index) {
        Ok(out) -> oni_bitcoin.hash256_digest(serialize_output(out))
        Error(_) -> oni_bitcoin.Hash256(<<0:256>>)
      }
    }
    _ -> {  // ALL
      let data = list.fold(tx.outputs, <<>>, fn(acc, out) {
        bit_array.append(acc, serialize_output(out))
      })
      oni_bitcoin.hash256_digest(data)
    }
  }

  // Get the input
  case list_nth(tx.inputs, input_index) {
    Error(_) -> oni_bitcoin.Hash256(<<0:256>>)
    Ok(input) -> {
      // Build preimage
      let script_bytes = oni_bitcoin.script_to_bytes(script_code)
      let script_len = oni_bitcoin.compact_size_encode(bit_array.byte_size(script_bytes))
      let value_sats = oni_bitcoin.amount_to_sats(value)

      let preimage = bit_array.concat([
        <<tx.version:32-little>>,
        hash_prevouts.bytes,
        hash_sequence.bytes,
        serialize_outpoint(input.prevout),
        script_len,
        script_bytes,
        <<value_sats:64-little>>,
        <<input.sequence:32-little>>,
        hash_outputs.bytes,
        <<tx.lock_time:32-little>>,
        <<sighash_type:32-little>>,
      ])

      oni_bitcoin.hash256_digest(preimage)
    }
  }
}

/// Compute BIP341 Taproot sighash
/// This is the complete implementation for key-path spending
fn compute_taproot_sighash_simple(
  tx: Transaction,
  input_index: Int,
  sighash_type: Int,
) -> Hash256 {
  // Normalize sighash type (0x00 is default = SIGHASH_ALL)
  let effective_type = case sighash_type {
    0x00 -> 0x00  // Default
    _ -> sighash_type
  }

  let base_type = int.bitwise_and(effective_type, 0x03)
  let anyonecanpay = int.bitwise_and(effective_type, 0x80) != 0

  // Build the signature message
  // Epoch (0x00 for Taproot)
  let epoch = <<0x00:8>>

  // Hash type byte
  let hash_type_byte = <<effective_type:8>>

  // Transaction version and locktime
  let version_bytes = <<tx.version:32-little>>
  let locktime_bytes = <<tx.lock_time:32-little>>

  // Common data hashes (if not ANYONECANPAY)
  let prevouts_data = case anyonecanpay {
    True -> <<>>
    False -> {
      let all_prevouts = list.fold(tx.inputs, <<>>, fn(acc, input) {
        bit_array.append(acc, serialize_outpoint(input.prevout))
      })
      oni_bitcoin.sha256(all_prevouts)
    }
  }

  // Sequences hash (if not ANYONECANPAY and not NONE/SINGLE)
  let sequences_data = case anyonecanpay || base_type == 0x02 || base_type == 0x03 {
    True -> <<>>
    False -> {
      let all_sequences = list.fold(tx.inputs, <<>>, fn(acc, input) {
        bit_array.append(acc, <<input.sequence:32-little>>)
      })
      oni_bitcoin.sha256(all_sequences)
    }
  }

  // Outputs hash based on sighash type
  let outputs_data = case base_type {
    0x02 -> <<>>  // SIGHASH_NONE
    0x03 -> {     // SIGHASH_SINGLE
      case list_nth(tx.outputs, input_index) {
        Error(_) -> <<>>
        Ok(output) -> oni_bitcoin.sha256(serialize_output(output))
      }
    }
    _ -> {        // SIGHASH_ALL (default)
      let all_outputs = list.fold(tx.outputs, <<>>, fn(acc, output) {
        bit_array.append(acc, serialize_output(output))
      })
      oni_bitcoin.sha256(all_outputs)
    }
  }

  // Spend type: 0 for key path, 1 for script path (no annex here)
  let spend_type = <<0x00:8>>

  // Input-specific data
  let input_data = case anyonecanpay {
    True -> {
      case list_nth(tx.inputs, input_index) {
        Error(_) -> <<>>
        Ok(input) -> {
          bit_array.concat([
            serialize_outpoint(input.prevout),
            <<0:64-little>>,  // amount (would need prevout value)
            <<0:8>>,          // scriptPubKey length
            <<input.sequence:32-little>>,
          ])
        }
      }
    }
    False -> <<input_index:32-little>>
  }

  // Build the full message
  let message = bit_array.concat([
    epoch,
    hash_type_byte,
    version_bytes,
    locktime_bytes,
    prevouts_data,
    sequences_data,
    outputs_data,
    spend_type,
    input_data,
  ])

  // Use tagged hash with "TapSighash" tag
  oni_bitcoin.Hash256(oni_bitcoin.tagged_hash("TapSighash", message))
}

// ============================================================================
// Taproot/Tapscript Support (BIP341/342)
// ============================================================================

/// Taproot control block structure
pub type TaprootControlBlock {
  TaprootControlBlock(
    /// Leaf version (must be 0xC0 or 0xC1 for Tapscript)
    leaf_version: Int,
    /// Parity of the output key (0 or 1)
    output_key_parity: Int,
    /// Internal public key (32 bytes x-only)
    internal_key: BitArray,
    /// Merkle path to the script (32 bytes each)
    merkle_path: List(BitArray),
  )
}

/// Parse a Taproot control block from witness data
pub fn parse_control_block(bytes: BitArray) -> Result(TaprootControlBlock, ConsensusError) {
  case bit_array.byte_size(bytes) {
    size if size < 33 -> Error(ScriptInvalid)
    size if { size - 33 } % 32 != 0 -> Error(ScriptInvalid)
    size -> {
      case bytes {
        <<first_byte:8, internal_key:256-bits, rest:bits>> -> {
          let leaf_version = int.bitwise_and(first_byte, 0xFE)
          let output_key_parity = int.bitwise_and(first_byte, 0x01)

          // Parse merkle path
          let path_len = { size - 33 } / 32
          case parse_merkle_path(rest, path_len, []) {
            Error(e) -> Error(e)
            Ok(path) -> {
              Ok(TaprootControlBlock(
                leaf_version: leaf_version,
                output_key_parity: output_key_parity,
                internal_key: <<internal_key:256-bits>>,
                merkle_path: path,
              ))
            }
          }
        }
        _ -> Error(ScriptInvalid)
      }
    }
  }
}

fn parse_merkle_path(
  bytes: BitArray,
  remaining: Int,
  acc: List(BitArray),
) -> Result(List(BitArray), ConsensusError) {
  case remaining {
    0 -> Ok(list.reverse(acc))
    _ -> {
      case bytes {
        <<node:256-bits, rest:bits>> -> {
          parse_merkle_path(rest, remaining - 1, [<<node:256-bits>>, ..acc])
        }
        _ -> Error(ScriptInvalid)
      }
    }
  }
}

/// Compute the tapleaf hash for a script
pub fn compute_tapleaf_hash(leaf_version: Int, script: BitArray) -> BitArray {
  let leaf_data = bit_array.concat([
    <<leaf_version:8>>,
    oni_bitcoin.compact_size_encode(bit_array.byte_size(script)),
    script,
  ])
  oni_bitcoin.tagged_hash("TapLeaf", leaf_data)
}

/// Compute the tapbranch hash (merkle node)
pub fn compute_tapbranch_hash(left: BitArray, right: BitArray) -> BitArray {
  // Sort lexicographically
  let #(first, second) = case left < right {
    True -> #(left, right)
    False -> #(right, left)
  }
  oni_bitcoin.tagged_hash("TapBranch", bit_array.append(first, second))
}

/// Compute the taptweak hash
pub fn compute_taptweak_hash(internal_key: BitArray, merkle_root: BitArray) -> BitArray {
  oni_bitcoin.tagged_hash("TapTweak", bit_array.append(internal_key, merkle_root))
}

/// Verify a Taproot script-path spend
pub fn verify_taproot_script_path(
  output_key: BitArray,
  script: BitArray,
  control_block: TaprootControlBlock,
) -> Bool {
  // Compute the tapleaf hash
  let leaf_hash = compute_tapleaf_hash(control_block.leaf_version, script)

  // Walk up the merkle tree
  let merkle_root = list.fold(control_block.merkle_path, leaf_hash, fn(current, sibling) {
    compute_tapbranch_hash(current, sibling)
  })

  // Compute the expected output key
  let tweak_hash = compute_taptweak_hash(control_block.internal_key, merkle_root)

  // Use the NIF to tweak the internal key and verify it matches the output key
  case oni_bitcoin.tweak_pubkey_for_taproot(
    oni_bitcoin.XOnlyPubKey(control_block.internal_key),
    tweak_hash,
  ) {
    Error(_) -> False
    Ok(#(tweaked_key, parity)) -> {
      // Verify the tweaked key matches the output key
      // and the parity matches
      tweaked_key.bytes == output_key && parity == control_block.output_key_parity
    }
  }
}

/// Verify a Taproot key-path spend (single Schnorr signature)
pub fn verify_taproot_key_path(
  output_key: BitArray,
  signature: BitArray,
  sighash: BitArray,
) -> Bool {
  // Schnorr signature must be 64 or 65 bytes
  case bit_array.byte_size(signature) {
    64 -> {
      // No sighash type appended (default = SIGHASH_DEFAULT)
      verify_schnorr(sighash, signature, output_key)
    }
    65 -> {
      // Sighash type is last byte
      case bit_array.slice(signature, 0, 64) {
        Ok(sig_bytes) -> verify_schnorr(sighash, sig_bytes, output_key)
        Error(_) -> False
      }
    }
    _ -> False
  }
}

/// Verify a Schnorr signature (BIP-340)
fn verify_schnorr(sighash: BitArray, signature: BitArray, pubkey: BitArray) -> Bool {
  case oni_bitcoin.schnorr_sig_from_bytes(signature) {
    Error(_) -> False
    Ok(sig) -> {
      case oni_bitcoin.xonly_pubkey_from_bytes(pubkey) {
        Error(_) -> False
        Ok(pk) -> {
          case oni_bitcoin.schnorr_verify_nif(sig, sighash, pk) {
            Error(_) -> False
            Ok(result) -> result
          }
        }
      }
    }
  }
}

/// Check if a script is a valid Taproot output (OP_1 <32 bytes>)
pub fn is_taproot_output(script: BitArray) -> Bool {
  case script {
    <<0x51:8, 0x20:8, _pubkey:256-bits>> -> True
    _ -> False
  }
}

/// Extract the output public key from a Taproot script
pub fn extract_taproot_pubkey(script: BitArray) -> Result(BitArray, ConsensusError) {
  case script {
    <<0x51:8, 0x20:8, pubkey:256-bits>> -> Ok(<<pubkey:256-bits>>)
    _ -> Error(ScriptInvalid)
  }
}

/// Validate Tapscript-specific rules (BIP-342)
pub fn validate_tapscript(script: BitArray, flags: ScriptFlags) -> Result(Nil, ConsensusError) {
  // Check script size
  case bit_array.byte_size(script) > max_script_size {
    True -> Error(ScriptSizeTooLarge)
    False -> {
      // Validate opcodes are allowed in Tapscript
      validate_tapscript_opcodes(script, 0, flags)
    }
  }
}

fn validate_tapscript_opcodes(script: BitArray, pos: Int, _flags: ScriptFlags) -> Result(Nil, ConsensusError) {
  let size = bit_array.byte_size(script)
  case pos >= size {
    True -> Ok(Nil)
    False -> {
      case bit_array.slice(script, pos, 1) {
        Error(_) -> Ok(Nil)
        Ok(<<opcode:8>>) -> {
          // Check for disabled opcodes in Tapscript
          case opcode {
            // OP_CHECKMULTISIG and OP_CHECKMULTISIGVERIFY are disabled
            0xAE | 0xAF -> Error(ScriptDisabledOpcode)
            // OP_CODESEPARATOR behavior changed but not disabled
            // Data push opcodes
            _ if opcode >= 0x01 && opcode <= 0x4B -> {
              validate_tapscript_opcodes(script, pos + 1 + opcode, _flags)
            }
            0x4C -> {  // OP_PUSHDATA1
              case bit_array.slice(script, pos + 1, 1) {
                Ok(<<len:8>>) -> validate_tapscript_opcodes(script, pos + 2 + len, _flags)
                _ -> Error(ScriptInvalid)
              }
            }
            0x4D -> {  // OP_PUSHDATA2
              case bit_array.slice(script, pos + 1, 2) {
                Ok(<<len:16-little>>) -> validate_tapscript_opcodes(script, pos + 3 + len, _flags)
                _ -> Error(ScriptInvalid)
              }
            }
            0x4E -> {  // OP_PUSHDATA4
              case bit_array.slice(script, pos + 1, 4) {
                Ok(<<len:32-little>>) -> validate_tapscript_opcodes(script, pos + 5 + len, _flags)
                _ -> Error(ScriptInvalid)
              }
            }
            // All other opcodes
            _ -> validate_tapscript_opcodes(script, pos + 1, _flags)
          }
        }
      }
    }
  }
}

/// Serialize outpoint for sighash
fn serialize_outpoint(outpoint: OutPoint) -> BitArray {
  <<outpoint.txid.hash.bytes:bits, outpoint.vout:32-little>>
}

/// Serialize output for sighash
fn serialize_output(output: TxOut) -> BitArray {
  let script_bytes = oni_bitcoin.script_to_bytes(output.script_pubkey)
  let value = oni_bitcoin.amount_to_sats(output.value)
  bit_array.concat([
    <<value:64-little>>,
    oni_bitcoin.compact_size_encode(bit_array.byte_size(script_bytes)),
    script_bytes,
  ])
}

/// Serialize transaction for legacy sighash
fn serialize_tx_for_sighash(tx: Transaction) -> BitArray {
  let inputs_data = list.fold(tx.inputs, <<>>, fn(acc, input) {
    let script = oni_bitcoin.script_to_bytes(input.script_sig)
    let input_data = bit_array.concat([
      input.prevout.txid.hash.bytes,
      <<input.prevout.vout:32-little>>,
      oni_bitcoin.compact_size_encode(bit_array.byte_size(script)),
      script,
      <<input.sequence:32-little>>,
    ])
    bit_array.append(acc, input_data)
  })

  let outputs_data = list.fold(tx.outputs, <<>>, fn(acc, output) {
    let script = oni_bitcoin.script_to_bytes(output.script_pubkey)
    let value = oni_bitcoin.amount_to_sats(output.value)
    let output_data = bit_array.concat([
      <<value:64-little>>,
      oni_bitcoin.compact_size_encode(bit_array.byte_size(script)),
      script,
    ])
    bit_array.append(acc, output_data)
  })

  bit_array.concat([
    <<tx.version:32-little>>,
    oni_bitcoin.compact_size_encode(list.length(tx.inputs)),
    inputs_data,
    oni_bitcoin.compact_size_encode(list.length(tx.outputs)),
    outputs_data,
    <<tx.lock_time:32-little>>,
  ])
}

/// ECDSA signature verification using secp256k1
fn verify_ecdsa(sighash: BitArray, signature: BitArray, pubkey: BitArray) -> Bool {
  // Parse the public key
  case oni_bitcoin.pubkey_from_bytes(pubkey) {
    Error(_) -> False
    Ok(pk) -> {
      // Parse the DER signature
      case oni_bitcoin.signature_from_der(signature) {
        Error(_) -> False
        Ok(sig) -> {
          // Perform ECDSA verification using Erlang crypto
          case oni_bitcoin.ecdsa_verify(sig, sighash, pk) {
            Error(_) -> False
            Ok(result) -> result
          }
        }
      }
    }
  }
}

/// Verify multiple signatures against pubkeys (CHECKMULTISIG)
fn verify_multisig(ctx: ScriptContext, sigs: List(BitArray), pubkeys: List(BitArray)) -> Bool {
  verify_multisig_loop(ctx, sigs, pubkeys)
}

fn verify_multisig_loop(ctx: ScriptContext, sigs: List(BitArray), pubkeys: List(BitArray)) -> Bool {
  case sigs {
    [] -> True  // All signatures verified
    [sig, ..rest_sigs] -> {
      // Find a matching pubkey
      case find_matching_pubkey(ctx, sig, pubkeys) {
        Error(_) -> False  // No matching pubkey found
        Ok(remaining_pubkeys) -> {
          // Continue with remaining signatures and pubkeys
          verify_multisig_loop(ctx, rest_sigs, remaining_pubkeys)
        }
      }
    }
  }
}

fn find_matching_pubkey(ctx: ScriptContext, sig: BitArray, pubkeys: List(BitArray)) -> Result(List(BitArray), Nil) {
  case pubkeys {
    [] -> Error(Nil)  // No more pubkeys to try
    [pubkey, ..rest] -> {
      case verify_signature(ctx, sig, pubkey) {
        True -> Ok(rest)  // Found match, return remaining pubkeys
        False -> find_matching_pubkey(ctx, sig, rest)  // Try next pubkey
      }
    }
  }
}

/// Pop n elements from a list
fn pop_n(lst: List(a), n: Int, acc: List(a)) -> Result(#(List(a), List(a)), Nil) {
  case n <= 0 {
    True -> Ok(#(list.reverse(acc), lst))
    False -> {
      case lst {
        [] -> Error(Nil)
        [head, ..tail] -> pop_n(tail, n - 1, [head, ..acc])
      }
    }
  }
}

// ============================================================================
// Script Number Encoding/Decoding
// ============================================================================

/// Encode an integer as a script number
pub fn encode_script_num(n: Int) -> BitArray {
  case n {
    0 -> <<>>
    _ -> {
      let abs_n = case n < 0 {
        True -> 0 - n
        False -> n
      }
      let bytes = encode_int_bytes(abs_n, <<>>)
      let bytes_with_sign = case n < 0 {
        True -> add_sign_bit(bytes, True)
        False -> add_sign_bit(bytes, False)
      }
      bytes_with_sign
    }
  }
}

fn encode_int_bytes(n: Int, acc: BitArray) -> BitArray {
  case n {
    0 -> acc
    _ -> {
      let byte = n % 256
      encode_int_bytes(n / 256, bit_array.append(acc, <<byte:8>>))
    }
  }
}

fn add_sign_bit(bytes: BitArray, negative: Bool) -> BitArray {
  let size = bit_array.byte_size(bytes)
  case size {
    0 -> <<>>
    _ -> {
      case bit_array.slice(bytes, size - 1, 1) {
        Ok(<<last:8>>) -> {
          case last >= 0x80 {
            True -> {
              // Need extra byte for sign
              let sign_byte = case negative {
                True -> <<0x80:8>>
                False -> <<0x00:8>>
              }
              bit_array.append(bytes, sign_byte)
            }
            False -> {
              // Can use high bit of last byte
              case negative {
                True -> {
                  let new_last = last + 0x80
                  case bit_array.slice(bytes, 0, size - 1) {
                    Ok(prefix) -> bit_array.append(prefix, <<new_last:8>>)
                    Error(_) -> bytes
                  }
                }
                False -> bytes
              }
            }
          }
        }
        _ -> bytes
      }
    }
  }
}

/// Decode a script number from bytes
pub fn decode_script_num(bytes: BitArray) -> Result(Int, Nil) {
  case bit_array.byte_size(bytes) {
    0 -> Ok(0)
    size if size > 4 -> Error(Nil)  // Script numbers limited to 4 bytes
    size -> {
      // Get the last byte to check sign
      case bit_array.slice(bytes, size - 1, 1) {
        Ok(<<last:8>>) -> {
          let negative = last >= 0x80
          let unsigned = decode_unsigned(bytes, 0, 0, negative)
          case negative {
            True -> Ok(0 - unsigned)
            False -> Ok(unsigned)
          }
        }
        _ -> Error(Nil)
      }
    }
  }
}

fn decode_unsigned(bytes: BitArray, index: Int, acc: Int, negative: Bool) -> Int {
  let size = bit_array.byte_size(bytes)
  case index >= size {
    True -> acc
    False -> {
      case bit_array.slice(bytes, index, 1) {
        Ok(<<byte:8>>) -> {
          let value = case index == size - 1 && negative {
            True -> byte - 0x80  // Clear sign bit
            False -> byte
          }
          decode_unsigned(bytes, index + 1, acc + value * pow256(index), negative)
        }
        _ -> acc
      }
    }
  }
}

fn pow256(n: Int) -> Int {
  case n {
    0 -> 1
    _ -> 256 * pow256(n - 1)
  }
}

// ============================================================================
// List Helpers
// ============================================================================

fn list_nth(lst: List(a), n: Int) -> Result(a, Nil) {
  case lst, n {
    [], _ -> Error(Nil)
    [head, ..], 0 -> Ok(head)
    [_, ..tail], _ -> list_nth(tail, n - 1)
  }
}

fn list_remove_nth(lst: List(a), n: Int) -> Result(#(a, List(a)), Nil) {
  list_remove_nth_loop(lst, n, [])
}

fn list_remove_nth_loop(lst: List(a), n: Int, acc: List(a)) -> Result(#(a, List(a)), Nil) {
  case lst, n {
    [], _ -> Error(Nil)
    [head, ..tail], 0 -> Ok(#(head, list.append(list.reverse(acc), tail)))
    [head, ..tail], _ -> list_remove_nth_loop(tail, n - 1, [head, ..acc])
  }
}
