// message.gleam - Bitcoin message signing and verification (BIP-137)
//
// This module implements Bitcoin's message signing protocol as specified in
// BIP-137. This allows proving ownership of an address without revealing
// the private key.
//
// Message format:
//   - Magic prefix: "\x18Bitcoin Signed Message:\n"
//   - Message length as varint
//   - Message bytes
//   - Double SHA256 hash of the above
//
// Signature format (compact recoverable):
//   - 1 byte header (27-34 for uncompressed, 31-34 for compressed)
//   - 32 bytes r value
//   - 32 bytes s value

import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ============================================================================
// Constants
// ============================================================================

/// Bitcoin signed message magic prefix
pub const message_magic = "Bitcoin Signed Message:\n"

/// Magic prefix with length byte for hashing
pub const message_magic_bytes = <<
  24, 66, 105, 116, 99, 111, 105, 110, 32, 83, 105, 103, 110, 101, 100, 32, 77,
  101, 115, 115, 97, 103, 101, 58, 10,
>>

/// Signature header base for uncompressed keys
pub const sig_header_uncompressed_base = 27

/// Signature header base for compressed keys
pub const sig_header_compressed_base = 31

/// Signature header for P2SH-P2WPKH
pub const sig_header_p2sh_p2wpkh_base = 35

/// Signature header for P2WPKH (bech32)
pub const sig_header_p2wpkh_base = 39

// ============================================================================
// Types
// ============================================================================

/// A signed message
pub type SignedMessage {
  SignedMessage(message: String, signature: MessageSignature, address: String)
}

/// A message signature (65 bytes: 1 byte header + 32 byte r + 32 byte s)
pub type MessageSignature {
  MessageSignature(bytes: BitArray)
}

/// Address type for signature verification
pub type AddressType {
  /// Legacy P2PKH (starts with 1)
  P2PKH
  /// SegWit P2SH-P2WPKH (starts with 3)
  P2SHP2WPKH
  /// Native SegWit P2WPKH (starts with bc1q)
  P2WPKH
  /// Taproot P2TR (starts with bc1p) - uses Schnorr
  P2TR
}

/// Verification result
pub type VerifyResult {
  VerifySuccess(address_type: AddressType, compressed: Bool)
  VerifyFailed(reason: String)
  VerifyError(error: MessageError)
}

/// Message signing/verification errors
pub type MessageError {
  InvalidSignatureLength
  InvalidSignatureHeader
  InvalidSignatureFormat
  InvalidMessage
  InvalidAddress
  SignatureDecodeFailed
  HashMismatch
  RecoveryFailed
  AddressMismatch
  UnsupportedAddressType
}

// ============================================================================
// Message Hashing
// ============================================================================

/// Create the message hash for signing
/// This is the double SHA256 of the magic prefix + message
pub fn message_hash(message: String) -> BitArray {
  let message_bytes = string_to_bytes(message)
  let message_len = bit_array.byte_size(message_bytes)

  // Build the prefixed message
  let prefixed = <<
    message_magic_bytes:bits,
    { encode_varint(message_len) }:bits,
    message_bytes:bits,
  >>

  // Double SHA256
  hash256(prefixed)
}

/// Encode an integer as a Bitcoin varint
fn encode_varint(n: Int) -> BitArray {
  case n {
    _ if n < 0xFD -> <<n:8>>
    _ if n <= 0xFFFF -> <<0xFD, n:16-little>>
    _ if n <= 0xFFFFFFFF -> <<0xFE, n:32-little>>
    _ -> <<0xFF, n:64-little>>
  }
}

/// Create the full message preimage (before hashing)
pub fn message_preimage(message: String) -> BitArray {
  let message_bytes = string_to_bytes(message)
  let message_len = bit_array.byte_size(message_bytes)

  <<
    message_magic_bytes:bits,
    { encode_varint(message_len) }:bits,
    message_bytes:bits,
  >>
}

// ============================================================================
// Signature Parsing
// ============================================================================

/// Parse a base64-encoded signature
pub fn parse_signature(
  base64_sig: String,
) -> Result(MessageSignature, MessageError) {
  case base64_decode(base64_sig) {
    Error(_) -> Error(SignatureDecodeFailed)
    Ok(bytes) -> {
      case bit_array.byte_size(bytes) {
        65 -> Ok(MessageSignature(bytes))
        _ -> Error(InvalidSignatureLength)
      }
    }
  }
}

/// Get the signature header byte
pub fn get_signature_header(sig: MessageSignature) -> Result(Int, MessageError) {
  case sig.bytes {
    <<header:8, _rest:bits>> -> Ok(header)
    _ -> Error(InvalidSignatureFormat)
  }
}

/// Get the r value from a signature
pub fn get_signature_r(sig: MessageSignature) -> Result(BitArray, MessageError) {
  case sig.bytes {
    <<_header:8, r:bits-size(256), _s:bits>> -> Ok(r)
    _ -> Error(InvalidSignatureFormat)
  }
}

/// Get the s value from a signature
pub fn get_signature_s(sig: MessageSignature) -> Result(BitArray, MessageError) {
  case sig.bytes {
    <<_header:8, _r:bits-size(256), s:bits-size(256)>> -> Ok(s)
    _ -> Error(InvalidSignatureFormat)
  }
}

/// Determine address type from signature header
pub fn address_type_from_header(
  header: Int,
) -> Result(#(AddressType, Bool, Int), MessageError) {
  case header {
    // Uncompressed P2PKH (27-30)
    h if h >= 27 && h <= 30 -> Ok(#(P2PKH, False, h - 27))
    // Compressed P2PKH (31-34)
    h if h >= 31 && h <= 34 -> Ok(#(P2PKH, True, h - 31))
    // P2SH-P2WPKH (35-38)
    h if h >= 35 && h <= 38 -> Ok(#(P2SHP2WPKH, True, h - 35))
    // P2WPKH (39-42)
    h if h >= 39 && h <= 42 -> Ok(#(P2WPKH, True, h - 39))
    _ -> Error(InvalidSignatureHeader)
  }
}

/// Encode a signature to base64
pub fn encode_signature(sig: MessageSignature) -> String {
  base64_encode(sig.bytes)
}

/// Create a signature from raw bytes
pub fn signature_from_bytes(
  bytes: BitArray,
) -> Result(MessageSignature, MessageError) {
  case bit_array.byte_size(bytes) {
    65 -> Ok(MessageSignature(bytes))
    _ -> Error(InvalidSignatureLength)
  }
}

// ============================================================================
// Verification (Framework)
// ============================================================================

/// Verify a message signature (framework - needs crypto implementation)
/// This validates the signature format and prepares for verification
pub fn prepare_verification(
  message: String,
  signature_base64: String,
  address: String,
) -> Result(VerificationContext, MessageError) {
  // Parse signature
  use sig <- result.try(parse_signature(signature_base64))

  // Get header
  use header <- result.try(get_signature_header(sig))

  // Determine address type
  use #(addr_type, compressed, recovery_id) <- result.try(
    address_type_from_header(header),
  )

  // Validate address format matches claimed type
  use _ <- result.try(validate_address_format(address, addr_type))

  // Compute message hash
  let msg_hash = message_hash(message)

  Ok(VerificationContext(
    message_hash: msg_hash,
    signature: sig,
    address: address,
    address_type: addr_type,
    compressed: compressed,
    recovery_id: recovery_id,
  ))
}

/// Context for signature verification
pub type VerificationContext {
  VerificationContext(
    message_hash: BitArray,
    signature: MessageSignature,
    address: String,
    address_type: AddressType,
    compressed: Bool,
    recovery_id: Int,
  )
}

/// Validate that an address has the correct format for its type
fn validate_address_format(
  address: String,
  addr_type: AddressType,
) -> Result(Nil, MessageError) {
  case addr_type {
    P2PKH -> {
      case
        string.starts_with(address, "1")
        || string.starts_with(address, "m")
        || string.starts_with(address, "n")
      {
        True -> Ok(Nil)
        False -> Error(AddressMismatch)
      }
    }
    P2SHP2WPKH -> {
      case
        string.starts_with(address, "3") || string.starts_with(address, "2")
      {
        True -> Ok(Nil)
        False -> Error(AddressMismatch)
      }
    }
    P2WPKH -> {
      case
        string.starts_with(address, "bc1q")
        || string.starts_with(address, "tb1q")
      {
        True -> Ok(Nil)
        False -> Error(AddressMismatch)
      }
    }
    P2TR -> {
      case
        string.starts_with(address, "bc1p")
        || string.starts_with(address, "tb1p")
      {
        True -> Ok(Nil)
        False -> Error(AddressMismatch)
      }
    }
  }
}

// ============================================================================
// Signing (Framework)
// ============================================================================

/// Context for creating a signature
pub type SigningContext {
  SigningContext(
    message: String,
    message_hash: BitArray,
    address_type: AddressType,
    compressed: Bool,
  )
}

/// Prepare for signing a message
pub fn prepare_signing(
  message: String,
  address_type: AddressType,
  compressed: Bool,
) -> SigningContext {
  SigningContext(
    message: message,
    message_hash: message_hash(message),
    address_type: address_type,
    compressed: compressed,
  )
}

/// Calculate the signature header byte
pub fn calculate_signature_header(
  address_type: AddressType,
  compressed: Bool,
  recovery_id: Int,
) -> Int {
  let base = case address_type, compressed {
    P2PKH, False -> sig_header_uncompressed_base
    P2PKH, True -> sig_header_compressed_base
    P2SHP2WPKH, _ -> sig_header_p2sh_p2wpkh_base
    P2WPKH, _ -> sig_header_p2wpkh_base
    P2TR, _ -> sig_header_p2wpkh_base
    // Taproot uses same range
  }
  base + recovery_id
}

/// Create a signature from components
pub fn create_signature(
  header: Int,
  r: BitArray,
  s: BitArray,
) -> Result(MessageSignature, MessageError) {
  case bit_array.byte_size(r) == 32 && bit_array.byte_size(s) == 32 {
    True -> Ok(MessageSignature(<<header:8, r:bits, s:bits>>))
    False -> Error(InvalidSignatureFormat)
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Check if a message is valid for signing (not too long, valid UTF-8)
pub fn validate_message(message: String) -> Result(Nil, MessageError) {
  let bytes = string_to_bytes(message)
  let len = bit_array.byte_size(bytes)

  // Maximum message length (arbitrary but sensible limit)
  case len <= 65_536 {
    True -> Ok(Nil)
    False -> Error(InvalidMessage)
  }
}

/// Format a signed message as a multi-line string
pub fn format_signed_message(
  message: String,
  address: String,
  signature: MessageSignature,
) -> String {
  let sig_base64 = encode_signature(signature)
  "-----BEGIN BITCOIN SIGNED MESSAGE-----\n"
  <> message
  <> "\n"
  <> "-----BEGIN SIGNATURE-----\n"
  <> address
  <> "\n"
  <> sig_base64
  <> "\n"
  <> "-----END BITCOIN SIGNED MESSAGE-----"
}

/// Parse a formatted signed message
pub fn parse_signed_message(
  formatted: String,
) -> Result(#(String, String, String), MessageError) {
  let lines = string.split(formatted, "\n")
  parse_signed_message_lines(lines, None, None, None, Idle)
}

type ParseState {
  Idle
  ReadingMessage
  ReadingSignature
  Done
}

fn parse_signed_message_lines(
  lines: List(String),
  message: Option(String),
  address: Option(String),
  signature: Option(String),
  state: ParseState,
) -> Result(#(String, String, String), MessageError) {
  case lines {
    [] -> {
      case message, address, signature {
        Some(m), Some(a), Some(s) -> Ok(#(m, a, s))
        _, _, _ -> Error(InvalidMessage)
      }
    }
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case state {
        Idle -> {
          case string.contains(trimmed, "BEGIN BITCOIN SIGNED MESSAGE") {
            True ->
              parse_signed_message_lines(
                rest,
                message,
                address,
                signature,
                ReadingMessage,
              )
            False ->
              parse_signed_message_lines(
                rest,
                message,
                address,
                signature,
                Idle,
              )
          }
        }
        ReadingMessage -> {
          case string.contains(trimmed, "BEGIN SIGNATURE") {
            True ->
              parse_signed_message_lines(
                rest,
                message,
                address,
                signature,
                ReadingSignature,
              )
            False -> {
              let new_message = case message {
                None -> Some(trimmed)
                Some(m) -> Some(m <> "\n" <> trimmed)
              }
              parse_signed_message_lines(
                rest,
                new_message,
                address,
                signature,
                ReadingMessage,
              )
            }
          }
        }
        ReadingSignature -> {
          case string.contains(trimmed, "END BITCOIN SIGNED MESSAGE") {
            True ->
              parse_signed_message_lines(
                rest,
                message,
                address,
                signature,
                Done,
              )
            False -> {
              case address {
                None ->
                  parse_signed_message_lines(
                    rest,
                    message,
                    Some(trimmed),
                    signature,
                    ReadingSignature,
                  )
                Some(_) -> {
                  case signature {
                    None ->
                      parse_signed_message_lines(
                        rest,
                        message,
                        address,
                        Some(trimmed),
                        ReadingSignature,
                      )
                    Some(_) ->
                      parse_signed_message_lines(
                        rest,
                        message,
                        address,
                        signature,
                        ReadingSignature,
                      )
                  }
                }
              }
            }
          }
        }
        Done -> {
          case message, address, signature {
            Some(m), Some(a), Some(s) -> Ok(#(m, a, s))
            _, _, _ -> Error(InvalidMessage)
          }
        }
      }
    }
  }
}

// ============================================================================
// Helper Functions (Stubs - need crypto library)
// ============================================================================

/// Convert string to bytes (UTF-8)
fn string_to_bytes(s: String) -> BitArray {
  bit_array.from_string(s)
}

/// Double SHA256 hash
fn hash256(data: BitArray) -> BitArray {
  // Placeholder - needs crypto implementation
  // In production: sha256(sha256(data))
  let hash1 = sha256(data)
  sha256(hash1)
}

/// SHA256 hash (uses Erlang crypto module)
@external(erlang, "crypto", "hash")
fn crypto_hash(algorithm: Atom, data: BitArray) -> BitArray

/// Erlang atom type for FFI
pub type Atom

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(binary: BitArray) -> Atom

fn sha256(data: BitArray) -> BitArray {
  crypto_hash(binary_to_atom(<<"sha256">>), data)
}

/// Base64 decode
@external(erlang, "base64", "decode")
fn base64_decode_raw(data: String) -> BitArray

fn base64_decode(data: String) -> Result(BitArray, Nil) {
  // Try to decode, return error if it fails
  let result = base64_decode_raw(data)
  case bit_array.byte_size(result) > 0 {
    True -> Ok(result)
    False -> Error(Nil)
  }
}

/// Base64 encode
@external(erlang, "base64", "encode")
fn base64_encode_raw(data: BitArray) -> BitArray

fn base64_encode(data: BitArray) -> String {
  let encoded = base64_encode_raw(data)
  case bit_array.to_string(encoded) {
    Ok(s) -> s
    Error(_) -> ""
  }
}
