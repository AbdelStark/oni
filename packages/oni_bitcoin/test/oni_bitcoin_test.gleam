import gleeunit
import gleeunit/should
import oni_bitcoin

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Hash Tests
// ============================================================================

pub fn hash256_from_bytes_valid_test() {
  let bytes = <<
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
  >>
  let result = oni_bitcoin.hash256_from_bytes(bytes)
  should.be_ok(result)
}

pub fn hash256_from_bytes_invalid_test() {
  let bytes = <<0x00, 0x01, 0x02>>
  let result = oni_bitcoin.hash256_from_bytes(bytes)
  should.be_error(result)
}

pub fn txid_from_bytes_valid_test() {
  let bytes = <<
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
  >>
  let result = oni_bitcoin.txid_from_bytes(bytes)
  should.be_ok(result)
}

// ============================================================================
// Hex Encoding Tests
// ============================================================================

pub fn hex_encode_test() {
  let bytes = <<0xDE, 0xAD, 0xBE, 0xEF>>
  let hex = oni_bitcoin.hex_encode(bytes)
  hex |> should.equal("deadbeef")
}

pub fn hex_decode_valid_test() {
  let result = oni_bitcoin.hex_decode("deadbeef")
  result |> should.be_ok
  let assert Ok(bytes) = result
  bytes |> should.equal(<<0xDE, 0xAD, 0xBE, 0xEF>>)
}

pub fn hex_decode_invalid_odd_length_test() {
  let result = oni_bitcoin.hex_decode("abc")
  result |> should.be_error
}

pub fn hex_decode_invalid_chars_test() {
  let result = oni_bitcoin.hex_decode("ghij")
  result |> should.be_error
}

pub fn hex_roundtrip_test() {
  let original = <<0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef>>
  let hex = oni_bitcoin.hex_encode(original)
  let assert Ok(decoded) = oni_bitcoin.hex_decode(hex)
  decoded |> should.equal(original)
}

// ============================================================================
// Amount Tests
// ============================================================================

pub fn amount_from_sats_valid_test() {
  let result = oni_bitcoin.amount_from_sats(100_000_000)
  should.be_ok(result)
}

pub fn amount_from_sats_negative_test() {
  let result = oni_bitcoin.amount_from_sats(-1)
  should.be_error(result)
}

pub fn amount_from_sats_max_test() {
  let result = oni_bitcoin.amount_from_sats(oni_bitcoin.max_satoshis)
  should.be_ok(result)
}

pub fn amount_from_sats_exceeds_max_test() {
  let result = oni_bitcoin.amount_from_sats(oni_bitcoin.max_satoshis + 1)
  should.be_error(result)
}

pub fn amount_add_test() {
  let assert Ok(a) = oni_bitcoin.amount_from_sats(100)
  let assert Ok(b) = oni_bitcoin.amount_from_sats(200)
  let result = oni_bitcoin.amount_add(a, b)
  let assert Ok(sum) = result
  oni_bitcoin.amount_to_sats(sum) |> should.equal(300)
}

pub fn amount_sub_test() {
  let assert Ok(a) = oni_bitcoin.amount_from_sats(500)
  let assert Ok(b) = oni_bitcoin.amount_from_sats(200)
  let result = oni_bitcoin.amount_sub(a, b)
  let assert Ok(diff) = result
  oni_bitcoin.amount_to_sats(diff) |> should.equal(300)
}

pub fn amount_sub_negative_test() {
  let assert Ok(a) = oni_bitcoin.amount_from_sats(100)
  let assert Ok(b) = oni_bitcoin.amount_from_sats(200)
  let result = oni_bitcoin.amount_sub(a, b)
  should.be_error(result)
}

// ============================================================================
// CompactSize Tests
// ============================================================================

pub fn compact_size_encode_small_test() {
  let result = oni_bitcoin.compact_size_encode(252)
  result |> should.equal(<<252:8>>)
}

pub fn compact_size_encode_fd_test() {
  let result = oni_bitcoin.compact_size_encode(253)
  result |> should.equal(<<0xFD:8, 253:16-little>>)
}

pub fn compact_size_encode_fe_test() {
  let result = oni_bitcoin.compact_size_encode(0x10000)
  result |> should.equal(<<0xFE:8, 0x10000:32-little>>)
}

pub fn compact_size_decode_small_test() {
  let result = oni_bitcoin.compact_size_decode(<<42:8, 0xFF:8>>)
  result |> should.be_ok
  let assert Ok(#(value, rest)) = result
  value |> should.equal(42)
  rest |> should.equal(<<0xFF:8>>)
}

pub fn compact_size_decode_fd_test() {
  let result = oni_bitcoin.compact_size_decode(<<0xFD:8, 300:16-little, 0xFF:8>>)
  result |> should.be_ok
  let assert Ok(#(value, rest)) = result
  value |> should.equal(300)
  rest |> should.equal(<<0xFF:8>>)
}

pub fn compact_size_roundtrip_test() {
  let values = [0, 1, 252, 253, 0xFFFF, 0x10000, 0xFFFFFFFF]
  use val <- list.each(values)
  let encoded = oni_bitcoin.compact_size_encode(val)
  let assert Ok(#(decoded, <<>>)) = oni_bitcoin.compact_size_decode(encoded)
  decoded |> should.equal(val)
}

// ============================================================================
// Script Tests
// ============================================================================

pub fn script_from_bytes_test() {
  let bytes = <<0x76, 0xa9, 0x14>>  // OP_DUP OP_HASH160 PUSH(20)
  let script = oni_bitcoin.script_from_bytes(bytes)
  oni_bitcoin.script_size(script) |> should.equal(3)
  oni_bitcoin.script_is_empty(script) |> should.be_false
}

pub fn script_empty_test() {
  let script = oni_bitcoin.script_from_bytes(<<>>)
  oni_bitcoin.script_is_empty(script) |> should.be_true
}

// ============================================================================
// OutPoint Tests
// ============================================================================

pub fn outpoint_null_test() {
  let null = oni_bitcoin.outpoint_null()
  oni_bitcoin.outpoint_is_null(null) |> should.be_true
}

// ============================================================================
// Hash Function Tests
// ============================================================================

pub fn sha256_test() {
  // SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  let input = <<"abc":utf8>>
  let result = oni_bitcoin.sha256(input)
  let hex = oni_bitcoin.hex_encode(result)
  hex |> should.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

pub fn sha256d_test() {
  // SHA256d("abc") = 4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358
  let input = <<"abc":utf8>>
  let result = oni_bitcoin.sha256d(input)
  let hex = oni_bitcoin.hex_encode(result)
  hex |> should.equal("4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358")
}

// ============================================================================
// RIPEMD160 and Hash160 Tests
// ============================================================================

pub fn ripemd160_test() {
  // RIPEMD160("abc") = 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
  let input = <<"abc":utf8>>
  let result = oni_bitcoin.ripemd160(input)
  let hex = oni_bitcoin.hex_encode(result)
  hex |> should.equal("8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
}

pub fn hash160_test() {
  // Hash160("abc") = RIPEMD160(SHA256("abc"))
  let input = <<"abc":utf8>>
  let result = oni_bitcoin.hash160(input)
  // Should be 20 bytes
  result |> should.equal(oni_bitcoin.ripemd160(oni_bitcoin.sha256(input)))
}

// ============================================================================
// Public Key Tests
// ============================================================================

pub fn pubkey_compressed_even_test() {
  // Compressed pubkey with 0x02 prefix (33 bytes)
  let bytes = <<
    0x02,
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
    0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
    0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
    0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98
  >>
  let result = oni_bitcoin.pubkey_from_bytes(bytes)
  should.be_ok(result)
  let assert Ok(pubkey) = result
  oni_bitcoin.pubkey_is_compressed(pubkey) |> should.be_true
}

pub fn pubkey_compressed_odd_test() {
  // Compressed pubkey with 0x03 prefix (33 bytes)
  let bytes = <<
    0x03,
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
    0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
    0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
    0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98
  >>
  let result = oni_bitcoin.pubkey_from_bytes(bytes)
  should.be_ok(result)
  let assert Ok(pubkey) = result
  oni_bitcoin.pubkey_is_compressed(pubkey) |> should.be_true
}

pub fn pubkey_uncompressed_test() {
  // Uncompressed pubkey with 0x04 prefix (65 bytes)
  let bytes = <<
    0x04,
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
    0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
    0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
    0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
    0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65,
    0x5D, 0xA4, 0xFB, 0xFC, 0x0E, 0x11, 0x08, 0xA8,
    0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19,
    0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10, 0xD4, 0xB8
  >>
  let result = oni_bitcoin.pubkey_from_bytes(bytes)
  should.be_ok(result)
  let assert Ok(pubkey) = result
  oni_bitcoin.pubkey_is_compressed(pubkey) |> should.be_false
}

pub fn pubkey_invalid_prefix_test() {
  // Invalid prefix 0x05
  let bytes = <<
    0x05,
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
    0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
    0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
    0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98
  >>
  let result = oni_bitcoin.pubkey_from_bytes(bytes)
  should.be_error(result)
}

pub fn pubkey_wrong_length_test() {
  // Wrong length (30 bytes instead of 33)
  let bytes = <<
    0x02,
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
    0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
    0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
    0x59, 0xF2, 0x81, 0x5B, 0x16
  >>
  let result = oni_bitcoin.pubkey_from_bytes(bytes)
  should.be_error(result)
}

pub fn xonly_pubkey_valid_test() {
  // X-only pubkey (32 bytes)
  let bytes = <<
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
    0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
    0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
    0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98
  >>
  let result = oni_bitcoin.xonly_pubkey_from_bytes(bytes)
  should.be_ok(result)
}

pub fn xonly_pubkey_invalid_length_test() {
  let bytes = <<0x01, 0x02, 0x03>>
  let result = oni_bitcoin.xonly_pubkey_from_bytes(bytes)
  should.be_error(result)
}

pub fn pubkey_to_xonly_test() {
  // Convert compressed to x-only
  let compressed = <<
    0x02,
    0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
    0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
    0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
    0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98
  >>
  let assert Ok(pubkey) = oni_bitcoin.pubkey_from_bytes(compressed)
  let result = oni_bitcoin.pubkey_to_xonly(pubkey)
  should.be_ok(result)
}

// ============================================================================
// Signature Tests
// ============================================================================

pub fn schnorr_sig_valid_test() {
  // 64-byte Schnorr signature
  let bytes = <<
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
    0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f
  >>
  let result = oni_bitcoin.schnorr_sig_from_bytes(bytes)
  should.be_ok(result)
}

pub fn schnorr_sig_invalid_length_test() {
  let bytes = <<0x00, 0x01, 0x02, 0x03>>
  let result = oni_bitcoin.schnorr_sig_from_bytes(bytes)
  should.be_error(result)
}

// ============================================================================
// Imports needed
// ============================================================================
import gleam/list
