// oni_bitcoin - Bitcoin primitives library for the oni Bitcoin node
//
// This module provides the core types and utilities for Bitcoin protocol
// implementation. It follows Bitcoin Core semantics for consensus-critical
// operations.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// ============================================================================
// Hash Types
// ============================================================================

/// A 256-bit hash value (32 bytes)
pub type Hash256 {
  Hash256(bytes: BitArray)
}

/// Transaction ID - double-SHA256 of the legacy transaction serialization
/// (excluding witness data for SegWit transactions)
pub type Txid {
  Txid(hash: Hash256)
}

/// Witness transaction ID - double-SHA256 of the full transaction
/// serialization including witness data
pub type Wtxid {
  Wtxid(hash: Hash256)
}

/// Block hash - double-SHA256 of the 80-byte block header
pub type BlockHash {
  BlockHash(hash: Hash256)
}

/// Create a Hash256 from raw bytes. Returns Error if not exactly 32 bytes.
pub fn hash256_from_bytes(bytes: BitArray) -> Result(Hash256, String) {
  case bit_array.byte_size(bytes) {
    32 -> Ok(Hash256(bytes))
    n -> Error("Expected 32 bytes, got " <> int.to_string(n))
  }
}

/// Create a Hash256 from a hex string (64 characters)
pub fn hash256_from_hex(hex: String) -> Result(Hash256, String) {
  case hex_decode(hex) {
    Ok(bytes) -> hash256_from_bytes(bytes)
    Error(e) -> Error(e)
  }
}

/// Convert Hash256 to hex string (internal byte order)
pub fn hash256_to_hex(hash: Hash256) -> String {
  hex_encode(hash.bytes)
}

/// Convert Hash256 to hex string in display order (reversed for txid/blockhash)
pub fn hash256_to_hex_display(hash: Hash256) -> String {
  hex_encode(reverse_bytes(hash.bytes))
}

/// Create a Txid from bytes (32 bytes, internal byte order)
pub fn txid_from_bytes(bytes: BitArray) -> Result(Txid, String) {
  hash256_from_bytes(bytes)
  |> result.map(Txid)
}

/// Create a Txid from hex (display order - reversed)
pub fn txid_from_hex(hex: String) -> Result(Txid, String) {
  case hex_decode(hex) {
    Ok(bytes) -> hash256_from_bytes(reverse_bytes(bytes)) |> result.map(Txid)
    Error(e) -> Error(e)
  }
}

/// Convert Txid to display hex (reversed byte order as shown in explorers)
pub fn txid_to_hex(txid: Txid) -> String {
  hash256_to_hex_display(txid.hash)
}

/// Create a BlockHash from bytes
pub fn block_hash_from_bytes(bytes: BitArray) -> Result(BlockHash, String) {
  hash256_from_bytes(bytes)
  |> result.map(BlockHash)
}

/// Create a BlockHash from hex (display order)
pub fn block_hash_from_hex(hex: String) -> Result(BlockHash, String) {
  case hex_decode(hex) {
    Ok(bytes) -> hash256_from_bytes(reverse_bytes(bytes)) |> result.map(BlockHash)
    Error(e) -> Error(e)
  }
}

/// Convert BlockHash to display hex
pub fn block_hash_to_hex(hash: BlockHash) -> String {
  hash256_to_hex_display(hash.hash)
}

// ============================================================================
// Amount Type
// ============================================================================

/// Amount in satoshis (1 BTC = 100,000,000 satoshis)
pub type Amount {
  Amount(sats: Int)
}

/// Maximum number of satoshis (21 million BTC)
pub const max_satoshis = 2_100_000_000_000_000

/// Create an Amount from satoshis. Returns Error if negative or exceeds max.
pub fn amount_from_sats(sats: Int) -> Result(Amount, String) {
  case sats {
    s if s < 0 -> Error("Amount cannot be negative")
    s if s > max_satoshis -> Error("Amount exceeds maximum supply")
    s -> Ok(Amount(s))
  }
}

/// Create an Amount from BTC (floating point approximation for convenience)
pub fn amount_from_btc(btc: Float) -> Result(Amount, String) {
  let sats = float_to_int(btc *. 100_000_000.0)
  amount_from_sats(sats)
}

/// Get satoshi value
pub fn amount_to_sats(amt: Amount) -> Int {
  amt.sats
}

/// Add two amounts safely
pub fn amount_add(a: Amount, b: Amount) -> Result(Amount, String) {
  amount_from_sats(a.sats + b.sats)
}

/// Subtract amounts (a - b). Returns Error if result would be negative.
pub fn amount_sub(a: Amount, b: Amount) -> Result(Amount, String) {
  amount_from_sats(a.sats - b.sats)
}

// ============================================================================
// Script Type
// ============================================================================

/// Bitcoin Script - a stack-based scripting language
pub type Script {
  Script(bytes: BitArray)
}

/// Create a Script from raw bytes
pub fn script_from_bytes(bytes: BitArray) -> Script {
  Script(bytes)
}

/// Get Script bytes
pub fn script_to_bytes(script: Script) -> BitArray {
  script.bytes
}

/// Check if script is empty
pub fn script_is_empty(script: Script) -> Bool {
  bit_array.byte_size(script.bytes) == 0
}

/// Get script size in bytes
pub fn script_size(script: Script) -> Int {
  bit_array.byte_size(script.bytes)
}

// ============================================================================
// OutPoint Type
// ============================================================================

/// Reference to a specific output of a previous transaction
pub type OutPoint {
  OutPoint(txid: Txid, vout: Int)
}

/// Create an OutPoint
pub fn outpoint_new(txid: Txid, vout: Int) -> OutPoint {
  OutPoint(txid, vout)
}

/// The null outpoint (used in coinbase transactions)
pub fn outpoint_null() -> OutPoint {
  let null_hash = Hash256(<<0:256>>)
  OutPoint(Txid(null_hash), 0xFFFFFFFF)
}

/// Check if this is a null outpoint
pub fn outpoint_is_null(op: OutPoint) -> Bool {
  op.vout == 0xFFFFFFFF
}

// ============================================================================
// Transaction Input
// ============================================================================

/// A transaction input spending a previous output
pub type TxIn {
  TxIn(
    prevout: OutPoint,
    script_sig: Script,
    sequence: Int,
    witness: List(BitArray),
  )
}

/// Create a TxIn
pub fn txin_new(
  prevout: OutPoint,
  script_sig: Script,
  sequence: Int,
) -> TxIn {
  TxIn(prevout, script_sig, sequence, [])
}

/// Default sequence value (final)
pub const sequence_final = 0xFFFFFFFF

/// Sequence value enabling RBF
pub const sequence_rbf_enabled = 0xFFFFFFFD

// ============================================================================
// Transaction Output
// ============================================================================

/// A transaction output
pub type TxOut {
  TxOut(value: Amount, script_pubkey: Script)
}

/// Create a TxOut
pub fn txout_new(value: Amount, script_pubkey: Script) -> TxOut {
  TxOut(value, script_pubkey)
}

// ============================================================================
// Transaction
// ============================================================================

/// A Bitcoin transaction
pub type Transaction {
  Transaction(
    version: Int,
    inputs: List(TxIn),
    outputs: List(TxOut),
    lock_time: Int,
  )
}

/// Create a new transaction
pub fn transaction_new(
  version: Int,
  inputs: List(TxIn),
  outputs: List(TxOut),
  lock_time: Int,
) -> Transaction {
  Transaction(version, inputs, outputs, lock_time)
}

/// Check if transaction has witness data
pub fn transaction_has_witness(tx: Transaction) -> Bool {
  list.any(tx.inputs, fn(input) { !list.is_empty(input.witness) })
}

// ============================================================================
// Block Header
// ============================================================================

/// Bitcoin block header (80 bytes)
pub type BlockHeader {
  BlockHeader(
    version: Int,
    prev_block: BlockHash,
    merkle_root: Hash256,
    timestamp: Int,
    bits: Int,
    nonce: Int,
  )
}

/// Create a block header
pub fn block_header_new(
  version: Int,
  prev_block: BlockHash,
  merkle_root: Hash256,
  timestamp: Int,
  bits: Int,
  nonce: Int,
) -> BlockHeader {
  BlockHeader(version, prev_block, merkle_root, timestamp, bits, nonce)
}

// ============================================================================
// Block
// ============================================================================

/// A Bitcoin block
pub type Block {
  Block(header: BlockHeader, transactions: List(Transaction))
}

/// Create a block
pub fn block_new(header: BlockHeader, transactions: List(Transaction)) -> Block {
  Block(header, transactions)
}

// ============================================================================
// Network Parameters
// ============================================================================

/// Network type
pub type Network {
  Mainnet
  Testnet
  Regtest
  Signet
}

/// Network parameters
pub type NetworkParams {
  NetworkParams(
    network: Network,
    p2pkh_prefix: Int,
    p2sh_prefix: Int,
    bech32_hrp: String,
    default_port: Int,
    genesis_hash: BlockHash,
  )
}

/// Mainnet parameters
pub fn mainnet_params() -> NetworkParams {
  let genesis_bytes = <<
    0x00, 0x00, 0x00, 0x00, 0x00, 0x19, 0xd6, 0x68,
    0x9c, 0x08, 0x5a, 0xe1, 0x65, 0x83, 0x1e, 0x93,
    0x4f, 0xf7, 0x63, 0xae, 0x46, 0xa2, 0xa6, 0xc1,
    0x72, 0xb3, 0xf1, 0xb6, 0x0a, 0x8c, 0xe2, 0x6f
  >>
  let assert Ok(genesis) = block_hash_from_bytes(genesis_bytes)

  NetworkParams(
    network: Mainnet,
    p2pkh_prefix: 0x00,
    p2sh_prefix: 0x05,
    bech32_hrp: "bc",
    default_port: 8333,
    genesis_hash: genesis,
  )
}

/// Testnet parameters
pub fn testnet_params() -> NetworkParams {
  let genesis_bytes = <<
    0x00, 0x00, 0x00, 0x00, 0x09, 0x33, 0xea, 0x01,
    0xad, 0x0e, 0xe9, 0x84, 0x20, 0x97, 0x79, 0xba,
    0xae, 0xc3, 0xce, 0xd9, 0x0f, 0xa3, 0xf4, 0x08,
    0x71, 0x95, 0x26, 0xf8, 0xd7, 0x7f, 0x49, 0x43
  >>
  let assert Ok(genesis) = block_hash_from_bytes(genesis_bytes)

  NetworkParams(
    network: Testnet,
    p2pkh_prefix: 0x6F,
    p2sh_prefix: 0xC4,
    bech32_hrp: "tb",
    default_port: 18333,
    genesis_hash: genesis,
  )
}

/// Regtest parameters
pub fn regtest_params() -> NetworkParams {
  let genesis_bytes = <<
    0x0f, 0x9e, 0x8e, 0x7f, 0xfd, 0x13, 0x18, 0x8e,
    0x49, 0x77, 0x5b, 0x9b, 0x02, 0x13, 0xe9, 0x0f,
    0x94, 0x03, 0x68, 0x9e, 0x2c, 0x3b, 0x3f, 0x4d,
    0x56, 0x61, 0x1e, 0xac, 0x25, 0x29, 0x3f, 0x06
  >>
  let assert Ok(genesis) = block_hash_from_bytes(genesis_bytes)

  NetworkParams(
    network: Regtest,
    p2pkh_prefix: 0x6F,
    p2sh_prefix: 0xC4,
    bech32_hrp: "bcrt",
    default_port: 18444,
    genesis_hash: genesis,
  )
}

// ============================================================================
// Hex Encoding/Decoding
// ============================================================================

/// Encode bytes to hex string
pub fn hex_encode(bytes: BitArray) -> String {
  bytes
  |> bit_array.to_string
  |> result.unwrap("")
  |> do_hex_encode(bytes, "")
}

fn do_hex_encode(_str: String, bytes: BitArray, acc: String) -> String {
  case bytes {
    <<b:8, rest:bits>> -> {
      let hi = int.to_base16(b / 16)
      let lo = int.to_base16(b % 16)
      do_hex_encode("", rest, acc <> string.lowercase(hi) <> string.lowercase(lo))
    }
    _ -> acc
  }
}

/// Decode hex string to bytes
pub fn hex_decode(hex: String) -> Result(BitArray, String) {
  case string.length(hex) % 2 {
    0 -> do_hex_decode(hex, <<>>)
    _ -> Error("Hex string must have even length")
  }
}

fn do_hex_decode(hex: String, acc: BitArray) -> Result(BitArray, String) {
  case string.pop_grapheme(hex) {
    Error(_) -> Ok(acc)
    Ok(#(hi, rest)) -> {
      case string.pop_grapheme(rest) {
        Error(_) -> Error("Unexpected end of hex string")
        Ok(#(lo, rest2)) -> {
          case hex_char_to_int(hi), hex_char_to_int(lo) {
            Ok(h), Ok(l) -> {
              let byte = h * 16 + l
              do_hex_decode(rest2, bit_array.append(acc, <<byte:8>>))
            }
            _, _ -> Error("Invalid hex character")
          }
        }
      }
    }
  }
}

fn hex_char_to_int(c: String) -> Result(Int, String) {
  case c {
    "0" -> Ok(0)
    "1" -> Ok(1)
    "2" -> Ok(2)
    "3" -> Ok(3)
    "4" -> Ok(4)
    "5" -> Ok(5)
    "6" -> Ok(6)
    "7" -> Ok(7)
    "8" -> Ok(8)
    "9" -> Ok(9)
    "a" | "A" -> Ok(10)
    "b" | "B" -> Ok(11)
    "c" | "C" -> Ok(12)
    "d" | "D" -> Ok(13)
    "e" | "E" -> Ok(14)
    "f" | "F" -> Ok(15)
    _ -> Error("Invalid hex character: " <> c)
  }
}

// ============================================================================
// Byte Utilities
// ============================================================================

/// Reverse byte order of a BitArray
pub fn reverse_bytes(bytes: BitArray) -> BitArray {
  do_reverse_bytes(bytes, <<>>)
}

fn do_reverse_bytes(bytes: BitArray, acc: BitArray) -> BitArray {
  case bytes {
    <<b:8, rest:bits>> -> do_reverse_bytes(rest, <<b:8, acc:bits>>)
    _ -> acc
  }
}

// ============================================================================
// CompactSize (Variable-length integer encoding)
// ============================================================================

/// Encode an integer as CompactSize
pub fn compact_size_encode(n: Int) -> BitArray {
  case n {
    _ if n < 0 -> <<>>
    _ if n < 0xFD -> <<n:8>>
    _ if n <= 0xFFFF -> <<0xFD:8, n:16-little>>
    _ if n <= 0xFFFFFFFF -> <<0xFE:8, n:32-little>>
    _ -> <<0xFF:8, n:64-little>>
  }
}

/// Decode a CompactSize from bytes. Returns (value, remaining_bytes) or Error.
pub fn compact_size_decode(bytes: BitArray) -> Result(#(Int, BitArray), String) {
  case bytes {
    <<0xFF:8, n:64-little, rest:bits>> -> Ok(#(n, rest))
    <<0xFE:8, n:32-little, rest:bits>> -> Ok(#(n, rest))
    <<0xFD:8, n:16-little, rest:bits>> -> Ok(#(n, rest))
    <<n:8, rest:bits>> -> Ok(#(n, rest))
    _ -> Error("Insufficient bytes for CompactSize")
  }
}

// ============================================================================
// Cryptographic Hash Functions
// ============================================================================

/// SHA256 hash
pub fn sha256(data: BitArray) -> BitArray {
  crypto.hash(crypto.Sha256, data)
}

/// Double SHA256 (SHA256d) - used extensively in Bitcoin
pub fn sha256d(data: BitArray) -> BitArray {
  sha256(sha256(data))
}

/// RIPEMD160 hash - uses Erlang's crypto module directly
pub fn ripemd160(data: BitArray) -> BitArray {
  erlang_ripemd160(data)
}

/// Erlang FFI for RIPEMD160
@external(erlang, "crypto", "hash")
fn erlang_ripemd160_raw(algo: ErlangAtom, data: BitArray) -> BitArray

/// Helper to call Erlang crypto:hash(ripemd160, data)
fn erlang_ripemd160(data: BitArray) -> BitArray {
  erlang_ripemd160_raw(ripemd160_atom(), data)
}

/// Get the ripemd160 atom
@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: BitArray) -> ErlangAtom

type ErlangAtom

fn ripemd160_atom() -> ErlangAtom {
  binary_to_atom(<<"ripemd160":utf8>>)
}

/// HASH160 = RIPEMD160(SHA256(data)) - used for addresses
pub fn hash160(data: BitArray) -> BitArray {
  ripemd160(sha256(data))
}

/// Compute double-SHA256 hash and return as Hash256
pub fn hash256_digest(data: BitArray) -> Hash256 {
  Hash256(sha256d(data))
}

/// Tagged hash as used in BIP-340 (Taproot)
pub fn tagged_hash(tag: String, data: BitArray) -> BitArray {
  let tag_bytes = bit_array.from_string(tag)
  let tag_hash = sha256(tag_bytes)
  sha256(bit_array.concat([tag_hash, tag_hash, data]))
}

// ============================================================================
// Public Key Types
// ============================================================================

/// Cryptographic errors
pub type CryptoError {
  InvalidPublicKey
  InvalidSignature
  InvalidMessage
  VerificationFailed
  UnsupportedOperation
}

/// Compressed or uncompressed secp256k1 public key
pub type PubKey {
  /// Compressed public key (33 bytes: 0x02 or 0x03 prefix + 32 byte X coordinate)
  CompressedPubKey(bytes: BitArray)
  /// Uncompressed public key (65 bytes: 0x04 prefix + 32 byte X + 32 byte Y)
  UncompressedPubKey(bytes: BitArray)
}

/// X-only public key for Taproot (BIP-340) - 32 bytes
pub type XOnlyPubKey {
  XOnlyPubKey(bytes: BitArray)
}

/// Parse a public key from bytes
pub fn pubkey_from_bytes(bytes: BitArray) -> Result(PubKey, CryptoError) {
  case bytes {
    // Compressed with even Y (33 bytes: 0x02 + 32 bytes)
    <<0x02:8, _x:256-bits>> ->
      Ok(CompressedPubKey(bytes))
    // Compressed with odd Y (33 bytes: 0x03 + 32 bytes)
    <<0x03:8, _x:256-bits>> ->
      Ok(CompressedPubKey(bytes))
    // Uncompressed (65 bytes: 0x04 + 64 bytes)
    <<0x04:8, _xy:512-bits>> ->
      Ok(UncompressedPubKey(bytes))
    _ -> Error(InvalidPublicKey)
  }
}

/// Parse an x-only public key from bytes (32 bytes)
pub fn xonly_pubkey_from_bytes(bytes: BitArray) -> Result(XOnlyPubKey, CryptoError) {
  case bit_array.byte_size(bytes) {
    32 -> Ok(XOnlyPubKey(bytes))
    _ -> Error(InvalidPublicKey)
  }
}

/// Convert a compressed public key to x-only (strip the prefix byte)
pub fn pubkey_to_xonly(pubkey: PubKey) -> Result(XOnlyPubKey, CryptoError) {
  case pubkey {
    CompressedPubKey(bytes) -> {
      case bytes {
        <<_prefix:8, x:256-bits>> -> Ok(XOnlyPubKey(x))
        _ -> Error(InvalidPublicKey)
      }
    }
    UncompressedPubKey(_) -> Error(UnsupportedOperation)
  }
}

/// Get the raw bytes of a public key
pub fn pubkey_to_bytes(pubkey: PubKey) -> BitArray {
  case pubkey {
    CompressedPubKey(bytes) -> bytes
    UncompressedPubKey(bytes) -> bytes
  }
}

/// Check if a public key is compressed
pub fn pubkey_is_compressed(pubkey: PubKey) -> Bool {
  case pubkey {
    CompressedPubKey(_) -> True
    UncompressedPubKey(_) -> False
  }
}

// ============================================================================
// Signature Types
// ============================================================================

/// DER-encoded ECDSA signature (variable length, typically 70-72 bytes)
pub type Signature {
  Signature(der: BitArray)
}

/// BIP-340 Schnorr signature (exactly 64 bytes)
pub type SchnorrSig {
  SchnorrSig(bytes: BitArray)
}

/// Parse an ECDSA signature from DER bytes
pub fn signature_from_der(der: BitArray) -> Result(Signature, CryptoError) {
  // Basic DER validation: must start with 0x30 (SEQUENCE)
  case der {
    <<0x30:8, len:8, rest:bits>> -> {
      case bit_array.byte_size(rest) == len {
        True -> Ok(Signature(der))
        False -> Error(InvalidSignature)
      }
    }
    _ -> Error(InvalidSignature)
  }
}

/// Parse a Schnorr signature from bytes (64 bytes)
pub fn schnorr_sig_from_bytes(bytes: BitArray) -> Result(SchnorrSig, CryptoError) {
  case bit_array.byte_size(bytes) {
    64 -> Ok(SchnorrSig(bytes))
    _ -> Error(InvalidSignature)
  }
}

/// Get the raw DER bytes of an ECDSA signature
pub fn signature_to_der(sig: Signature) -> BitArray {
  sig.der
}

/// Get the raw bytes of a Schnorr signature
pub fn schnorr_sig_to_bytes(sig: SchnorrSig) -> BitArray {
  sig.bytes
}

// ============================================================================
// Signature Verification
// ============================================================================

/// Verify an ECDSA signature against a message hash and public key
/// Note: This uses Erlang's crypto module for secp256k1 ECDSA verification
pub fn ecdsa_verify(
  sig: Signature,
  msg_hash: BitArray,
  pubkey: PubKey,
) -> Result(Bool, CryptoError) {
  case bit_array.byte_size(msg_hash) {
    32 -> {
      let pubkey_bytes = pubkey_to_bytes(pubkey)
      let result = erlang_ecdsa_verify(sig.der, msg_hash, pubkey_bytes)
      Ok(result)
    }
    _ -> Error(InvalidMessage)
  }
}

/// Verify a BIP-340 Schnorr signature
/// Note: Erlang's crypto doesn't support BIP-340 Schnorr directly.
/// This is a placeholder that will need NIF integration for production use.
pub fn schnorr_verify(
  sig: SchnorrSig,
  msg_hash: BitArray,
  pubkey: XOnlyPubKey,
) -> Result(Bool, CryptoError) {
  case bit_array.byte_size(msg_hash) {
    32 -> {
      // BIP-340 Schnorr verification requires special handling.
      // For now, we validate inputs but return an error indicating
      // that a NIF implementation is needed for actual verification.
      let _ = sig
      let _ = pubkey
      Error(UnsupportedOperation)
    }
    _ -> Error(InvalidMessage)
  }
}

/// Erlang FFI for ECDSA verification on secp256k1
fn erlang_ecdsa_verify(
  signature: BitArray,
  message: BitArray,
  pubkey: BitArray,
) -> Bool {
  // Call Erlang's crypto:verify/5
  erlang_crypto_verify(
    ecdsa_atom(),
    sha256_atom(),
    message,
    signature,
    #(pubkey, secp256k1_atom()),
  )
}

@external(erlang, "crypto", "verify")
fn erlang_crypto_verify(
  algo: ErlangAtom,
  hash_algo: ErlangAtom,
  message: BitArray,
  signature: BitArray,
  key: #(BitArray, ErlangAtom),
) -> Bool

fn ecdsa_atom() -> ErlangAtom {
  binary_to_atom(<<"ecdsa":utf8>>)
}

fn sha256_atom() -> ErlangAtom {
  binary_to_atom(<<"sha256":utf8>>)
}

fn secp256k1_atom() -> ErlangAtom {
  binary_to_atom(<<"secp256k1":utf8>>)
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert float to int (truncates)
fn float_to_int(f: Float) -> Int {
  case f <. 0.0 {
    True -> 0 - float_to_int(0.0 -. f)
    False -> do_float_to_int(f, 0)
  }
}

fn do_float_to_int(f: Float, acc: Int) -> Int {
  case f <. 1.0 {
    True -> acc
    False -> do_float_to_int(f -. 1.0, acc + 1)
  }
}

// ============================================================================
// Transaction Serialization
// ============================================================================

/// Encode a transaction to bytes (without witness data for legacy txid)
pub fn encode_tx_legacy(tx: Transaction) -> BitArray {
  let inputs_data = encode_inputs(tx.inputs)
  let outputs_data = encode_outputs(tx.outputs)

  bit_array.concat([
    <<tx.version:32-little>>,
    compact_size_encode(list.length(tx.inputs)),
    inputs_data,
    compact_size_encode(list.length(tx.outputs)),
    outputs_data,
    <<tx.lock_time:32-little>>,
  ])
}

/// Encode a transaction with witness data (full SegWit serialization)
pub fn encode_tx(tx: Transaction) -> BitArray {
  let has_witness = transaction_has_witness(tx)

  case has_witness {
    False -> encode_tx_legacy(tx)
    True -> {
      let inputs_data = encode_inputs(tx.inputs)
      let outputs_data = encode_outputs(tx.outputs)
      let witness_data = encode_witnesses(tx.inputs)

      bit_array.concat([
        <<tx.version:32-little>>,
        <<0x00:8, 0x01:8>>,  // SegWit marker and flag
        compact_size_encode(list.length(tx.inputs)),
        inputs_data,
        compact_size_encode(list.length(tx.outputs)),
        outputs_data,
        witness_data,
        <<tx.lock_time:32-little>>,
      ])
    }
  }
}

fn encode_inputs(inputs: List(TxIn)) -> BitArray {
  list.fold(inputs, <<>>, fn(acc, input) {
    let script = script_to_bytes(input.script_sig)
    let script_len = compact_size_encode(bit_array.byte_size(script))
    let input_data = bit_array.concat([
      input.prevout.txid.hash.bytes,
      <<input.prevout.vout:32-little>>,
      script_len,
      script,
      <<input.sequence:32-little>>,
    ])
    bit_array.append(acc, input_data)
  })
}

fn encode_outputs(outputs: List(TxOut)) -> BitArray {
  list.fold(outputs, <<>>, fn(acc, output) {
    let script = script_to_bytes(output.script_pubkey)
    let script_len = compact_size_encode(bit_array.byte_size(script))
    let value = amount_to_sats(output.value)
    let output_data = bit_array.concat([
      <<value:64-little>>,
      script_len,
      script,
    ])
    bit_array.append(acc, output_data)
  })
}

fn encode_witnesses(inputs: List(TxIn)) -> BitArray {
  list.fold(inputs, <<>>, fn(acc, input) {
    let witness = input.witness
    let count = compact_size_encode(list.length(witness))
    let witness_data = list.fold(witness, <<>>, fn(wacc, item) {
      let item_len = compact_size_encode(bit_array.byte_size(item))
      bit_array.concat([wacc, item_len, item])
    })
    bit_array.concat([acc, count, witness_data])
  })
}

/// Decode a transaction from bytes
/// Returns the transaction and remaining bytes
pub fn decode_tx(bytes: BitArray) -> Result(#(Transaction, BitArray), String) {
  case bytes {
    <<version:32-little, rest:bits>> -> {
      // Check for SegWit marker
      case rest {
        <<0x00:8, 0x01:8, after_marker:bits>> -> {
          // SegWit transaction
          decode_tx_segwit(version, after_marker)
        }
        _ -> {
          // Legacy transaction
          decode_tx_legacy(version, rest)
        }
      }
    }
    _ -> Error("Insufficient bytes for transaction")
  }
}

fn decode_tx_legacy(version: Int, bytes: BitArray) -> Result(#(Transaction, BitArray), String) {
  // Decode inputs
  case compact_size_decode(bytes) {
    Error(e) -> Error(e)
    Ok(#(input_count, after_count)) -> {
      case decode_inputs(after_count, input_count, []) {
        Error(e) -> Error(e)
        Ok(#(inputs, after_inputs)) -> {
          // Decode outputs
          case compact_size_decode(after_inputs) {
            Error(e) -> Error(e)
            Ok(#(output_count, after_out_count)) -> {
              case decode_outputs(after_out_count, output_count, []) {
                Error(e) -> Error(e)
                Ok(#(outputs, after_outputs)) -> {
                  // Decode locktime
                  case after_outputs {
                    <<lock_time:32-little, remaining:bits>> -> {
                      let tx = Transaction(
                        version: version,
                        inputs: inputs,
                        outputs: outputs,
                        lock_time: lock_time,
                      )
                      Ok(#(tx, remaining))
                    }
                    _ -> Error("Insufficient bytes for locktime")
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

fn decode_tx_segwit(version: Int, bytes: BitArray) -> Result(#(Transaction, BitArray), String) {
  // Decode inputs
  case compact_size_decode(bytes) {
    Error(e) -> Error(e)
    Ok(#(input_count, after_count)) -> {
      case decode_inputs(after_count, input_count, []) {
        Error(e) -> Error(e)
        Ok(#(inputs, after_inputs)) -> {
          // Decode outputs
          case compact_size_decode(after_inputs) {
            Error(e) -> Error(e)
            Ok(#(output_count, after_out_count)) -> {
              case decode_outputs(after_out_count, output_count, []) {
                Error(e) -> Error(e)
                Ok(#(outputs, after_outputs)) -> {
                  // Decode witnesses (one per input)
                  case decode_all_witnesses(after_outputs, input_count, []) {
                    Error(e) -> Error(e)
                    Ok(#(witnesses, after_witnesses)) -> {
                      // Decode locktime
                      case after_witnesses {
                        <<lock_time:32-little, remaining:bits>> -> {
                          // Attach witnesses to inputs
                          let inputs_with_witness = attach_witnesses(inputs, witnesses)
                          let tx = Transaction(
                            version: version,
                            inputs: inputs_with_witness,
                            outputs: outputs,
                            lock_time: lock_time,
                          )
                          Ok(#(tx, remaining))
                        }
                        _ -> Error("Insufficient bytes for locktime")
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

fn decode_inputs(bytes: BitArray, count: Int, acc: List(TxIn)) -> Result(#(List(TxIn), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case decode_input(bytes) {
        Error(e) -> Error(e)
        Ok(#(input, rest)) -> decode_inputs(rest, count - 1, [input, ..acc])
      }
    }
  }
}

fn decode_input(bytes: BitArray) -> Result(#(TxIn, BitArray), String) {
  case bytes {
    <<txid_bytes:256-bits, vout:32-little, rest:bits>> -> {
      case compact_size_decode(rest) {
        Error(e) -> Error(e)
        Ok(#(script_len, after_len)) -> {
          case bit_array.slice(after_len, 0, script_len) {
            Error(_) -> Error("Insufficient bytes for script_sig")
            Ok(script_bytes) -> {
              let remaining_size = bit_array.byte_size(after_len) - script_len
              case bit_array.slice(after_len, script_len, remaining_size) {
                Error(_) -> Error("Invalid slice for remaining")
                Ok(after_script) -> {
                  case after_script {
                    <<sequence:32-little, remaining:bits>> -> {
                      let txid = Txid(Hash256(<<txid_bytes:256-bits>>))
                      let prevout = OutPoint(txid, vout)
                      let script_sig = Script(script_bytes)
                      let input = TxIn(prevout, script_sig, sequence, [])
                      Ok(#(input, remaining))
                    }
                    _ -> Error("Insufficient bytes for sequence")
                  }
                }
              }
            }
          }
        }
      }
    }
    _ -> Error("Insufficient bytes for input")
  }
}

fn decode_outputs(bytes: BitArray, count: Int, acc: List(TxOut)) -> Result(#(List(TxOut), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case decode_output(bytes) {
        Error(e) -> Error(e)
        Ok(#(output, rest)) -> decode_outputs(rest, count - 1, [output, ..acc])
      }
    }
  }
}

fn decode_output(bytes: BitArray) -> Result(#(TxOut, BitArray), String) {
  case bytes {
    <<value:64-little, rest:bits>> -> {
      case compact_size_decode(rest) {
        Error(e) -> Error(e)
        Ok(#(script_len, after_len)) -> {
          case bit_array.slice(after_len, 0, script_len) {
            Error(_) -> Error("Insufficient bytes for script_pubkey")
            Ok(script_bytes) -> {
              let remaining_size = bit_array.byte_size(after_len) - script_len
              case bit_array.slice(after_len, script_len, remaining_size) {
                Error(_) -> {
                  // No remaining bytes, which is fine
                  case amount_from_sats(value) {
                    Error(e) -> Error(e)
                    Ok(amount) -> {
                      let script_pubkey = Script(script_bytes)
                      let output = TxOut(amount, script_pubkey)
                      Ok(#(output, <<>>))
                    }
                  }
                }
                Ok(remaining) -> {
                  case amount_from_sats(value) {
                    Error(e) -> Error(e)
                    Ok(amount) -> {
                      let script_pubkey = Script(script_bytes)
                      let output = TxOut(amount, script_pubkey)
                      Ok(#(output, remaining))
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    _ -> Error("Insufficient bytes for output value")
  }
}

fn decode_all_witnesses(bytes: BitArray, count: Int, acc: List(List(BitArray))) -> Result(#(List(List(BitArray)), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case decode_witness(bytes) {
        Error(e) -> Error(e)
        Ok(#(witness, rest)) -> decode_all_witnesses(rest, count - 1, [witness, ..acc])
      }
    }
  }
}

fn decode_witness(bytes: BitArray) -> Result(#(List(BitArray), BitArray), String) {
  case compact_size_decode(bytes) {
    Error(e) -> Error(e)
    Ok(#(stack_count, after_count)) -> {
      decode_witness_stack(after_count, stack_count, [])
    }
  }
}

fn decode_witness_stack(bytes: BitArray, count: Int, acc: List(BitArray)) -> Result(#(List(BitArray), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case compact_size_decode(bytes) {
        Error(e) -> Error(e)
        Ok(#(item_len, after_len)) -> {
          case bit_array.slice(after_len, 0, item_len) {
            Error(_) -> Error("Insufficient bytes for witness item")
            Ok(item) -> {
              let remaining_size = bit_array.byte_size(after_len) - item_len
              case bit_array.slice(after_len, item_len, remaining_size) {
                Error(_) -> decode_witness_stack(<<>>, count - 1, [item, ..acc])
                Ok(remaining) -> decode_witness_stack(remaining, count - 1, [item, ..acc])
              }
            }
          }
        }
      }
    }
  }
}

fn attach_witnesses(inputs: List(TxIn), witnesses: List(List(BitArray))) -> List(TxIn) {
  case inputs, witnesses {
    [], _ -> []
    [input, ..rest_inputs], [witness, ..rest_witnesses] -> {
      let updated_input = TxIn(..input, witness: witness)
      [updated_input, ..attach_witnesses(rest_inputs, rest_witnesses)]
    }
    [input, ..rest_inputs], [] -> {
      [input, ..attach_witnesses(rest_inputs, [])]
    }
  }
}

/// Compute the transaction ID (txid) from a transaction
/// The txid is the double-SHA256 of the legacy serialization (without witness)
pub fn txid_from_tx(tx: Transaction) -> Txid {
  let serialized = encode_tx_legacy(tx)
  let hash = hash256_digest(serialized)
  Txid(hash)
}

/// Compute the witness transaction ID (wtxid) from a transaction
/// The wtxid is the double-SHA256 of the full serialization (with witness)
pub fn wtxid_from_tx(tx: Transaction) -> Wtxid {
  let serialized = encode_tx(tx)
  let hash = hash256_digest(serialized)
  Wtxid(hash)
}

/// Get transaction size in bytes (legacy serialization)
pub fn tx_size(tx: Transaction) -> Int {
  bit_array.byte_size(encode_tx_legacy(tx))
}

/// Get transaction virtual size (vsize) in virtual bytes
/// vsize = (weight + 3) / 4
pub fn tx_vsize(tx: Transaction) -> Int {
  let weight = tx_weight(tx)
  { weight + 3 } / 4
}

/// Get transaction weight in weight units
/// weight = base_size * 3 + total_size
pub fn tx_weight(tx: Transaction) -> Int {
  let base_size = bit_array.byte_size(encode_tx_legacy(tx))
  let total_size = bit_array.byte_size(encode_tx(tx))
  base_size * 3 + total_size
}

// ============================================================================
// Base58 Encoding/Decoding
// ============================================================================

/// Base58 alphabet (Bitcoin variant - no 0, O, I, l)
const base58_alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

/// Encode bytes to Base58 string
pub fn base58_encode(bytes: BitArray) -> String {
  // Count leading zeros
  let leading_zeros = count_leading_zeros(bytes, 0)

  // Convert to a big integer
  let num = bytes_to_bigint(bytes, 0)

  // Convert to base58
  let base58_chars = bigint_to_base58(num, "")

  // Add leading '1's for each leading zero byte
  let leading_ones = string.repeat("1", leading_zeros)
  leading_ones <> base58_chars
}

fn count_leading_zeros(bytes: BitArray, count: Int) -> Int {
  case bytes {
    <<0:8, rest:bits>> -> count_leading_zeros(rest, count + 1)
    _ -> count
  }
}

fn bytes_to_bigint(bytes: BitArray, acc: Int) -> Int {
  case bytes {
    <<b:8, rest:bits>> -> bytes_to_bigint(rest, acc * 256 + b)
    _ -> acc
  }
}

fn bigint_to_base58(num: Int, acc: String) -> String {
  case num {
    0 -> acc
    _ -> {
      let remainder = num % 58
      let quotient = num / 58
      let char = string_char_at(base58_alphabet, remainder)
      bigint_to_base58(quotient, char <> acc)
    }
  }
}

fn string_char_at(s: String, idx: Int) -> String {
  case string.drop_start(s, idx) {
    "" -> ""
    rest -> {
      case string.pop_grapheme(rest) {
        Ok(#(c, _)) -> c
        Error(_) -> ""
      }
    }
  }
}

/// Decode Base58 string to bytes
pub fn base58_decode(input: String) -> Result(BitArray, String) {
  // Count leading '1's (they become leading zero bytes)
  let leading_ones = count_leading_char(input, "1", 0)

  // Convert to a big integer
  case base58_to_bigint(input, 0) {
    Error(e) -> Error(e)
    Ok(num) -> {
      // Convert to bytes
      let bytes = bigint_to_bytes(num, <<>>)
      // Prepend leading zeros
      let leading_zeros = create_zero_bytes_n(leading_ones, <<>>)
      Ok(bit_array.append(leading_zeros, bytes))
    }
  }
}

fn count_leading_char(s: String, c: String, count: Int) -> Int {
  case string.pop_grapheme(s) {
    Ok(#(first, rest)) -> {
      case first == c {
        True -> count_leading_char(rest, c, count + 1)
        False -> count
      }
    }
    Error(_) -> count
  }
}

fn base58_to_bigint(s: String, acc: Int) -> Result(Int, String) {
  case string.pop_grapheme(s) {
    Error(_) -> Ok(acc)
    Ok(#(c, rest)) -> {
      case base58_char_value(c) {
        Error(e) -> Error(e)
        Ok(val) -> base58_to_bigint(rest, acc * 58 + val)
      }
    }
  }
}

fn base58_char_value(c: String) -> Result(Int, String) {
  case string.contains(base58_alphabet, c) {
    False -> Error("Invalid Base58 character: " <> c)
    True -> find_char_index(base58_alphabet, c, 0)
  }
}

fn find_char_index(s: String, target: String, idx: Int) -> Result(Int, String) {
  case string.pop_grapheme(s) {
    Error(_) -> Error("Character not found")
    Ok(#(c, rest)) -> {
      case c == target {
        True -> Ok(idx)
        False -> find_char_index(rest, target, idx + 1)
      }
    }
  }
}

fn bigint_to_bytes(num: Int, acc: BitArray) -> BitArray {
  case num {
    0 -> acc
    _ -> {
      let byte = num % 256
      let quotient = num / 256
      bigint_to_bytes(quotient, <<byte:8, acc:bits>>)
    }
  }
}

fn create_zero_bytes_n(n: Int, acc: BitArray) -> BitArray {
  case n {
    0 -> acc
    _ -> create_zero_bytes_n(n - 1, bit_array.append(acc, <<0:8>>))
  }
}

// ============================================================================
// Base58Check Encoding/Decoding
// ============================================================================

/// Encode bytes with Base58Check (adds 4-byte checksum)
pub fn base58check_encode(payload: BitArray) -> String {
  let checksum = compute_checksum(payload)
  let with_checksum = bit_array.append(payload, checksum)
  base58_encode(with_checksum)
}

/// Decode Base58Check string to bytes (verifies and removes checksum)
pub fn base58check_decode(input: String) -> Result(BitArray, String) {
  case base58_decode(input) {
    Error(e) -> Error(e)
    Ok(decoded) -> {
      let size = bit_array.byte_size(decoded)
      case size < 5 {
        True -> Error("Base58Check data too short")
        False -> {
          // Split payload and checksum
          case bit_array.slice(decoded, 0, size - 4) {
            Error(_) -> Error("Failed to extract payload")
            Ok(payload) -> {
              case bit_array.slice(decoded, size - 4, 4) {
                Error(_) -> Error("Failed to extract checksum")
                Ok(checksum) -> {
                  // Verify checksum
                  let expected = compute_checksum(payload)
                  case checksum == expected {
                    True -> Ok(payload)
                    False -> Error("Invalid checksum")
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

fn compute_checksum(data: BitArray) -> BitArray {
  let hash = sha256d(data)
  case bit_array.slice(hash, 0, 4) {
    Ok(cs) -> cs
    Error(_) -> <<0, 0, 0, 0>>
  }
}

// ============================================================================
// Bech32 Encoding/Decoding
// ============================================================================

/// Bech32 alphabet
const bech32_alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

/// Bech32 generator polynomial
const bech32_gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

/// Bech32 encoding variant
pub type Bech32Variant {
  Bech32   // Original BIP173 (for SegWit v0)
  Bech32m  // BIP350 (for SegWit v1+, Taproot)
}

/// Encode data as Bech32/Bech32m
pub fn bech32_encode(hrp: String, data: List(Int), variant: Bech32Variant) -> String {
  // Expand HRP for checksum
  let hrp_expanded = bech32_hrp_expand(hrp)

  // Compute checksum
  let values = list.append(hrp_expanded, data)
  let checksum = bech32_create_checksum(values, variant)

  // Encode data and checksum
  let data_with_checksum = list.append(data, checksum)
  let encoded = list.fold(data_with_checksum, "", fn(acc, val) {
    acc <> string_char_at(bech32_alphabet, val)
  })

  hrp <> "1" <> encoded
}

/// Decode a Bech32/Bech32m string
pub fn bech32_decode(input: String) -> Result(#(String, List(Int), Bech32Variant), String) {
  // Check for mixed case
  let lower = string.lowercase(input)
  let upper = string.uppercase(input)
  case input != lower && input != upper {
    True -> Error("Mixed case not allowed")
    False -> {
      let normalized = lower

      // Find separator
      case find_last_char(normalized, "1", 0, -1) {
        -1 -> Error("No separator found")
        sep_pos -> {
          case sep_pos < 1 || sep_pos + 7 > string.length(normalized) {
            True -> Error("Invalid separator position")
            False -> {
              let hrp = string.slice(normalized, 0, sep_pos)
              let data_part = string.drop_start(normalized, sep_pos + 1)

              // Decode data characters
              case decode_bech32_data(data_part, []) {
                Error(e) -> Error(e)
                Ok(data) -> {
                  // Verify checksum
                  let hrp_expanded = bech32_hrp_expand(hrp)
                  let values = list.append(hrp_expanded, data)
                  let polymod = bech32_polymod(values)

                  case polymod {
                    1 -> {
                      // Bech32
                      let payload = list.take(data, list.length(data) - 6)
                      Ok(#(hrp, payload, Bech32))
                    }
                    0x2bc830a3 -> {
                      // Bech32m
                      let payload = list.take(data, list.length(data) - 6)
                      Ok(#(hrp, payload, Bech32m))
                    }
                    _ -> Error("Invalid checksum")
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

fn find_last_char(s: String, target: String, idx: Int, last: Int) -> Int {
  case string.pop_grapheme(s) {
    Error(_) -> last
    Ok(#(c, rest)) -> {
      case c == target {
        True -> find_last_char(rest, target, idx + 1, idx)
        False -> find_last_char(rest, target, idx + 1, last)
      }
    }
  }
}

fn decode_bech32_data(s: String, acc: List(Int)) -> Result(List(Int), String) {
  case string.pop_grapheme(s) {
    Error(_) -> Ok(list.reverse(acc))
    Ok(#(c, rest)) -> {
      case bech32_char_value(c) {
        Error(e) -> Error(e)
        Ok(val) -> decode_bech32_data(rest, [val, ..acc])
      }
    }
  }
}

fn bech32_char_value(c: String) -> Result(Int, String) {
  find_char_index(bech32_alphabet, c, 0)
}

fn bech32_hrp_expand(hrp: String) -> List(Int) {
  let high = string_to_chars(hrp)
    |> list.map(fn(c) { char_code(c) / 32 })
  let low = string_to_chars(hrp)
    |> list.map(fn(c) { int.bitwise_and(char_code(c), 31) })
  list.flatten([high, [0], low])
}

fn string_to_chars(s: String) -> List(String) {
  string_to_chars_acc(s, [])
}

fn string_to_chars_acc(s: String, acc: List(String)) -> List(String) {
  case string.pop_grapheme(s) {
    Error(_) -> list.reverse(acc)
    Ok(#(c, rest)) -> string_to_chars_acc(rest, [c, ..acc])
  }
}

fn char_code(c: String) -> Int {
  case bit_array.from_string(c) {
    <<code:8, _:bits>> -> code
    <<code:8>> -> code
    _ -> 0
  }
}

fn bech32_polymod(values: List(Int)) -> Int {
  bech32_polymod_loop(values, 1)
}

fn bech32_polymod_loop(values: List(Int), chk: Int) -> Int {
  case values {
    [] -> chk
    [v, ..rest] -> {
      let b = int.bitwise_shift_right(chk, 25)
      let new_chk = int.bitwise_xor(
        int.bitwise_and(int.bitwise_shift_left(chk, 5), 0x3FFFFFF),
        v
      )
      let new_chk = xor_generators(new_chk, b, bech32_gen, 0)
      bech32_polymod_loop(rest, new_chk)
    }
  }
}

fn xor_generators(chk: Int, b: Int, gen: List(Int), i: Int) -> Int {
  case gen {
    [] -> chk
    [g, ..rest] -> {
      let new_chk = case int.bitwise_and(int.bitwise_shift_right(b, i), 1) {
        1 -> int.bitwise_xor(chk, g)
        _ -> chk
      }
      xor_generators(new_chk, b, rest, i + 1)
    }
  }
}

fn bech32_create_checksum(values: List(Int), variant: Bech32Variant) -> List(Int) {
  let const_value = case variant {
    Bech32 -> 1
    Bech32m -> 0x2bc830a3
  }
  let poly = bech32_polymod(list.append(values, [0, 0, 0, 0, 0, 0]))
  let final_poly = int.bitwise_xor(poly, const_value)
  [
    int.bitwise_and(int.bitwise_shift_right(final_poly, 25), 31),
    int.bitwise_and(int.bitwise_shift_right(final_poly, 20), 31),
    int.bitwise_and(int.bitwise_shift_right(final_poly, 15), 31),
    int.bitwise_and(int.bitwise_shift_right(final_poly, 10), 31),
    int.bitwise_and(int.bitwise_shift_right(final_poly, 5), 31),
    int.bitwise_and(final_poly, 31),
  ]
}

// ============================================================================
// Bitcoin Address Types and Encoding
// ============================================================================

/// Bitcoin address type
pub type Address {
  /// Legacy P2PKH address (starts with 1 or m/n)
  P2PKH(hash: BitArray, network: Network)
  /// Legacy P2SH address (starts with 3 or 2)
  P2SH(hash: BitArray, network: Network)
  /// SegWit v0 P2WPKH address (starts with bc1q or tb1q)
  P2WPKH(hash: BitArray, network: Network)
  /// SegWit v0 P2WSH address (starts with bc1q or tb1q)
  P2WSH(hash: BitArray, network: Network)
  /// SegWit v1 P2TR Taproot address (starts with bc1p or tb1p)
  P2TR(pubkey: BitArray, network: Network)
}

/// Encode an address to string
pub fn address_to_string(addr: Address) -> String {
  case addr {
    P2PKH(hash, network) -> {
      let prefix = case network {
        Mainnet -> <<0x00>>
        Testnet | Regtest | Signet -> <<0x6F>>
      }
      base58check_encode(bit_array.append(prefix, hash))
    }
    P2SH(hash, network) -> {
      let prefix = case network {
        Mainnet -> <<0x05>>
        Testnet | Regtest | Signet -> <<0xC4>>
      }
      base58check_encode(bit_array.append(prefix, hash))
    }
    P2WPKH(hash, network) | P2WSH(hash, network) -> {
      let hrp = case network {
        Mainnet -> "bc"
        Testnet | Signet -> "tb"
        Regtest -> "bcrt"
      }
      let data = convert_bits(hash, 8, 5, True)
      bech32_encode(hrp, [0, ..data], Bech32)
    }
    P2TR(pubkey, network) -> {
      let hrp = case network {
        Mainnet -> "bc"
        Testnet | Signet -> "tb"
        Regtest -> "bcrt"
      }
      let data = convert_bits(pubkey, 8, 5, True)
      bech32_encode(hrp, [1, ..data], Bech32m)
    }
  }
}

/// Parse an address from string
pub fn address_from_string(s: String, network: Network) -> Result(Address, String) {
  // Try Bech32 first
  case bech32_decode(s) {
    Ok(#(hrp, data, variant)) -> {
      // Check HRP
      let expected_hrp = case network {
        Mainnet -> "bc"
        Testnet | Signet -> "tb"
        Regtest -> "bcrt"
      }
      case hrp == expected_hrp {
        False -> Error("Invalid address prefix for network")
        True -> {
          case data {
            [version, ..rest] -> {
              let payload = convert_bits_list(rest, 5, 8, False)
              case version, list.length(payload), variant {
                0, 20, Bech32 -> Ok(P2WPKH(list_to_bitarray(payload), network))
                0, 32, Bech32 -> Ok(P2WSH(list_to_bitarray(payload), network))
                1, 32, Bech32m -> Ok(P2TR(list_to_bitarray(payload), network))
                _, _, _ -> Error("Invalid witness program")
              }
            }
            _ -> Error("Invalid Bech32 data")
          }
        }
      }
    }
    Error(_) -> {
      // Try Base58Check
      case base58check_decode(s) {
        Error(e) -> Error(e)
        Ok(payload) -> {
          case payload {
            <<0x00, hash:160-bits>> -> Ok(P2PKH(<<hash:160-bits>>, network))
            <<0x6F, hash:160-bits>> -> Ok(P2PKH(<<hash:160-bits>>, network))
            <<0x05, hash:160-bits>> -> Ok(P2SH(<<hash:160-bits>>, network))
            <<0xC4, hash:160-bits>> -> Ok(P2SH(<<hash:160-bits>>, network))
            _ -> Error("Unknown address format")
          }
        }
      }
    }
  }
}

fn convert_bits(data: BitArray, from: Int, to: Int, pad: Bool) -> List(Int) {
  convert_bits_loop(data, from, to, pad, 0, 0, [])
}

fn convert_bits_loop(
  data: BitArray,
  from: Int,
  to: Int,
  pad: Bool,
  acc: Int,
  bits: Int,
  result: List(Int),
) -> List(Int) {
  case data {
    <<byte:8, rest:bits>> -> {
      let new_acc = int.bitwise_or(int.bitwise_shift_left(acc, from), byte)
      let new_bits = bits + from
      let #(new_result, final_acc, final_bits) = extract_bits(new_acc, new_bits, to, result)
      convert_bits_loop(rest, from, to, pad, final_acc, final_bits, new_result)
    }
    <<>> -> {
      case pad && bits > 0 {
        True -> {
          let padded = int.bitwise_shift_left(acc, to - bits)
          list.reverse([int.bitwise_and(padded, int.bitwise_shift_left(1, to) - 1), ..result])
        }
        False -> list.reverse(result)
      }
    }
    _ -> list.reverse(result)
  }
}

fn extract_bits(acc: Int, bits: Int, to: Int, result: List(Int)) -> #(List(Int), Int, Int) {
  case bits >= to {
    True -> {
      let new_bits = bits - to
      let value = int.bitwise_and(int.bitwise_shift_right(acc, new_bits), int.bitwise_shift_left(1, to) - 1)
      extract_bits(acc, new_bits, to, [value, ..result])
    }
    False -> #(result, acc, bits)
  }
}

fn convert_bits_list(data: List(Int), from: Int, to: Int, pad: Bool) -> List(Int) {
  convert_bits_list_loop(data, from, to, pad, 0, 0, [])
}

fn convert_bits_list_loop(
  data: List(Int),
  from: Int,
  to: Int,
  pad: Bool,
  acc: Int,
  bits: Int,
  result: List(Int),
) -> List(Int) {
  case data {
    [byte, ..rest] -> {
      let new_acc = int.bitwise_or(int.bitwise_shift_left(acc, from), byte)
      let new_bits = bits + from
      let #(new_result, final_acc, final_bits) = extract_bits(new_acc, new_bits, to, result)
      convert_bits_list_loop(rest, from, to, pad, final_acc, final_bits, new_result)
    }
    [] -> {
      case pad && bits > 0 {
        True -> {
          let padded = int.bitwise_shift_left(acc, to - bits)
          list.reverse([int.bitwise_and(padded, int.bitwise_shift_left(1, to) - 1), ..result])
        }
        False -> list.reverse(result)
      }
    }
  }
}

fn list_to_bitarray(lst: List(Int)) -> BitArray {
  list.fold(lst, <<>>, fn(acc, byte) {
    bit_array.append(acc, <<byte:8>>)
  })
}
