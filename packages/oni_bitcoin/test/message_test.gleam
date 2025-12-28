// message_test.gleam - Tests for Bitcoin message signing

import gleam/bit_array
import gleam/result
import message.{
  AddressMismatch, InvalidSignatureFormat, InvalidSignatureHeader,
  InvalidSignatureLength, P2PKH, P2SHP2WPKH, P2WPKH,
}

// ============================================================================
// Message Hash Tests
// ============================================================================

pub fn message_hash_deterministic_test() {
  let msg = "Hello, Bitcoin!"

  let hash1 = message.message_hash(msg)
  let hash2 = message.message_hash(msg)

  let assert True = hash1 == hash2
}

pub fn message_hash_different_messages_test() {
  let hash1 = message.message_hash("Hello")
  let hash2 = message.message_hash("World")

  let assert True = hash1 != hash2
}

pub fn message_preimage_includes_magic_test() {
  let msg = "Test"
  let preimage = message.message_preimage(msg)

  // Preimage should start with magic bytes
  // Magic: "\x18Bitcoin Signed Message:\n"
  case preimage {
    <<24, 66, 105, 116, 99, 111, 105, 110, _rest:bits>> -> Nil
    _ -> panic as "Preimage should start with magic bytes"
  }
}

// ============================================================================
// Signature Parsing Tests
// ============================================================================

pub fn parse_valid_signature_test() {
  // 65 bytes: 1 header + 32 r + 32 s
  let sig_bytes = <<31, 0:256, 1:256>>  // Header 31 = compressed P2PKH
  let sig_base64 = base64_encode(sig_bytes)

  let result = message.parse_signature(sig_base64)

  case result {
    Ok(_sig) -> Nil
    Error(_) -> panic as "Should parse valid signature"
  }
}

pub fn parse_invalid_length_signature_test() {
  // Only 64 bytes (missing header)
  let sig_bytes = <<0:256, 1:256>>
  let sig_base64 = base64_encode(sig_bytes)

  let result = message.parse_signature(sig_base64)

  let assert True = result == Error(InvalidSignatureLength)
}

pub fn get_signature_header_test() {
  let sig = message.MessageSignature(<<31, 0:256, 1:256>>)

  let result = message.get_signature_header(sig)

  let assert True = result == Ok(31)
}

pub fn get_signature_r_test() {
  let r_bytes = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
                  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32>>
  let sig = message.MessageSignature(<<31, r_bytes:bits, 0:256>>)

  let result = message.get_signature_r(sig)

  let assert True = result == Ok(r_bytes)
}

// ============================================================================
// Address Type Detection Tests
// ============================================================================

pub fn address_type_uncompressed_p2pkh_test() {
  // Headers 27-30 are uncompressed P2PKH
  let result = message.address_type_from_header(27)

  case result {
    Ok(#(P2PKH, False, 0)) -> Nil
    _ -> panic as "Should detect uncompressed P2PKH"
  }
}

pub fn address_type_compressed_p2pkh_test() {
  // Headers 31-34 are compressed P2PKH
  let result = message.address_type_from_header(31)

  case result {
    Ok(#(P2PKH, True, 0)) -> Nil
    _ -> panic as "Should detect compressed P2PKH"
  }
}

pub fn address_type_p2sh_p2wpkh_test() {
  // Headers 35-38 are P2SH-P2WPKH
  let result = message.address_type_from_header(35)

  case result {
    Ok(#(P2SHP2WPKH, True, 0)) -> Nil
    _ -> panic as "Should detect P2SH-P2WPKH"
  }
}

pub fn address_type_p2wpkh_test() {
  // Headers 39-42 are P2WPKH
  let result = message.address_type_from_header(39)

  case result {
    Ok(#(P2WPKH, True, 0)) -> Nil
    _ -> panic as "Should detect P2WPKH"
  }
}

pub fn address_type_invalid_header_test() {
  // Header 99 is invalid
  let result = message.address_type_from_header(99)

  let assert True = result == Error(InvalidSignatureHeader)
}

// ============================================================================
// Verification Context Tests
// ============================================================================

pub fn prepare_verification_valid_test() {
  // Valid P2PKH signature format
  let sig_bytes = <<31, 0:256, 1:256>>
  let sig_base64 = base64_encode(sig_bytes)

  let result = message.prepare_verification(
    "Test message",
    sig_base64,
    "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
  )

  case result {
    Ok(ctx) -> {
      let assert True = ctx.address == "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
      let assert True = ctx.compressed == True
    }
    Error(_) -> panic as "Should prepare verification context"
  }
}

pub fn prepare_verification_address_mismatch_test() {
  // P2PKH signature (header 31) but bech32 address
  let sig_bytes = <<31, 0:256, 1:256>>
  let sig_base64 = base64_encode(sig_bytes)

  let result = message.prepare_verification(
    "Test message",
    sig_base64,
    "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",  // P2WPKH address
  )

  let assert True = result == Error(AddressMismatch)
}

// ============================================================================
// Signing Context Tests
// ============================================================================

pub fn prepare_signing_test() {
  let ctx = message.prepare_signing("Test message", P2PKH, True)

  let assert True = ctx.message == "Test message"
  let assert True = ctx.compressed == True
}

pub fn calculate_signature_header_test() {
  // Compressed P2PKH with recovery ID 0
  let header = message.calculate_signature_header(P2PKH, True, 0)
  let assert True = header == 31

  // Uncompressed P2PKH with recovery ID 1
  let header2 = message.calculate_signature_header(P2PKH, False, 1)
  let assert True = header2 == 28
}

// ============================================================================
// Message Validation Tests
// ============================================================================

pub fn validate_message_normal_test() {
  let result = message.validate_message("Normal message")

  let assert True = result == Ok(Nil)
}

pub fn validate_message_empty_test() {
  let result = message.validate_message("")

  let assert True = result == Ok(Nil)
}

// ============================================================================
// Formatting Tests
// ============================================================================

pub fn format_signed_message_test() {
  let sig = message.MessageSignature(<<31, 0:256, 1:256>>)

  let formatted = message.format_signed_message(
    "Hello, Bitcoin!",
    "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
    sig,
  )

  // Should contain the expected sections
  let assert True = string_contains(formatted, "BEGIN BITCOIN SIGNED MESSAGE")
  let assert True = string_contains(formatted, "Hello, Bitcoin!")
  let assert True = string_contains(formatted, "BEGIN SIGNATURE")
  let assert True = string_contains(formatted, "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2")
  let assert True = string_contains(formatted, "END BITCOIN SIGNED MESSAGE")
}

pub fn parse_formatted_message_test() {
  let sig = message.MessageSignature(<<31, 0:256, 1:256>>)

  let formatted = message.format_signed_message(
    "Test",
    "1TestAddr",
    sig,
  )

  let result = message.parse_signed_message(formatted)

  case result {
    Ok(#(msg, addr, _sig)) -> {
      let assert True = msg == "Test"
      let assert True = addr == "1TestAddr"
    }
    Error(_) -> panic as "Should parse formatted message"
  }
}

// ============================================================================
// Signature Creation Tests
// ============================================================================

pub fn create_signature_valid_test() {
  let r = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
            17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32>>
  let s = <<33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
            49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64>>

  let result = message.create_signature(31, r, s)

  case result {
    Ok(sig) -> {
      // Verify it's 65 bytes
      let assert True = bit_array.byte_size(sig.bytes) == 65
    }
    Error(_) -> panic as "Should create valid signature"
  }
}

pub fn create_signature_invalid_r_length_test() {
  let r = <<1, 2, 3>>  // Too short
  let s = <<0:256>>

  let result = message.create_signature(31, r, s)

  let assert True = result == Error(InvalidSignatureFormat)
}

// ============================================================================
// Helper Functions
// ============================================================================

@external(erlang, "base64", "encode")
fn base64_encode_raw(data: BitArray) -> BitArray

fn base64_encode(data: BitArray) -> String {
  let encoded = base64_encode_raw(data)
  case bit_array.to_string(encoded) {
    Ok(s) -> s
    Error(_) -> ""
  }
}

fn string_contains(haystack: String, needle: String) -> Bool {
  case string_split_once(haystack, needle) {
    Ok(_) -> True
    Error(_) -> False
  }
}

import gleam/string

fn string_split_once(s: String, sep: String) -> Result(#(String, String), Nil) {
  string.split_once(s, sep)
}
