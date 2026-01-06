// descriptors_test.gleam - Tests for output script descriptors

import descriptors
import gleam/string

// ============================================================================
// Basic Parsing Tests
// ============================================================================

pub fn parse_pkh_descriptor_test() {
  let desc =
    "pkh(02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5)"

  let result = descriptors.parse(desc)

  case result {
    Ok(descriptors.PkhDescriptor(descriptors.RawPubKey(_, True))) -> Nil
    _ -> panic as "Should parse pkh descriptor"
  }
}

pub fn parse_wpkh_descriptor_test() {
  let desc =
    "wpkh(02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5)"

  let result = descriptors.parse(desc)

  case result {
    Ok(descriptors.WpkhDescriptor(descriptors.RawPubKey(_, True))) -> Nil
    _ -> panic as "Should parse wpkh descriptor"
  }
}

pub fn parse_unknown_type_fails_test() {
  let desc = "unknown(something)"

  let result = descriptors.parse(desc)

  let assert True = result == Error(descriptors.UnknownDescriptorType)
  Nil
}

pub fn parse_missing_paren_fails_test() {
  let desc =
    "pkh(02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

  let result = descriptors.parse(desc)

  let assert True = result == Error(descriptors.MissingClosingParen)
  Nil
}

pub fn parse_invalid_key_fails_test() {
  let desc = "pkh(notavalidkey)"

  let result = descriptors.parse(desc)

  let assert True = result == Error(descriptors.InvalidKey)
  Nil
}

// ============================================================================
// Checksum Tests
// ============================================================================

pub fn compute_checksum_deterministic_test() {
  let desc =
    "pkh(02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5)"

  let cs1 = descriptors.compute_checksum(desc)
  let cs2 = descriptors.compute_checksum(desc)

  let assert True = cs1 == cs2
  Nil
}

pub fn to_string_with_checksum_test() {
  let desc =
    "pkh(02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5)"

  case descriptors.parse(desc) {
    Ok(parsed) -> {
      let with_checksum = descriptors.to_string_with_checksum(parsed)
      // Should contain #
      let assert True = string.contains(with_checksum, "#")
      Nil
    }
    Error(_) -> panic as "Should parse descriptor"
  }
}

// ============================================================================
// Roundtrip Tests
// ============================================================================

pub fn pkh_roundtrip_test() {
  let original =
    "pkh(02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5)"

  case descriptors.parse(original) {
    Ok(parsed) -> {
      let serialized = descriptors.to_string(parsed)
      case descriptors.parse(serialized) {
        Ok(_) -> Nil
        Error(_) -> panic as "Should roundtrip pkh descriptor"
      }
    }
    Error(_) -> panic as "Should parse original"
  }
}

// ============================================================================
// Key Parsing Tests
// ============================================================================

pub fn parse_compressed_pubkey_test() {
  let hex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

  let result = descriptors.parse_key(hex)

  case result {
    Ok(descriptors.RawPubKey(_, compressed)) -> {
      let assert True = compressed == True
      Nil
    }
    _ -> panic as "Should parse compressed pubkey"
  }
}

pub fn parse_wif_key_test() {
  let wif = "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn"

  let result = descriptors.parse_key(wif)

  case result {
    Ok(descriptors.WifKey(w)) -> {
      let assert True = w == wif
      Nil
    }
    _ -> panic as "Should parse WIF key"
  }
}
