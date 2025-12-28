// oni_bitcoin - Bitcoin primitives library for the oni Bitcoin node
//
// This module provides the core types and utilities for Bitcoin protocol
// implementation. It follows Bitcoin Core semantics for consensus-critical
// operations.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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

/// Encode bytes to hex string
pub fn bytes_to_hex(bytes: BitArray) -> String {
  do_bytes_to_hex(bytes, "")
}

fn do_bytes_to_hex(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<byte:8, rest:bits>> -> {
      let hi = int_to_hex_char(byte / 16)
      let lo = int_to_hex_char(byte % 16)
      do_bytes_to_hex(rest, acc <> hi <> lo)
    }
    _ -> acc
  }
}

fn int_to_hex_char(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "a"
    11 -> "b"
    12 -> "c"
    13 -> "d"
    14 -> "e"
    15 -> "f"
    _ -> "?"
  }
}

/// Alias for txid_to_hex (wtxids have same format)
pub fn wtxid_to_hex(txid: Txid) -> String {
  txid_to_hex(txid)
}

/// Decode a bech32/bech32m address to version and program
pub fn decode_bech32_address(address: String) -> Result(#(Int, BitArray), String) {
  case bech32_decode(address) {
    Error(e) -> Error(e)
    Ok(#(_hrp, data, _variant)) -> {
      case data {
        [version, ..rest] -> {
          // Convert 5-bit groups to bytes
          case convert_bits_5to8(rest) {
            Error(e) -> Error(e)
            Ok(program) -> Ok(#(version, program))
          }
        }
        _ -> Error("Empty bech32 data")
      }
    }
  }
}

fn convert_bits_5to8(input: List(Int)) -> Result(BitArray, String) {
  // Convert list of 5-bit values to 8-bit bytes
  // We accumulate bits and emit bytes when we have 8
  let result = do_convert_bits_5to8(input, 0, 0, <<>>)
  Ok(result)
}

fn do_convert_bits_5to8(input: List(Int), acc: Int, bits: Int, result: BitArray) -> BitArray {
  case input {
    [] -> {
      // If we have remaining bits, ignore padding
      result
    }
    [val, ..rest] -> {
      // Add 5 bits to accumulator
      let new_acc = { acc * 32 } + val
      let new_bits = bits + 5

      case new_bits >= 8 {
        True -> {
          // Extract a byte
          let shift = new_bits - 8
          let byte = new_acc / { 1 * power_of_2(shift) }
          let remaining = new_acc % { 1 * power_of_2(shift) }
          do_convert_bits_5to8(rest, remaining, shift, bit_array.append(result, <<byte:8>>))
        }
        False -> do_convert_bits_5to8(rest, new_acc, new_bits, result)
      }
    }
  }
}

fn power_of_2(n: Int) -> Int {
  case n {
    0 -> 1
    _ -> 2 * power_of_2(n - 1)
  }
}

/// Decode a base58check address to version and payload
pub fn decode_base58check(address: String) -> Result(#(Int, BitArray), String) {
  case base58check_decode(address) {
    Error(e) -> Error(e)
    Ok(decoded) -> {
      case decoded {
        <<version:8, payload:bits>> -> Ok(#(version, payload))
        _ -> Error("Invalid base58check payload")
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
  erlang_hash(ripemd160_atom(), data)
}

/// SHA1 hash - uses Erlang's crypto module directly
/// Note: SHA1 is cryptographically weak and should only be used for
/// Bitcoin Script compatibility (OP_SHA1)
pub fn sha1(data: BitArray) -> BitArray {
  erlang_hash(sha1_atom(), data)
}

/// Erlang FFI for crypto:hash
@external(erlang, "crypto", "hash")
fn erlang_hash(algo: ErlangAtom, data: BitArray) -> BitArray

/// Get the ripemd160 atom
@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: BitArray) -> ErlangAtom

type ErlangAtom

fn ripemd160_atom() -> ErlangAtom {
  binary_to_atom(<<"ripemd160":utf8>>)
}

fn sha1_atom() -> ErlangAtom {
  binary_to_atom(<<"sha":utf8>>)
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
  case string.drop_left(s, idx) {
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
              let data_part = string.drop_left(normalized, sep_pos + 1)

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
      let new_chk = int.bitwise_exclusive_or(
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
        1 -> int.bitwise_exclusive_or(chk, g)
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
  let final_poly = int.bitwise_exclusive_or(poly, const_value)
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

// ============================================================================
// Block Header Serialization
// ============================================================================

/// Encode a block header to bytes (80 bytes)
pub fn encode_block_header(header: BlockHeader) -> BitArray {
  bit_array.concat([
    <<header.version:32-little>>,
    header.prev_block.hash.bytes,
    header.merkle_root.bytes,
    <<header.timestamp:32-little>>,
    <<header.bits:32-little>>,
    <<header.nonce:32-little>>,
  ])
}

/// Decode a block header from bytes
pub fn decode_block_header(bytes: BitArray) -> Result(#(BlockHeader, BitArray), String) {
  case bytes {
    <<version:32-little, prev:256-bits, merkle:256-bits,
      timestamp:32-little, bits:32-little, nonce:32-little, rest:bits>> -> {
      let prev_block = BlockHash(Hash256(<<prev:256-bits>>))
      let merkle_root = Hash256(<<merkle:256-bits>>)
      let header = BlockHeader(
        version: version,
        prev_block: prev_block,
        merkle_root: merkle_root,
        timestamp: timestamp,
        bits: bits,
        nonce: nonce,
      )
      Ok(#(header, rest))
    }
    _ -> Error("Insufficient bytes for block header (need 80)")
  }
}

/// Compute the block hash from a header
pub fn block_hash_from_header(header: BlockHeader) -> BlockHash {
  let serialized = encode_block_header(header)
  let hash = hash256_digest(serialized)
  BlockHash(hash)
}

// ============================================================================
// Block Serialization
// ============================================================================

/// Encode a full block to bytes
pub fn encode_block(block: Block) -> BitArray {
  let header_bytes = encode_block_header(block.header)
  let tx_count = compact_size_encode(list.length(block.transactions))
  let tx_bytes = list.fold(block.transactions, <<>>, fn(acc, tx) {
    bit_array.append(acc, encode_tx(tx))
  })
  bit_array.concat([header_bytes, tx_count, tx_bytes])
}

/// Decode a full block from bytes
pub fn decode_block(bytes: BitArray) -> Result(#(Block, BitArray), String) {
  case decode_block_header(bytes) {
    Error(e) -> Error(e)
    Ok(#(header, after_header)) -> {
      case compact_size_decode(after_header) {
        Error(e) -> Error(e)
        Ok(#(tx_count, after_count)) -> {
          case decode_transactions(after_count, tx_count, []) {
            Error(e) -> Error(e)
            Ok(#(txs, remaining)) -> {
              let block = Block(header, txs)
              Ok(#(block, remaining))
            }
          }
        }
      }
    }
  }
}

fn decode_transactions(bytes: BitArray, count: Int, acc: List(Transaction)) -> Result(#(List(Transaction), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case decode_tx(bytes) {
        Error(e) -> Error(e)
        Ok(#(tx, rest)) -> decode_transactions(rest, count - 1, [tx, ..acc])
      }
    }
  }
}

// ============================================================================
// Network Magic Constants
// ============================================================================

/// Network magic bytes for message framing
pub type NetworkMagic {
  NetworkMagic(bytes: BitArray)
}

/// Get network magic for mainnet
pub fn mainnet_magic() -> NetworkMagic {
  NetworkMagic(<<0xF9, 0xBE, 0xB4, 0xD9>>)
}

/// Get network magic for testnet
pub fn testnet_magic() -> NetworkMagic {
  NetworkMagic(<<0x0B, 0x11, 0x09, 0x07>>)
}

/// Get network magic for regtest
pub fn regtest_magic() -> NetworkMagic {
  NetworkMagic(<<0xFA, 0xBF, 0xB5, 0xDA>>)
}

/// Get network magic for signet
pub fn signet_magic() -> NetworkMagic {
  NetworkMagic(<<0x0A, 0x03, 0xCF, 0x40>>)
}

/// Get network magic for a network type
pub fn network_magic(network: Network) -> NetworkMagic {
  case network {
    Mainnet -> mainnet_magic()
    Testnet -> testnet_magic()
    Regtest -> regtest_magic()
    Signet -> signet_magic()
  }
}

// ============================================================================
// WIF (Wallet Import Format) Encoding
// ============================================================================

/// Private key type
pub type PrivateKey {
  PrivateKey(bytes: BitArray, compressed: Bool)
}

/// Create a private key from 32 bytes
pub fn private_key_from_bytes(bytes: BitArray, compressed: Bool) -> Result(PrivateKey, String) {
  case bit_array.byte_size(bytes) {
    32 -> Ok(PrivateKey(bytes, compressed))
    _ -> Error("Private key must be 32 bytes")
  }
}

/// Encode a private key to WIF format
pub fn private_key_to_wif(key: PrivateKey, network: Network) -> String {
  let prefix = case network {
    Mainnet -> <<0x80>>
    Testnet | Regtest | Signet -> <<0xEF>>
  }

  let payload = case key.compressed {
    True -> bit_array.concat([prefix, key.bytes, <<0x01>>])
    False -> bit_array.append(prefix, key.bytes)
  }

  base58check_encode(payload)
}

/// Decode a private key from WIF format
pub fn private_key_from_wif(wif: String) -> Result(#(PrivateKey, Network), String) {
  case base58check_decode(wif) {
    Error(e) -> Error(e)
    Ok(payload) -> {
      case payload {
        // Mainnet compressed (34 bytes: prefix + 32 key + compression flag)
        <<0x80, key:256-bits, 0x01>> -> {
          case private_key_from_bytes(<<key:256-bits>>, True) {
            Ok(pk) -> Ok(#(pk, Mainnet))
            Error(e) -> Error(e)
          }
        }
        // Mainnet uncompressed (33 bytes: prefix + 32 key)
        <<0x80, key:256-bits>> -> {
          case private_key_from_bytes(<<key:256-bits>>, False) {
            Ok(pk) -> Ok(#(pk, Mainnet))
            Error(e) -> Error(e)
          }
        }
        // Testnet compressed
        <<0xEF, key:256-bits, 0x01>> -> {
          case private_key_from_bytes(<<key:256-bits>>, True) {
            Ok(pk) -> Ok(#(pk, Testnet))
            Error(e) -> Error(e)
          }
        }
        // Testnet uncompressed
        <<0xEF, key:256-bits>> -> {
          case private_key_from_bytes(<<key:256-bits>>, False) {
            Ok(pk) -> Ok(#(pk, Testnet))
            Error(e) -> Error(e)
          }
        }
        _ -> Error("Invalid WIF format")
      }
    }
  }
}

/// Get the public key hash (hash160) from a private key
/// Note: This is a placeholder - real implementation requires secp256k1
pub fn private_key_to_pubkey_hash(_key: PrivateKey) -> BitArray {
  // In a real implementation, this would:
  // 1. Derive the public key from the private key using secp256k1
  // 2. Compress or not based on the compressed flag
  // 3. Return hash160(pubkey)
  // For now, return a placeholder
  <<0:160>>
}

// ============================================================================
// Extended Public Key Types (BIP32)
// ============================================================================

/// Extended key depth
pub type ExtKeyDepth = Int

/// Extended key fingerprint (4 bytes)
pub type Fingerprint {
  Fingerprint(bytes: BitArray)
}

/// Extended key chain code (32 bytes)
pub type ChainCode {
  ChainCode(bytes: BitArray)
}

/// Create a fingerprint from bytes
pub fn fingerprint_from_bytes(bytes: BitArray) -> Result(Fingerprint, String) {
  case bit_array.byte_size(bytes) {
    4 -> Ok(Fingerprint(bytes))
    _ -> Error("Fingerprint must be 4 bytes")
  }
}

/// Create a chain code from bytes
pub fn chain_code_from_bytes(bytes: BitArray) -> Result(ChainCode, String) {
  case bit_array.byte_size(bytes) {
    32 -> Ok(ChainCode(bytes))
    _ -> Error("Chain code must be 32 bytes")
  }
}

// ============================================================================
// Schnorr Signature Verification (BIP-340)
// ============================================================================

/// Verify a BIP-340 Schnorr signature
/// Uses the secp256k1 NIF for actual verification
pub fn schnorr_verify_nif(
  sig: SchnorrSig,
  msg_hash: BitArray,
  pubkey: XOnlyPubKey,
) -> Result(Bool, CryptoError) {
  case bit_array.byte_size(msg_hash) {
    32 -> {
      // Call the Erlang NIF module
      case erlang_schnorr_verify(msg_hash, sig.bytes, pubkey.bytes) {
        #(True, True) -> Ok(True)
        #(True, False) -> Ok(False)
        _ -> Error(VerificationFailed)
      }
    }
    _ -> Error(InvalidMessage)
  }
}

/// Erlang FFI for Schnorr verification
@external(erlang, "oni_secp256k1", "schnorr_verify")
fn erlang_schnorr_verify(
  msg_hash: BitArray,
  signature: BitArray,
  pubkey: BitArray,
) -> #(Bool, Bool)

/// Tweak a public key for Taproot (BIP-341)
pub fn tweak_pubkey_for_taproot(
  internal_key: XOnlyPubKey,
  tweak_hash: BitArray,
) -> Result(#(XOnlyPubKey, Int), CryptoError) {
  case bit_array.byte_size(tweak_hash) {
    32 -> {
      case erlang_tweak_pubkey(internal_key.bytes, tweak_hash) {
        #(True, #(output_key, parity)) -> {
          case xonly_pubkey_from_bytes(output_key) {
            Ok(pk) -> Ok(#(pk, parity))
            Error(_) -> Error(InvalidPublicKey)
          }
        }
        _ -> Error(UnsupportedOperation)
      }
    }
    _ -> Error(InvalidMessage)
  }
}

/// Erlang FFI for Taproot pubkey tweaking
@external(erlang, "oni_secp256k1", "tweak_pubkey")
fn erlang_tweak_pubkey(
  internal_key: BitArray,
  tweak_hash: BitArray,
) -> #(Bool, #(BitArray, Int))

// ============================================================================
// Script Helper Functions
// ============================================================================

/// Create an empty script
pub fn script_empty() -> Script {
  Script(<<>>)
}

/// Create a script from hex string
pub fn script_from_hex(hex: String) -> Result(Script, String) {
  case hex_decode(hex) {
    Ok(bytes) -> Ok(Script(bytes))
    Error(e) -> Error(e)
  }
}

/// Create satoshi amount directly (for internal use)
pub fn sats(value: Int) -> Amount {
  Amount(value)
}

// ============================================================================
// PSBT (Partially Signed Bitcoin Transaction) - BIP174/BIP370
// ============================================================================

/// PSBT magic bytes "psbt\xff"
const psbt_magic = <<0x70, 0x73, 0x62, 0x74, 0xFF>>

/// PSBT key types for global map
pub type PsbtGlobalKey {
  PsbtGlobalUnsignedTx       // 0x00
  PsbtGlobalXpub             // 0x01
  PsbtGlobalTxVersion        // 0x02 (PSBT v2)
  PsbtGlobalFallbackLocktime // 0x03 (PSBT v2)
  PsbtGlobalInputCount       // 0x04 (PSBT v2)
  PsbtGlobalOutputCount      // 0x05 (PSBT v2)
  PsbtGlobalTxModifiable     // 0x06 (PSBT v2)
  PsbtGlobalVersion          // 0xFB
  PsbtGlobalProprietary      // 0xFC
  PsbtGlobalUnknown(Int)
}

/// PSBT key types for input map
pub type PsbtInputKey {
  PsbtInNonWitnessUtxo       // 0x00
  PsbtInWitnessUtxo          // 0x01
  PsbtInPartialSig           // 0x02
  PsbtInSighashType          // 0x03
  PsbtInRedeemScript         // 0x04
  PsbtInWitnessScript        // 0x05
  PsbtInBip32Derivation      // 0x06
  PsbtInFinalScriptsig       // 0x07
  PsbtInFinalScriptwitness   // 0x08
  PsbtInPorCommitment        // 0x09
  PsbtInRipemd160            // 0x0A
  PsbtInSha256               // 0x0B
  PsbtInHash160              // 0x0C
  PsbtInHash256              // 0x0D
  PsbtInPreviousTxid         // 0x0E (PSBT v2)
  PsbtInOutputIndex          // 0x0F (PSBT v2)
  PsbtInSequence             // 0x10 (PSBT v2)
  PsbtInRequiredTimeLocktime // 0x11 (PSBT v2)
  PsbtInRequiredHeightLocktime // 0x12 (PSBT v2)
  PsbtInTapKeySig            // 0x13
  PsbtInTapScriptSig         // 0x14
  PsbtInTapLeafScript        // 0x15
  PsbtInTapBip32Derivation   // 0x16
  PsbtInTapInternalKey       // 0x17
  PsbtInTapMerkleRoot        // 0x18
  PsbtInProprietary          // 0xFC
  PsbtInUnknown(Int)
}

/// PSBT key types for output map
pub type PsbtOutputKey {
  PsbtOutRedeemScript        // 0x00
  PsbtOutWitnessScript       // 0x01
  PsbtOutBip32Derivation     // 0x02
  PsbtOutAmount              // 0x03 (PSBT v2)
  PsbtOutScript              // 0x04 (PSBT v2)
  PsbtOutTapInternalKey      // 0x05
  PsbtOutTapTree             // 0x06
  PsbtOutTapBip32Derivation  // 0x07
  PsbtOutProprietary         // 0xFC
  PsbtOutUnknown(Int)
}

/// A PSBT input
pub type PsbtInput {
  PsbtInput(
    non_witness_utxo: Option(Transaction),
    witness_utxo: Option(TxOut),
    partial_sigs: List(#(BitArray, BitArray)),
    sighash_type: Option(Int),
    redeem_script: Option(Script),
    witness_script: Option(Script),
    bip32_derivation: List(#(BitArray, BitArray)),
    final_script_sig: Option(Script),
    final_script_witness: Option(List(BitArray)),
    tap_key_sig: Option(BitArray),
    tap_script_sigs: List(#(BitArray, BitArray)),
    tap_leaf_scripts: List(#(BitArray, BitArray)),
    tap_internal_key: Option(BitArray),
    tap_merkle_root: Option(BitArray),
    unknown: List(#(BitArray, BitArray)),
  )
}

/// A PSBT output
pub type PsbtOutput {
  PsbtOutput(
    redeem_script: Option(Script),
    witness_script: Option(Script),
    bip32_derivation: List(#(BitArray, BitArray)),
    tap_internal_key: Option(BitArray),
    tap_tree: Option(BitArray),
    unknown: List(#(BitArray, BitArray)),
  )
}

/// Partially Signed Bitcoin Transaction
pub type Psbt {
  Psbt(
    unsigned_tx: Transaction,
    version: Int,
    xpubs: List(#(BitArray, BitArray)),
    inputs: List(PsbtInput),
    outputs: List(PsbtOutput),
    unknown: List(#(BitArray, BitArray)),
  )
}

/// PSBT errors
pub type PsbtError {
  PsbtInvalidMagic
  PsbtInvalidFormat(String)
  PsbtMissingUnsignedTx
  PsbtDuplicateKey
  PsbtInvalidKeyType
  PsbtInputCountMismatch
  PsbtOutputCountMismatch
  PsbtAlreadyFinalized
  PsbtNotFinalized
}

/// Create an empty PSBT input
pub fn psbt_input_new() -> PsbtInput {
  PsbtInput(
    non_witness_utxo: option.None,
    witness_utxo: option.None,
    partial_sigs: [],
    sighash_type: option.None,
    redeem_script: option.None,
    witness_script: option.None,
    bip32_derivation: [],
    final_script_sig: option.None,
    final_script_witness: option.None,
    tap_key_sig: option.None,
    tap_script_sigs: [],
    tap_leaf_scripts: [],
    tap_internal_key: option.None,
    tap_merkle_root: option.None,
    unknown: [],
  )
}

/// Create an empty PSBT output
pub fn psbt_output_new() -> PsbtOutput {
  PsbtOutput(
    redeem_script: option.None,
    witness_script: option.None,
    bip32_derivation: [],
    tap_internal_key: option.None,
    tap_tree: option.None,
    unknown: [],
  )
}

/// Create a PSBT from an unsigned transaction
pub fn psbt_from_unsigned_tx(tx: Transaction) -> Result(Psbt, PsbtError) {
  // Verify transaction has no signatures
  let has_sigs = list.any(tx.inputs, fn(input) {
    !script_is_empty(input.script_sig) || !list.is_empty(input.witness)
  })

  case has_sigs {
    True -> Error(PsbtAlreadyFinalized)
    False -> {
      // Create empty inputs and outputs
      let inputs = list.map(tx.inputs, fn(_) { psbt_input_new() })
      let outputs = list.map(tx.outputs, fn(_) { psbt_output_new() })

      Ok(Psbt(
        unsigned_tx: tx,
        version: 0,
        xpubs: [],
        inputs: inputs,
        outputs: outputs,
        unknown: [],
      ))
    }
  }
}

/// Serialize a PSBT to bytes
pub fn psbt_serialize(psbt: Psbt) -> BitArray {
  let global_map = serialize_psbt_global(psbt)
  let input_maps = list.map(psbt.inputs, serialize_psbt_input)
  let output_maps = list.map(psbt.outputs, serialize_psbt_output)

  bit_array.concat([
    psbt_magic,
    global_map,
    ..list.append(input_maps, output_maps)
  ])
}

fn serialize_psbt_global(psbt: Psbt) -> BitArray {
  // Serialize unsigned transaction
  let tx_bytes = encode_tx_legacy(psbt.unsigned_tx)
  let tx_key = <<0x00>>
  let tx_entry = serialize_psbt_entry(tx_key, tx_bytes)

  // Serialize version if non-zero
  let version_entry = case psbt.version {
    0 -> <<>>
    v -> {
      let version_key = <<0xFB>>
      let version_value = <<v:32-little>>
      serialize_psbt_entry(version_key, version_value)
    }
  }

  // Serialize xpubs
  let xpub_entries = list.fold(psbt.xpubs, <<>>, fn(acc, xpub) {
    let #(key, value) = xpub
    let full_key = bit_array.append(<<0x01>>, key)
    bit_array.append(acc, serialize_psbt_entry(full_key, value))
  })

  // Serialize unknown entries
  let unknown_entries = list.fold(psbt.unknown, <<>>, fn(acc, entry) {
    let #(key, value) = entry
    bit_array.append(acc, serialize_psbt_entry(key, value))
  })

  // End with separator (0x00)
  bit_array.concat([tx_entry, version_entry, xpub_entries, unknown_entries, <<0x00>>])
}

fn serialize_psbt_entry(key: BitArray, value: BitArray) -> BitArray {
  let key_len = compact_size_encode(bit_array.byte_size(key))
  let value_len = compact_size_encode(bit_array.byte_size(value))
  bit_array.concat([key_len, key, value_len, value])
}

fn serialize_psbt_input(input: PsbtInput) -> BitArray {
  let mut_data = <<>>

  // Non-witness UTXO
  let data = case input.non_witness_utxo {
    option.Some(tx) -> {
      let tx_bytes = encode_tx(tx)
      bit_array.append(mut_data, serialize_psbt_entry(<<0x00>>, tx_bytes))
    }
    option.None -> mut_data
  }

  // Witness UTXO
  let data = case input.witness_utxo {
    option.Some(utxo) -> {
      let utxo_bytes = serialize_txout(utxo)
      bit_array.append(data, serialize_psbt_entry(<<0x01>>, utxo_bytes))
    }
    option.None -> data
  }

  // Partial signatures
  let data = list.fold(input.partial_sigs, data, fn(acc, sig) {
    let #(pubkey, signature) = sig
    let key = bit_array.append(<<0x02>>, pubkey)
    bit_array.append(acc, serialize_psbt_entry(key, signature))
  })

  // Sighash type
  let data = case input.sighash_type {
    option.Some(sighash) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x03>>, <<sighash:32-little>>))
    }
    option.None -> data
  }

  // Redeem script
  let data = case input.redeem_script {
    option.Some(script) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x04>>, script_to_bytes(script)))
    }
    option.None -> data
  }

  // Witness script
  let data = case input.witness_script {
    option.Some(script) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x05>>, script_to_bytes(script)))
    }
    option.None -> data
  }

  // Final scriptsig
  let data = case input.final_script_sig {
    option.Some(script) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x07>>, script_to_bytes(script)))
    }
    option.None -> data
  }

  // Final scriptwitness
  let data = case input.final_script_witness {
    option.Some(witness) -> {
      let witness_bytes = serialize_witness_stack(witness)
      bit_array.append(data, serialize_psbt_entry(<<0x08>>, witness_bytes))
    }
    option.None -> data
  }

  // Tap key signature
  let data = case input.tap_key_sig {
    option.Some(sig) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x13>>, sig))
    }
    option.None -> data
  }

  // Tap internal key
  let data = case input.tap_internal_key {
    option.Some(key) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x17>>, key))
    }
    option.None -> data
  }

  // Unknown entries
  let data = list.fold(input.unknown, data, fn(acc, entry) {
    let #(key, value) = entry
    bit_array.append(acc, serialize_psbt_entry(key, value))
  })

  // End with separator
  bit_array.append(data, <<0x00>>)
}

fn serialize_psbt_output(output: PsbtOutput) -> BitArray {
  let mut_data = <<>>

  // Redeem script
  let data = case output.redeem_script {
    option.Some(script) -> {
      bit_array.append(mut_data, serialize_psbt_entry(<<0x00>>, script_to_bytes(script)))
    }
    option.None -> mut_data
  }

  // Witness script
  let data = case output.witness_script {
    option.Some(script) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x01>>, script_to_bytes(script)))
    }
    option.None -> data
  }

  // BIP32 derivation paths
  let data = list.fold(output.bip32_derivation, data, fn(acc, deriv) {
    let #(pubkey, path) = deriv
    let key = bit_array.append(<<0x02>>, pubkey)
    bit_array.append(acc, serialize_psbt_entry(key, path))
  })

  // Tap internal key
  let data = case output.tap_internal_key {
    option.Some(key) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x05>>, key))
    }
    option.None -> data
  }

  // Tap tree
  let data = case output.tap_tree {
    option.Some(tree) -> {
      bit_array.append(data, serialize_psbt_entry(<<0x06>>, tree))
    }
    option.None -> data
  }

  // Unknown entries
  let data = list.fold(output.unknown, data, fn(acc, entry) {
    let #(key, value) = entry
    bit_array.append(acc, serialize_psbt_entry(key, value))
  })

  // End with separator
  bit_array.append(data, <<0x00>>)
}

fn serialize_txout(output: TxOut) -> BitArray {
  let script = script_to_bytes(output.script_pubkey)
  let value = amount_to_sats(output.value)
  bit_array.concat([
    <<value:64-little>>,
    compact_size_encode(bit_array.byte_size(script)),
    script,
  ])
}

fn serialize_witness_stack(witness: List(BitArray)) -> BitArray {
  let count = compact_size_encode(list.length(witness))
  let items = list.fold(witness, <<>>, fn(acc, item) {
    let item_len = compact_size_encode(bit_array.byte_size(item))
    bit_array.concat([acc, item_len, item])
  })
  bit_array.append(count, items)
}

/// Parse a PSBT from bytes
pub fn psbt_parse(bytes: BitArray) -> Result(Psbt, PsbtError) {
  // Check magic
  case bytes {
    <<0x70, 0x73, 0x62, 0x74, 0xFF, rest:bits>> -> {
      parse_psbt_maps(rest)
    }
    _ -> Error(PsbtInvalidMagic)
  }
}

fn parse_psbt_maps(bytes: BitArray) -> Result(Psbt, PsbtError) {
  // Parse global map
  case parse_psbt_global_map(bytes, option.None, 0, [], []) {
    Error(e) -> Error(e)
    Ok(#(unsigned_tx, version, xpubs, unknown, rest)) -> {
      case unsigned_tx {
        option.None -> Error(PsbtMissingUnsignedTx)
        option.Some(tx) -> {
          let input_count = list.length(tx.inputs)
          let output_count = list.length(tx.outputs)

          // Parse input maps
          case parse_psbt_input_maps(rest, input_count, []) {
            Error(e) -> Error(e)
            Ok(#(inputs, rest2)) -> {
              // Parse output maps
              case parse_psbt_output_maps(rest2, output_count, []) {
                Error(e) -> Error(e)
                Ok(#(outputs, _rest3)) -> {
                  Ok(Psbt(
                    unsigned_tx: tx,
                    version: version,
                    xpubs: xpubs,
                    inputs: inputs,
                    outputs: outputs,
                    unknown: unknown,
                  ))
                }
              }
            }
          }
        }
      }
    }
  }
}

fn parse_psbt_global_map(
  bytes: BitArray,
  tx: Option(Transaction),
  version: Int,
  xpubs: List(#(BitArray, BitArray)),
  unknown: List(#(BitArray, BitArray)),
) -> Result(#(Option(Transaction), Int, List(#(BitArray, BitArray)), List(#(BitArray, BitArray)), BitArray), PsbtError) {
  // Read key length
  case compact_size_decode(bytes) {
    Error(_) -> Error(PsbtInvalidFormat("Failed to read key length"))
    Ok(#(0, rest)) -> {
      // Separator - end of global map
      Ok(#(tx, version, list.reverse(xpubs), list.reverse(unknown), rest))
    }
    Ok(#(key_len, rest)) -> {
      // Read key
      case bit_array.slice(rest, 0, key_len) {
        Error(_) -> Error(PsbtInvalidFormat("Failed to read key"))
        Ok(key) -> {
          let after_key = slice_after(rest, key_len)
          // Read value length
          case compact_size_decode(after_key) {
            Error(_) -> Error(PsbtInvalidFormat("Failed to read value length"))
            Ok(#(value_len, after_value_len)) -> {
              case bit_array.slice(after_value_len, 0, value_len) {
                Error(_) -> Error(PsbtInvalidFormat("Failed to read value"))
                Ok(value) -> {
                  let after_value = slice_after(after_value_len, value_len)
                  // Process based on key type
                  case key {
                    <<0x00>> -> {
                      // Unsigned transaction
                      case decode_tx(value) {
                        Error(_) -> Error(PsbtInvalidFormat("Invalid unsigned tx"))
                        Ok(#(parsed_tx, _)) -> {
                          parse_psbt_global_map(after_value, option.Some(parsed_tx), version, xpubs, unknown)
                        }
                      }
                    }
                    <<0x01, xpub_key:bits>> -> {
                      // Xpub
                      let new_xpubs = [#(<<xpub_key:bits>>, value), ..xpubs]
                      parse_psbt_global_map(after_value, tx, version, new_xpubs, unknown)
                    }
                    <<0xFB>> -> {
                      // Version
                      case value {
                        <<v:32-little>> -> {
                          parse_psbt_global_map(after_value, tx, v, xpubs, unknown)
                        }
                        _ -> Error(PsbtInvalidFormat("Invalid version"))
                      }
                    }
                    _ -> {
                      // Unknown
                      let new_unknown = [#(key, value), ..unknown]
                      parse_psbt_global_map(after_value, tx, version, xpubs, new_unknown)
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

fn parse_psbt_input_maps(
  bytes: BitArray,
  remaining: Int,
  acc: List(PsbtInput),
) -> Result(#(List(PsbtInput), BitArray), PsbtError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case parse_psbt_input_map(bytes, psbt_input_new()) {
        Error(e) -> Error(e)
        Ok(#(input, rest)) -> {
          parse_psbt_input_maps(rest, remaining - 1, [input, ..acc])
        }
      }
    }
  }
}

fn parse_psbt_input_map(
  bytes: BitArray,
  input: PsbtInput,
) -> Result(#(PsbtInput, BitArray), PsbtError) {
  case compact_size_decode(bytes) {
    Error(_) -> Error(PsbtInvalidFormat("Failed to read input key length"))
    Ok(#(0, rest)) -> {
      // Separator
      Ok(#(input, rest))
    }
    Ok(#(key_len, rest)) -> {
      case bit_array.slice(rest, 0, key_len) {
        Error(_) -> Error(PsbtInvalidFormat("Failed to read input key"))
        Ok(key) -> {
          let after_key = slice_after(rest, key_len)
          case compact_size_decode(after_key) {
            Error(_) -> Error(PsbtInvalidFormat("Failed to read input value length"))
            Ok(#(value_len, after_value_len)) -> {
              case bit_array.slice(after_value_len, 0, value_len) {
                Error(_) -> Error(PsbtInvalidFormat("Failed to read input value"))
                Ok(value) -> {
                  let after_value = slice_after(after_value_len, value_len)
                  let new_input = update_psbt_input(input, key, value)
                  parse_psbt_input_map(after_value, new_input)
                }
              }
            }
          }
        }
      }
    }
  }
}

fn update_psbt_input(input: PsbtInput, key: BitArray, value: BitArray) -> PsbtInput {
  case key {
    <<0x00>> -> {
      // Non-witness UTXO
      case decode_tx(value) {
        Ok(#(tx, _)) -> PsbtInput(..input, non_witness_utxo: option.Some(tx))
        Error(_) -> input
      }
    }
    <<0x01>> -> {
      // Witness UTXO
      case parse_txout(value) {
        Ok(#(utxo, _)) -> PsbtInput(..input, witness_utxo: option.Some(utxo))
        Error(_) -> input
      }
    }
    <<0x02, pubkey:bits>> -> {
      // Partial signature
      PsbtInput(..input, partial_sigs: [#(<<pubkey:bits>>, value), ..input.partial_sigs])
    }
    <<0x03>> -> {
      // Sighash type
      case value {
        <<sighash:32-little>> -> PsbtInput(..input, sighash_type: option.Some(sighash))
        _ -> input
      }
    }
    <<0x04>> -> {
      // Redeem script
      PsbtInput(..input, redeem_script: option.Some(Script(value)))
    }
    <<0x05>> -> {
      // Witness script
      PsbtInput(..input, witness_script: option.Some(Script(value)))
    }
    <<0x07>> -> {
      // Final scriptsig
      PsbtInput(..input, final_script_sig: option.Some(Script(value)))
    }
    <<0x08>> -> {
      // Final scriptwitness
      case parse_witness_stack(value) {
        Ok(witness) -> PsbtInput(..input, final_script_witness: option.Some(witness))
        Error(_) -> input
      }
    }
    <<0x13>> -> {
      // Tap key sig
      PsbtInput(..input, tap_key_sig: option.Some(value))
    }
    <<0x17>> -> {
      // Tap internal key
      PsbtInput(..input, tap_internal_key: option.Some(value))
    }
    <<0x18>> -> {
      // Tap merkle root
      PsbtInput(..input, tap_merkle_root: option.Some(value))
    }
    _ -> {
      // Unknown
      PsbtInput(..input, unknown: [#(key, value), ..input.unknown])
    }
  }
}

fn parse_psbt_output_maps(
  bytes: BitArray,
  remaining: Int,
  acc: List(PsbtOutput),
) -> Result(#(List(PsbtOutput), BitArray), PsbtError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case parse_psbt_output_map(bytes, psbt_output_new()) {
        Error(e) -> Error(e)
        Ok(#(output, rest)) -> {
          parse_psbt_output_maps(rest, remaining - 1, [output, ..acc])
        }
      }
    }
  }
}

fn parse_psbt_output_map(
  bytes: BitArray,
  output: PsbtOutput,
) -> Result(#(PsbtOutput, BitArray), PsbtError) {
  case compact_size_decode(bytes) {
    Error(_) -> Error(PsbtInvalidFormat("Failed to read output key length"))
    Ok(#(0, rest)) -> {
      // Separator
      Ok(#(output, rest))
    }
    Ok(#(key_len, rest)) -> {
      case bit_array.slice(rest, 0, key_len) {
        Error(_) -> Error(PsbtInvalidFormat("Failed to read output key"))
        Ok(key) -> {
          let after_key = slice_after(rest, key_len)
          case compact_size_decode(after_key) {
            Error(_) -> Error(PsbtInvalidFormat("Failed to read output value length"))
            Ok(#(value_len, after_value_len)) -> {
              case bit_array.slice(after_value_len, 0, value_len) {
                Error(_) -> Error(PsbtInvalidFormat("Failed to read output value"))
                Ok(value) -> {
                  let after_value = slice_after(after_value_len, value_len)
                  let new_output = update_psbt_output(output, key, value)
                  parse_psbt_output_map(after_value, new_output)
                }
              }
            }
          }
        }
      }
    }
  }
}

fn update_psbt_output(output: PsbtOutput, key: BitArray, value: BitArray) -> PsbtOutput {
  case key {
    <<0x00>> -> {
      // Redeem script
      PsbtOutput(..output, redeem_script: option.Some(Script(value)))
    }
    <<0x01>> -> {
      // Witness script
      PsbtOutput(..output, witness_script: option.Some(Script(value)))
    }
    <<0x02, pubkey:bits>> -> {
      // BIP32 derivation
      PsbtOutput(..output, bip32_derivation: [#(<<pubkey:bits>>, value), ..output.bip32_derivation])
    }
    <<0x05>> -> {
      // Tap internal key
      PsbtOutput(..output, tap_internal_key: option.Some(value))
    }
    <<0x06>> -> {
      // Tap tree
      PsbtOutput(..output, tap_tree: option.Some(value))
    }
    _ -> {
      // Unknown
      PsbtOutput(..output, unknown: [#(key, value), ..output.unknown])
    }
  }
}

fn parse_txout(bytes: BitArray) -> Result(#(TxOut, BitArray), String) {
  case bytes {
    <<value:64-little, rest:bits>> -> {
      case compact_size_decode(rest) {
        Error(e) -> Error(e)
        Ok(#(script_len, after_len)) -> {
          case bit_array.slice(after_len, 0, script_len) {
            Error(_) -> Error("Failed to read script")
            Ok(script_bytes) -> {
              let remaining = slice_after(after_len, script_len)
              case amount_from_sats(value) {
                Error(e) -> Error(e)
                Ok(amount) -> {
                  Ok(#(TxOut(amount, Script(script_bytes)), remaining))
                }
              }
            }
          }
        }
      }
    }
    _ -> Error("Invalid txout")
  }
}

fn parse_witness_stack(bytes: BitArray) -> Result(List(BitArray), String) {
  case compact_size_decode(bytes) {
    Error(e) -> Error(e)
    Ok(#(count, rest)) -> {
      parse_witness_items(rest, count, [])
    }
  }
}

fn parse_witness_items(
  bytes: BitArray,
  remaining: Int,
  acc: List(BitArray),
) -> Result(List(BitArray), String) {
  case remaining {
    0 -> Ok(list.reverse(acc))
    _ -> {
      case compact_size_decode(bytes) {
        Error(e) -> Error(e)
        Ok(#(item_len, rest)) -> {
          case bit_array.slice(rest, 0, item_len) {
            Error(_) -> Error("Failed to read witness item")
            Ok(item) -> {
              let after = slice_after(rest, item_len)
              parse_witness_items(after, remaining - 1, [item, ..acc])
            }
          }
        }
      }
    }
  }
}

fn slice_after(bytes: BitArray, offset: Int) -> BitArray {
  let size = bit_array.byte_size(bytes)
  case bit_array.slice(bytes, offset, size - offset) {
    Ok(rest) -> rest
    Error(_) -> <<>>
  }
}

/// Convert PSBT to base64 string
pub fn psbt_to_base64(psbt: Psbt) -> String {
  let bytes = psbt_serialize(psbt)
  base64_encode(bytes)
}

/// Parse PSBT from base64 string
pub fn psbt_from_base64(input: String) -> Result(Psbt, PsbtError) {
  case base64_decode(input) {
    Error(_) -> Error(PsbtInvalidFormat("Invalid base64"))
    Ok(bytes) -> psbt_parse(bytes)
  }
}

/// Add a partial signature to a PSBT input
pub fn psbt_add_partial_sig(
  psbt: Psbt,
  input_index: Int,
  pubkey: BitArray,
  signature: BitArray,
) -> Result(Psbt, PsbtError) {
  case list_update_at(psbt.inputs, input_index, fn(input) {
    PsbtInput(..input, partial_sigs: [#(pubkey, signature), ..input.partial_sigs])
  }) {
    Error(_) -> Error(PsbtInputCountMismatch)
    Ok(new_inputs) -> Ok(Psbt(..psbt, inputs: new_inputs))
  }
}

/// Check if a PSBT is complete (all inputs have signatures)
pub fn psbt_is_complete(psbt: Psbt) -> Bool {
  list.all(psbt.inputs, fn(input) {
    option.is_some(input.final_script_sig) ||
    option.is_some(input.final_script_witness) ||
    !list.is_empty(input.partial_sigs) ||
    option.is_some(input.tap_key_sig)
  })
}

/// Extract the final signed transaction from a finalized PSBT
pub fn psbt_extract_tx(psbt: Psbt) -> Result(Transaction, PsbtError) {
  let all_finalized = list.all(psbt.inputs, fn(input) {
    option.is_some(input.final_script_sig) ||
    option.is_some(input.final_script_witness)
  })

  case all_finalized {
    False -> Error(PsbtNotFinalized)
    True -> {
      // Build the final transaction
      let new_inputs = list.map2(psbt.unsigned_tx.inputs, psbt.inputs, fn(tx_input, psbt_input) {
        let final_sig = case psbt_input.final_script_sig {
          option.Some(script) -> script
          option.None -> script_empty()
        }
        let final_witness = case psbt_input.final_script_witness {
          option.Some(witness) -> witness
          option.None -> []
        }
        TxIn(..tx_input, script_sig: final_sig, witness: final_witness)
      })

      Ok(Transaction(..psbt.unsigned_tx, inputs: new_inputs))
    }
  }
}

fn list_update_at(lst: List(a), index: Int, f: fn(a) -> a) -> Result(List(a), Nil) {
  case lst, index {
    [], _ -> Error(Nil)
    [head, ..tail], 0 -> Ok([f(head), ..tail])
    [head, ..tail], n -> {
      case list_update_at(tail, n - 1, f) {
        Error(e) -> Error(e)
        Ok(new_tail) -> Ok([head, ..new_tail])
      }
    }
  }
}

// ============================================================================
// Base64 Encoding/Decoding
// ============================================================================

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

/// Encode bytes to base64 string
pub fn base64_encode(bytes: BitArray) -> String {
  do_base64_encode(bytes, "")
}

fn do_base64_encode(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<a:6, b:6, c:6, d:6, rest:bits>> -> {
      let chars = string_char_at(base64_alphabet, a)
        <> string_char_at(base64_alphabet, b)
        <> string_char_at(base64_alphabet, c)
        <> string_char_at(base64_alphabet, d)
      do_base64_encode(rest, acc <> chars)
    }
    <<a:6, b:6, c:4>> -> {
      let chars = string_char_at(base64_alphabet, a)
        <> string_char_at(base64_alphabet, b)
        <> string_char_at(base64_alphabet, int.bitwise_shift_left(c, 2))
        <> "="
      acc <> chars
    }
    <<a:6, b:2>> -> {
      let chars = string_char_at(base64_alphabet, a)
        <> string_char_at(base64_alphabet, int.bitwise_shift_left(b, 4))
        <> "=="
      acc <> chars
    }
    <<>> -> acc
    _ -> acc
  }
}

/// Decode base64 string to bytes
pub fn base64_decode(input: String) -> Result(BitArray, String) {
  // Remove padding
  let cleaned = string.replace(input, "=", "")
  do_base64_decode(cleaned, <<>>)
}

fn do_base64_decode(input: String, acc: BitArray) -> Result(BitArray, String) {
  case string.length(input) {
    0 -> Ok(acc)
    1 -> Error("Invalid base64 length")
    2 -> {
      case string.pop_grapheme(input) {
        Error(_) -> Ok(acc)
        Ok(#(c1, rest)) -> {
          case string.pop_grapheme(rest) {
            Error(_) -> Ok(acc)
            Ok(#(c2, _)) -> {
              case base64_char_value(c1), base64_char_value(c2) {
                Ok(v1), Ok(v2) -> {
                  let byte = int.bitwise_or(
                    int.bitwise_shift_left(v1, 2),
                    int.bitwise_shift_right(v2, 4),
                  )
                  Ok(bit_array.append(acc, <<byte:8>>))
                }
                _, _ -> Error("Invalid base64 character")
              }
            }
          }
        }
      }
    }
    3 -> {
      case take_n_chars(input, 3) {
        Error(_) -> Ok(acc)
        Ok(#(chars, _)) -> {
          case chars {
            [c1, c2, c3] -> {
              case base64_char_value(c1), base64_char_value(c2), base64_char_value(c3) {
                Ok(v1), Ok(v2), Ok(v3) -> {
                  let b1 = int.bitwise_or(
                    int.bitwise_shift_left(v1, 2),
                    int.bitwise_shift_right(v2, 4),
                  )
                  let b2 = int.bitwise_or(
                    int.bitwise_and(int.bitwise_shift_left(v2, 4), 0xF0),
                    int.bitwise_shift_right(v3, 2),
                  )
                  Ok(bit_array.concat([acc, <<b1:8, b2:8>>]))
                }
                _, _, _ -> Error("Invalid base64 character")
              }
            }
            _ -> Error("Invalid base64")
          }
        }
      }
    }
    _ -> {
      case take_n_chars(input, 4) {
        Error(_) -> Ok(acc)
        Ok(#(chars, rest)) -> {
          case chars {
            [c1, c2, c3, c4] -> {
              case base64_char_value(c1), base64_char_value(c2),
                   base64_char_value(c3), base64_char_value(c4) {
                Ok(v1), Ok(v2), Ok(v3), Ok(v4) -> {
                  let b1 = int.bitwise_or(
                    int.bitwise_shift_left(v1, 2),
                    int.bitwise_shift_right(v2, 4),
                  )
                  let b2 = int.bitwise_or(
                    int.bitwise_and(int.bitwise_shift_left(v2, 4), 0xF0),
                    int.bitwise_shift_right(v3, 2),
                  )
                  let b3 = int.bitwise_or(
                    int.bitwise_and(int.bitwise_shift_left(v3, 6), 0xC0),
                    v4,
                  )
                  let new_acc = bit_array.concat([acc, <<b1:8, b2:8, b3:8>>])
                  do_base64_decode(rest, new_acc)
                }
                _, _, _, _ -> Error("Invalid base64 character")
              }
            }
            _ -> Error("Invalid base64")
          }
        }
      }
    }
  }
}

fn base64_char_value(c: String) -> Result(Int, String) {
  case string.contains(base64_alphabet, c) {
    False -> Error("Invalid base64 character: " <> c)
    True -> find_char_index(base64_alphabet, c, 0)
  }
}

fn take_n_chars(s: String, n: Int) -> Result(#(List(String), String), Nil) {
  take_n_chars_acc(s, n, [])
}

fn take_n_chars_acc(s: String, n: Int, acc: List(String)) -> Result(#(List(String), String), Nil) {
  case n {
    0 -> Ok(#(list.reverse(acc), s))
    _ -> {
      case string.pop_grapheme(s) {
        Error(_) -> Error(Nil)
        Ok(#(c, rest)) -> take_n_chars_acc(rest, n - 1, [c, ..acc])
      }
    }
  }
}

// ============================================================================
// Transaction Fee Utilities
// ============================================================================

/// Calculate fee rate in satoshis per virtual byte
pub fn fee_rate(fee_sats: Int, vsize: Int) -> Float {
  case vsize > 0 {
    True -> int.to_float(fee_sats) /. int.to_float(vsize)
    False -> 0.0
  }
}

/// Calculate fee rate in satoshis per weight unit
pub fn fee_rate_per_wu(fee_sats: Int, weight: Int) -> Float {
  case weight > 0 {
    True -> int.to_float(fee_sats) /. int.to_float(weight)
    False -> 0.0
  }
}

/// Estimate transaction fee given a fee rate (sat/vB) and transaction
pub fn estimate_tx_fee(tx: Transaction, fee_rate_sat_per_vb: Float) -> Int {
  let vsize = tx_vsize(tx)
  float_to_int(int.to_float(vsize) *. fee_rate_sat_per_vb)
}

/// Dust threshold for an output (based on fee rate)
/// An output is considered dust if spending it would cost more than its value
pub fn dust_threshold(script_pubkey: Script, fee_rate_sat_per_vb: Float) -> Int {
  let script_size = script_size(script_pubkey)
  // Input size estimate: outpoint(36) + scriptSig length(1) + sequence(4) + scriptSig
  // For P2PKH: scriptSig is ~107 bytes (sig + pubkey)
  // For P2WPKH: witness is ~107 bytes but counted at 1/4 weight
  let input_size = case script_size {
    // P2PKH (OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG)
    25 -> 148  // 36 + 1 + 4 + 107
    // P2WPKH (OP_0 <20>)
    22 -> 68   // (36 + 1 + 4) * 4 + 107 / 4 ≈ 68 vbytes
    // P2WSH (OP_0 <32>)
    34 -> 104  // rough estimate
    // P2TR (OP_1 <32>)
    _ -> 58    // Taproot keypath
  }
  float_to_int(int.to_float(input_size) *. fee_rate_sat_per_vb)
}
