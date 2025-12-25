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
