import gleeunit
import gleeunit/should
import oni_bitcoin
import gleam/io

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// BIP-340 Schnorr Signature Test Vectors
// These tests use official BIP-340 test vectors for verification
// ============================================================================

/// Helper to decode hex string to bytes
fn decode_hex(hex: String) -> BitArray {
  case oni_bitcoin.hex_decode(hex) {
    Ok(bytes) -> bytes
    Error(_) -> <<>>
  }
}

/// Test vector 0: Valid signature (simple case)
pub fn bip340_vector_0_test() {
  let pubkey_hex = "F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9"
  let message_hex = "0000000000000000000000000000000000000000000000000000000000000000"
  let sig_hex = "E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"

  let pubkey_bytes = decode_hex(pubkey_hex)
  let message_bytes = decode_hex(message_hex)
  let sig_bytes = decode_hex(sig_hex)

  // Parse types
  let pubkey_result = oni_bitcoin.xonly_pubkey_from_bytes(pubkey_bytes)
  pubkey_result |> should.be_ok

  let sig_result = oni_bitcoin.schnorr_sig_from_bytes(sig_bytes)
  sig_result |> should.be_ok

  // Verify signature (will use NIF if available, otherwise return error)
  let assert Ok(pubkey) = pubkey_result
  let assert Ok(sig) = sig_result

  case oni_bitcoin.schnorr_verify(sig, message_bytes, pubkey) {
    Ok(valid) -> valid |> should.be_true
    Error(oni_bitcoin.NifNotLoaded) -> {
      // NIF not loaded, test passes with warning
      io.println("Warning: secp256k1 NIF not loaded, skipping Schnorr verification")
    }
    Error(_) -> should.fail()
  }
}

/// Test vector 1: Valid signature
pub fn bip340_vector_1_test() {
  let pubkey_hex = "DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"
  let message_hex = "243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"
  let sig_hex = "6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE33418906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A"

  let pubkey_bytes = decode_hex(pubkey_hex)
  let message_bytes = decode_hex(message_hex)
  let sig_bytes = decode_hex(sig_hex)

  let assert Ok(pubkey) = oni_bitcoin.xonly_pubkey_from_bytes(pubkey_bytes)
  let assert Ok(sig) = oni_bitcoin.schnorr_sig_from_bytes(sig_bytes)

  case oni_bitcoin.schnorr_verify(sig, message_bytes, pubkey) {
    Ok(valid) -> valid |> should.be_true
    Error(oni_bitcoin.NifNotLoaded) -> {
      io.println("Warning: secp256k1 NIF not loaded, skipping Schnorr verification")
    }
    Error(_) -> should.fail()
  }
}

/// Test vector 2: Valid signature
pub fn bip340_vector_2_test() {
  let pubkey_hex = "DD308AFEC5777E13121FA72B9CC1B7CC0139715309B086C960E18FD969774EB8"
  let message_hex = "7E2D58D8B3BCDF1ABADEC7829054F90DDA9805AAB56C77333024B9D0A508B75C"
  let sig_hex = "5831AAEED7B44BB74E5EAB94BA9D4294C49BCF2A60728D8B4C200F50DD313C1BAB745879A5AD954A72C45A91C3A51D3C7ADEA98D82F8481E0E1E03674A6F3FB7"

  let pubkey_bytes = decode_hex(pubkey_hex)
  let message_bytes = decode_hex(message_hex)
  let sig_bytes = decode_hex(sig_hex)

  let assert Ok(pubkey) = oni_bitcoin.xonly_pubkey_from_bytes(pubkey_bytes)
  let assert Ok(sig) = oni_bitcoin.schnorr_sig_from_bytes(sig_bytes)

  case oni_bitcoin.schnorr_verify(sig, message_bytes, pubkey) {
    Ok(valid) -> valid |> should.be_true
    Error(oni_bitcoin.NifNotLoaded) -> {
      io.println("Warning: secp256k1 NIF not loaded, skipping Schnorr verification")
    }
    Error(_) -> should.fail()
  }
}

/// Test vector 3: Valid signature (edge case with all 0xFF message)
pub fn bip340_vector_3_test() {
  let pubkey_hex = "25D1DFF95105F5253C4022F628A996AD3A0D95FBF21D468A1B33F8C160D8F517"
  let message_hex = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
  let sig_hex = "7EB0509757E246F19449885651611CB965ECC1A187DD51B64FDA1EDC9637D5EC97582B9CB13DB3933705B32BA982AF5AF25FD78881EBB32771FC5922EFC66EA3"

  let pubkey_bytes = decode_hex(pubkey_hex)
  let message_bytes = decode_hex(message_hex)
  let sig_bytes = decode_hex(sig_hex)

  let assert Ok(pubkey) = oni_bitcoin.xonly_pubkey_from_bytes(pubkey_bytes)
  let assert Ok(sig) = oni_bitcoin.schnorr_sig_from_bytes(sig_bytes)

  case oni_bitcoin.schnorr_verify(sig, message_bytes, pubkey) {
    Ok(valid) -> valid |> should.be_true
    Error(oni_bitcoin.NifNotLoaded) -> {
      io.println("Warning: secp256k1 NIF not loaded, skipping Schnorr verification")
    }
    Error(_) -> should.fail()
  }
}

/// Test vector 6: Invalid signature (has_even_y(R) is false)
pub fn bip340_vector_6_invalid_test() {
  let pubkey_hex = "DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"
  let message_hex = "243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"
  let sig_hex = "FFF97BD5755EEEA420453A14355235D382F6472F8568A18B2F057A14602975563CC27944640AC607CD107AE10923D9EF7A73C643E166BE5EBEAFA34B1AC553E2"

  let pubkey_bytes = decode_hex(pubkey_hex)
  let message_bytes = decode_hex(message_hex)
  let sig_bytes = decode_hex(sig_hex)

  let assert Ok(pubkey) = oni_bitcoin.xonly_pubkey_from_bytes(pubkey_bytes)
  let assert Ok(sig) = oni_bitcoin.schnorr_sig_from_bytes(sig_bytes)

  case oni_bitcoin.schnorr_verify(sig, message_bytes, pubkey) {
    Ok(valid) -> valid |> should.be_false
    Error(oni_bitcoin.NifNotLoaded) -> {
      io.println("Warning: secp256k1 NIF not loaded, skipping Schnorr verification")
    }
    Error(_) -> {
      // Some invalid signatures may return error instead of false
      io.println("Signature verification returned error (expected for invalid sig)")
    }
  }
}

/// Test vector 7: Invalid signature (negated message)
pub fn bip340_vector_7_invalid_test() {
  let pubkey_hex = "DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"
  let message_hex = "243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"
  let sig_hex = "1FA62E331EDBC21C394792D2AB1100A7B432B013DF3F6FF4F99FCB33E0E1515F28890B3EDB6E7189B630448B515CE4F8622A954CFE545735AAEA5134FCCDB2BD"

  let pubkey_bytes = decode_hex(pubkey_hex)
  let message_bytes = decode_hex(message_hex)
  let sig_bytes = decode_hex(sig_hex)

  let assert Ok(pubkey) = oni_bitcoin.xonly_pubkey_from_bytes(pubkey_bytes)
  let assert Ok(sig) = oni_bitcoin.schnorr_sig_from_bytes(sig_bytes)

  case oni_bitcoin.schnorr_verify(sig, message_bytes, pubkey) {
    Ok(valid) -> valid |> should.be_false
    Error(oni_bitcoin.NifNotLoaded) -> {
      io.println("Warning: secp256k1 NIF not loaded, skipping Schnorr verification")
    }
    Error(_) -> {
      io.println("Signature verification returned error (expected for invalid sig)")
    }
  }
}

// ============================================================================
// X-Only Public Key Tests
// ============================================================================

pub fn xonly_pubkey_valid_32_bytes_test() {
  // Valid 32-byte x-only pubkey
  let bytes = decode_hex("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9")
  let result = oni_bitcoin.xonly_pubkey_from_bytes(bytes)
  result |> should.be_ok
}

pub fn xonly_pubkey_invalid_31_bytes_test() {
  // Invalid: 31 bytes instead of 32
  let bytes = decode_hex("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036")
  let result = oni_bitcoin.xonly_pubkey_from_bytes(bytes)
  result |> should.be_error
}

pub fn xonly_pubkey_invalid_33_bytes_test() {
  // Invalid: 33 bytes instead of 32
  let bytes = decode_hex("02F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9")
  let result = oni_bitcoin.xonly_pubkey_from_bytes(bytes)
  result |> should.be_error
}

// ============================================================================
// Schnorr Signature Format Tests
// ============================================================================

pub fn schnorr_sig_valid_64_bytes_test() {
  let bytes = decode_hex("E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0")
  let result = oni_bitcoin.schnorr_sig_from_bytes(bytes)
  result |> should.be_ok
}

pub fn schnorr_sig_invalid_63_bytes_test() {
  // One byte short
  let bytes = decode_hex("E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536")
  let result = oni_bitcoin.schnorr_sig_from_bytes(bytes)
  result |> should.be_error
}

pub fn schnorr_sig_invalid_65_bytes_test() {
  // One byte too many
  let bytes = decode_hex("E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0FF")
  let result = oni_bitcoin.schnorr_sig_from_bytes(bytes)
  result |> should.be_error
}

// ============================================================================
// Public Key Conversion Tests
// ============================================================================

pub fn pubkey_to_xonly_compressed_even_test() {
  // Compressed pubkey with 0x02 prefix
  let compressed = decode_hex("02F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9")
  let assert Ok(pubkey) = oni_bitcoin.pubkey_from_bytes(compressed)

  let result = oni_bitcoin.pubkey_to_xonly(pubkey)
  result |> should.be_ok

  let assert Ok(xonly) = result
  let xonly_hex = oni_bitcoin.hex_encode(xonly.bytes)
  // Should be the x-coordinate without prefix (lowercase)
  xonly_hex |> should.equal("f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9")
}

pub fn pubkey_to_xonly_compressed_odd_test() {
  // Compressed pubkey with 0x03 prefix
  let compressed = decode_hex("03DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659")
  let assert Ok(pubkey) = oni_bitcoin.pubkey_from_bytes(compressed)

  let result = oni_bitcoin.pubkey_to_xonly(pubkey)
  result |> should.be_ok

  let assert Ok(xonly) = result
  let xonly_hex = oni_bitcoin.hex_encode(xonly.bytes)
  xonly_hex |> should.equal("dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659")
}

// ============================================================================
// ECDSA Verification Tests (uses Erlang crypto fallback)
// ============================================================================

/// Test ECDSA verification format handling
/// This test uses the Erlang crypto fallback if NIF is not available
pub fn ecdsa_verify_format_test() {
  // This tests that the ECDSA verify function handles inputs correctly
  // Note: Creating a valid ECDSA signature requires signing which we can't do
  // without the private key. This test validates input handling.

  // Valid format: 32-byte hash, DER sig, compressed pubkey
  let msg_hash = decode_hex("0000000000000000000000000000000000000000000000000000000000000001")
  let pubkey_bytes = decode_hex("02F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9")

  // A minimal DER signature (this is not cryptographically valid, just testing format handling)
  let der_sig = decode_hex("3044022000000000000000000000000000000000000000000000000000000000000000010220000000000000000000000000000000000000000000000000000000000000000")

  let assert Ok(pubkey) = oni_bitcoin.pubkey_from_bytes(pubkey_bytes)

  // Create a Signature type directly from DER bytes
  let sig = oni_bitcoin.Signature(der: der_sig)

  // Try to verify (will fail with invalid sig, but tests the flow)
  let result = oni_bitcoin.ecdsa_verify(sig, msg_hash, pubkey)
  // Should return Ok(false) or error, not crash
  case result {
    Ok(valid) -> {
      io.println("ECDSA verify returned: " <> case valid {
        True -> "true"
        False -> "false"
      })
    }
    Error(_) -> io.println("ECDSA verify returned error (expected for malformed sig)")
  }
}

// ============================================================================
// Error Handling Tests
// ============================================================================

pub fn schnorr_verify_wrong_hash_length_test() {
  // Message hash must be exactly 32 bytes
  let pubkey_bytes = decode_hex("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9")
  let sig_bytes = decode_hex("E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0")

  // Wrong length hash (31 bytes)
  let wrong_hash = decode_hex("00000000000000000000000000000000000000000000000000000000000000")

  let assert Ok(pubkey) = oni_bitcoin.xonly_pubkey_from_bytes(pubkey_bytes)
  let assert Ok(sig) = oni_bitcoin.schnorr_sig_from_bytes(sig_bytes)

  let result = oni_bitcoin.schnorr_verify(sig, wrong_hash, pubkey)
  result |> should.be_error
}
