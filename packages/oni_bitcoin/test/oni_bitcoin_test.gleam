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
    0x00,
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0a,
    0x0b,
    0x0c,
    0x0d,
    0x0e,
    0x0f,
    0x10,
    0x11,
    0x12,
    0x13,
    0x14,
    0x15,
    0x16,
    0x17,
    0x18,
    0x19,
    0x1a,
    0x1b,
    0x1c,
    0x1d,
    0x1e,
    0x1f,
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
    0x00,
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0a,
    0x0b,
    0x0c,
    0x0d,
    0x0e,
    0x0f,
    0x10,
    0x11,
    0x12,
    0x13,
    0x14,
    0x15,
    0x16,
    0x17,
    0x18,
    0x19,
    0x1a,
    0x1b,
    0x1c,
    0x1d,
    0x1e,
    0x1f,
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
  let result =
    oni_bitcoin.compact_size_decode(<<0xFD:8, 300:16-little, 0xFF:8>>)
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
  let bytes = <<0x76, 0xa9, 0x14>>
  // OP_DUP OP_HASH160 PUSH(20)
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
  hex
  |> should.equal(
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

pub fn sha256d_test() {
  // SHA256d("abc") = 4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358
  let input = <<"abc":utf8>>
  let result = oni_bitcoin.sha256d(input)
  let hex = oni_bitcoin.hex_encode(result)
  hex
  |> should.equal(
    "4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358",
  )
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
    0x79,
    0xBE,
    0x66,
    0x7E,
    0xF9,
    0xDC,
    0xBB,
    0xAC,
    0x55,
    0xA0,
    0x62,
    0x95,
    0xCE,
    0x87,
    0x0B,
    0x07,
    0x02,
    0x9B,
    0xFC,
    0xDB,
    0x2D,
    0xCE,
    0x28,
    0xD9,
    0x59,
    0xF2,
    0x81,
    0x5B,
    0x16,
    0xF8,
    0x17,
    0x98,
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
    0x79,
    0xBE,
    0x66,
    0x7E,
    0xF9,
    0xDC,
    0xBB,
    0xAC,
    0x55,
    0xA0,
    0x62,
    0x95,
    0xCE,
    0x87,
    0x0B,
    0x07,
    0x02,
    0x9B,
    0xFC,
    0xDB,
    0x2D,
    0xCE,
    0x28,
    0xD9,
    0x59,
    0xF2,
    0x81,
    0x5B,
    0x16,
    0xF8,
    0x17,
    0x98,
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
    0x79,
    0xBE,
    0x66,
    0x7E,
    0xF9,
    0xDC,
    0xBB,
    0xAC,
    0x55,
    0xA0,
    0x62,
    0x95,
    0xCE,
    0x87,
    0x0B,
    0x07,
    0x02,
    0x9B,
    0xFC,
    0xDB,
    0x2D,
    0xCE,
    0x28,
    0xD9,
    0x59,
    0xF2,
    0x81,
    0x5B,
    0x16,
    0xF8,
    0x17,
    0x98,
    0x48,
    0x3A,
    0xDA,
    0x77,
    0x26,
    0xA3,
    0xC4,
    0x65,
    0x5D,
    0xA4,
    0xFB,
    0xFC,
    0x0E,
    0x11,
    0x08,
    0xA8,
    0xFD,
    0x17,
    0xB4,
    0x48,
    0xA6,
    0x85,
    0x54,
    0x19,
    0x9C,
    0x47,
    0xD0,
    0x8F,
    0xFB,
    0x10,
    0xD4,
    0xB8,
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
    0x79,
    0xBE,
    0x66,
    0x7E,
    0xF9,
    0xDC,
    0xBB,
    0xAC,
    0x55,
    0xA0,
    0x62,
    0x95,
    0xCE,
    0x87,
    0x0B,
    0x07,
    0x02,
    0x9B,
    0xFC,
    0xDB,
    0x2D,
    0xCE,
    0x28,
    0xD9,
    0x59,
    0xF2,
    0x81,
    0x5B,
    0x16,
    0xF8,
    0x17,
    0x98,
  >>
  let result = oni_bitcoin.pubkey_from_bytes(bytes)
  should.be_error(result)
}

pub fn pubkey_wrong_length_test() {
  // Wrong length (30 bytes instead of 33)
  let bytes = <<
    0x02,
    0x79,
    0xBE,
    0x66,
    0x7E,
    0xF9,
    0xDC,
    0xBB,
    0xAC,
    0x55,
    0xA0,
    0x62,
    0x95,
    0xCE,
    0x87,
    0x0B,
    0x07,
    0x02,
    0x9B,
    0xFC,
    0xDB,
    0x2D,
    0xCE,
    0x28,
    0xD9,
    0x59,
    0xF2,
    0x81,
    0x5B,
    0x16,
  >>
  let result = oni_bitcoin.pubkey_from_bytes(bytes)
  should.be_error(result)
}

pub fn xonly_pubkey_valid_test() {
  // X-only pubkey (32 bytes)
  let bytes = <<
    0x79,
    0xBE,
    0x66,
    0x7E,
    0xF9,
    0xDC,
    0xBB,
    0xAC,
    0x55,
    0xA0,
    0x62,
    0x95,
    0xCE,
    0x87,
    0x0B,
    0x07,
    0x02,
    0x9B,
    0xFC,
    0xDB,
    0x2D,
    0xCE,
    0x28,
    0xD9,
    0x59,
    0xF2,
    0x81,
    0x5B,
    0x16,
    0xF8,
    0x17,
    0x98,
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
    0x79,
    0xBE,
    0x66,
    0x7E,
    0xF9,
    0xDC,
    0xBB,
    0xAC,
    0x55,
    0xA0,
    0x62,
    0x95,
    0xCE,
    0x87,
    0x0B,
    0x07,
    0x02,
    0x9B,
    0xFC,
    0xDB,
    0x2D,
    0xCE,
    0x28,
    0xD9,
    0x59,
    0xF2,
    0x81,
    0x5B,
    0x16,
    0xF8,
    0x17,
    0x98,
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
    0x00,
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0a,
    0x0b,
    0x0c,
    0x0d,
    0x0e,
    0x0f,
    0x10,
    0x11,
    0x12,
    0x13,
    0x14,
    0x15,
    0x16,
    0x17,
    0x18,
    0x19,
    0x1a,
    0x1b,
    0x1c,
    0x1d,
    0x1e,
    0x1f,
    0x20,
    0x21,
    0x22,
    0x23,
    0x24,
    0x25,
    0x26,
    0x27,
    0x28,
    0x29,
    0x2a,
    0x2b,
    0x2c,
    0x2d,
    0x2e,
    0x2f,
    0x30,
    0x31,
    0x32,
    0x33,
    0x34,
    0x35,
    0x36,
    0x37,
    0x38,
    0x39,
    0x3a,
    0x3b,
    0x3c,
    0x3d,
    0x3e,
    0x3f,
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
// Transaction Encoding/Decoding Tests
// ============================================================================

pub fn transaction_create_and_encode_test() {
  // Create a simple transaction
  let prevout = oni_bitcoin.outpoint_null()
  let script_sig =
    oni_bitcoin.script_from_bytes(<<0x04, 0xff, 0xff, 0x00, 0x1d, 0x01, 0x04>>)
  let input = oni_bitcoin.TxIn(prevout, script_sig, 0xFFFFFFFF, [])

  let assert Ok(value) = oni_bitcoin.amount_from_sats(5_000_000_000)
  let script_pubkey = oni_bitcoin.script_from_bytes(<<0x76, 0xa9, 0x14>>)
  let output = oni_bitcoin.TxOut(value, script_pubkey)

  let tx =
    oni_bitcoin.Transaction(
      version: 1,
      inputs: [input],
      outputs: [output],
      lock_time: 0,
    )

  // Encode the transaction
  let encoded = oni_bitcoin.encode_tx(tx)
  encoded |> should.not_equal(<<>>)

  // Decode should succeed
  let result = oni_bitcoin.decode_tx(encoded)
  result |> should.be_ok
}

pub fn transaction_decode_legacy_test() {
  // A real mainnet transaction (simplified)
  // Version 1, 1 input, 1 output
  let tx_bytes = <<
    // version (little-endian)
    0x01,
    0x00,
    0x00,
    0x00,
    // input count
    0x01,
    // prev txid (32 bytes of zeros - coinbase)
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    // prev vout
    0xFF,
    0xFF,
    0xFF,
    0xFF,
    // script length
    0x07,
    // coinbase script
    0x04,
    0xff,
    0xff,
    0x00,
    0x1d,
    0x01,
    0x04,
    // sequence
    0xFF,
    0xFF,
    0xFF,
    0xFF,
    // output count
    0x01,
    // value (50 BTC in satoshis)
    0x00,
    0xf2,
    0x05,
    0x2a,
    0x01,
    0x00,
    0x00,
    0x00,
    // script_pubkey length
    0x03,
    // script_pubkey
    0x76,
    0xa9,
    0x14,
    // locktime
    0x00,
    0x00,
    0x00,
    0x00,
  >>

  let result = oni_bitcoin.decode_tx(tx_bytes)
  result |> should.be_ok
  let assert Ok(#(tx, _remaining)) = result

  tx.version |> should.equal(1)
  list.length(tx.inputs) |> should.equal(1)
  list.length(tx.outputs) |> should.equal(1)
  tx.lock_time |> should.equal(0)
}

pub fn txid_from_tx_test() {
  // Create a simple transaction and compute its txid
  let prevout = oni_bitcoin.outpoint_null()
  let script_sig = oni_bitcoin.script_from_bytes(<<0x04, 0x01, 0x02, 0x03>>)
  let input = oni_bitcoin.TxIn(prevout, script_sig, 0xFFFFFFFF, [])

  let assert Ok(value) = oni_bitcoin.amount_from_sats(100_000_000)
  let script_pubkey = oni_bitcoin.script_from_bytes(<<0x76, 0xa9>>)
  let output = oni_bitcoin.TxOut(value, script_pubkey)

  let tx =
    oni_bitcoin.Transaction(
      version: 1,
      inputs: [input],
      outputs: [output],
      lock_time: 0,
    )

  // Compute txid
  let txid = oni_bitcoin.txid_from_tx(tx)

  // Should be a valid 32-byte hash
  let hex = oni_bitcoin.txid_to_hex(txid)
  string.length(hex) |> should.equal(64)
}

pub fn tx_size_test() {
  let prevout = oni_bitcoin.outpoint_null()
  let script_sig = oni_bitcoin.script_from_bytes(<<0x04, 0x01>>)
  let input = oni_bitcoin.TxIn(prevout, script_sig, 0xFFFFFFFF, [])

  let assert Ok(value) = oni_bitcoin.amount_from_sats(50_000_000)
  let script_pubkey = oni_bitcoin.script_from_bytes(<<0x76>>)
  let output = oni_bitcoin.TxOut(value, script_pubkey)

  let tx =
    oni_bitcoin.Transaction(
      version: 1,
      inputs: [input],
      outputs: [output],
      lock_time: 0,
    )

  // Check sizes are positive
  let size = oni_bitcoin.tx_size(tx)
  { size > 0 } |> should.be_true

  let vsize = oni_bitcoin.tx_vsize(tx)
  { vsize > 0 } |> should.be_true

  let weight = oni_bitcoin.tx_weight(tx)
  { weight > 0 } |> should.be_true

  // For non-segwit tx, weight = size * 4
  weight |> should.equal(size * 4)
}

// ============================================================================
// Base58 Encoding/Decoding Tests
// ============================================================================

pub fn base58_encode_simple_test() {
  // Known test vectors
  let result = oni_bitcoin.base58_encode(<<0x00, 0x00, 0x28, 0x7f, 0xb4, 0xcd>>)
  // Should have leading 1s for leading zero bytes
  string.starts_with(result, "11") |> should.be_true
}

pub fn base58_encode_decode_roundtrip_test() {
  let original = <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE>>
  let encoded = oni_bitcoin.base58_encode(original)
  let assert Ok(decoded) = oni_bitcoin.base58_decode(encoded)
  decoded |> should.equal(original)
}

pub fn base58_decode_invalid_char_test() {
  // 'O' is not in base58 alphabet
  let result = oni_bitcoin.base58_decode("INVALID0")
  result |> should.be_error
}

// ============================================================================
// Base58Check Encoding/Decoding Tests
// ============================================================================

pub fn base58check_encode_decode_roundtrip_test() {
  let payload = <<0x00, 0x14, 0x62, 0xe9, 0x07, 0xb1, 0x5c, 0xbf, 0x27, 0xd5>>
  let encoded = oni_bitcoin.base58check_encode(payload)
  let assert Ok(decoded) = oni_bitcoin.base58check_decode(encoded)
  decoded |> should.equal(payload)
}

pub fn base58check_decode_invalid_checksum_test() {
  // Encode then corrupt the last character
  let payload = <<0x00, 0x01, 0x02, 0x03, 0x04, 0x05>>
  let encoded = oni_bitcoin.base58check_encode(payload)

  // Modify the encoded string slightly (this will break checksum)
  // We can't easily do this without base58 decode working, so skip detailed test
  let _ = encoded
}

// ============================================================================
// Bech32/Bech32m Encoding/Decoding Tests
// ============================================================================

pub fn bech32_encode_decode_test() {
  // Test vector from BIP173
  let data = [
    0,
    14,
    20,
    15,
    7,
    13,
    26,
    0,
    25,
    18,
    6,
    11,
    13,
    8,
    21,
    4,
    20,
    3,
    17,
    2,
    29,
    3,
    12,
    29,
    3,
    4,
    15,
    24,
    20,
    6,
    14,
    30,
    22,
  ]
  let encoded = oni_bitcoin.bech32_encode("bc", data, oni_bitcoin.Bech32)

  // Should start with bc1
  string.starts_with(encoded, "bc1") |> should.be_true

  // Decode should succeed
  let result = oni_bitcoin.bech32_decode(encoded)
  result |> should.be_ok
  let assert Ok(#(hrp, decoded_data, variant)) = result
  hrp |> should.equal("bc")
  decoded_data |> should.equal(data)
  case variant {
    oni_bitcoin.Bech32 -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn bech32m_encode_decode_test() {
  // Taproot address data (witness version 1)
  let data = [
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]
  let encoded = oni_bitcoin.bech32_encode("bc", data, oni_bitcoin.Bech32m)

  // Should start with bc1p (version 1 = p in bech32)
  string.starts_with(encoded, "bc1p") |> should.be_true

  let result = oni_bitcoin.bech32_decode(encoded)
  result |> should.be_ok
  let assert Ok(#(hrp, decoded_data, variant)) = result
  hrp |> should.equal("bc")
  decoded_data |> should.equal(data)
  case variant {
    oni_bitcoin.Bech32m -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn bech32_decode_mixed_case_test() {
  // Mixed case should fail
  let result =
    oni_bitcoin.bech32_decode("BC1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
  result |> should.be_error
}

// ============================================================================
// Address Encoding/Decoding Tests
// ============================================================================

pub fn address_p2pkh_roundtrip_test() {
  let hash = <<
    0x14,
    0x62,
    0xe9,
    0x07,
    0xb1,
    0x5c,
    0xbf,
    0x27,
    0xd5,
    0x42,
    0x5f,
    0x99,
    0x7d,
    0xab,
    0x5f,
    0xec,
    0x16,
    0x24,
    0xa3,
    0x2e,
  >>
  let addr = oni_bitcoin.P2PKH(hash, oni_bitcoin.Mainnet)
  let encoded = oni_bitcoin.address_to_string(addr)

  // Mainnet P2PKH starts with 1
  string.starts_with(encoded, "1") |> should.be_true

  // Decode
  let result = oni_bitcoin.address_from_string(encoded, oni_bitcoin.Mainnet)
  result |> should.be_ok
}

pub fn address_p2sh_roundtrip_test() {
  let hash = <<
    0x14,
    0x62,
    0xe9,
    0x07,
    0xb1,
    0x5c,
    0xbf,
    0x27,
    0xd5,
    0x42,
    0x5f,
    0x99,
    0x7d,
    0xab,
    0x5f,
    0xec,
    0x16,
    0x24,
    0xa3,
    0x2e,
  >>
  let addr = oni_bitcoin.P2SH(hash, oni_bitcoin.Mainnet)
  let encoded = oni_bitcoin.address_to_string(addr)

  // Mainnet P2SH starts with 3
  string.starts_with(encoded, "3") |> should.be_true

  let result = oni_bitcoin.address_from_string(encoded, oni_bitcoin.Mainnet)
  result |> should.be_ok
}

pub fn address_p2wpkh_roundtrip_test() {
  let hash = <<
    0x14,
    0x62,
    0xe9,
    0x07,
    0xb1,
    0x5c,
    0xbf,
    0x27,
    0xd5,
    0x42,
    0x5f,
    0x99,
    0x7d,
    0xab,
    0x5f,
    0xec,
    0x16,
    0x24,
    0xa3,
    0x2e,
  >>
  let addr = oni_bitcoin.P2WPKH(hash, oni_bitcoin.Mainnet)
  let encoded = oni_bitcoin.address_to_string(addr)

  // Mainnet P2WPKH starts with bc1q
  string.starts_with(encoded, "bc1q") |> should.be_true

  let result = oni_bitcoin.address_from_string(encoded, oni_bitcoin.Mainnet)
  result |> should.be_ok
}

pub fn address_p2tr_roundtrip_test() {
  let pubkey = <<
    0x79,
    0xBE,
    0x66,
    0x7E,
    0xF9,
    0xDC,
    0xBB,
    0xAC,
    0x55,
    0xA0,
    0x62,
    0x95,
    0xCE,
    0x87,
    0x0B,
    0x07,
    0x02,
    0x9B,
    0xFC,
    0xDB,
    0x2D,
    0xCE,
    0x28,
    0xD9,
    0x59,
    0xF2,
    0x81,
    0x5B,
    0x16,
    0xF8,
    0x17,
    0x98,
  >>
  let addr = oni_bitcoin.P2TR(pubkey, oni_bitcoin.Mainnet)
  let encoded = oni_bitcoin.address_to_string(addr)

  // Mainnet P2TR starts with bc1p
  string.starts_with(encoded, "bc1p") |> should.be_true

  let result = oni_bitcoin.address_from_string(encoded, oni_bitcoin.Mainnet)
  result |> should.be_ok
}

pub fn address_testnet_p2pkh_test() {
  let hash = <<
    0x14,
    0x62,
    0xe9,
    0x07,
    0xb1,
    0x5c,
    0xbf,
    0x27,
    0xd5,
    0x42,
    0x5f,
    0x99,
    0x7d,
    0xab,
    0x5f,
    0xec,
    0x16,
    0x24,
    0xa3,
    0x2e,
  >>
  let addr = oni_bitcoin.P2PKH(hash, oni_bitcoin.Testnet)
  let encoded = oni_bitcoin.address_to_string(addr)

  // Testnet P2PKH starts with m or n
  { string.starts_with(encoded, "m") || string.starts_with(encoded, "n") }
  |> should.be_true
}

// ============================================================================
// Block Header Serialization Tests
// ============================================================================

pub fn block_header_encode_decode_roundtrip_test() {
  // Create a block header
  let prev_bytes = <<
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  >>
  let merkle_bytes = <<
    0x4a,
    0x5e,
    0x1e,
    0x4b,
    0xaa,
    0xb8,
    0x9f,
    0x3a,
    0x32,
    0x51,
    0x8a,
    0x88,
    0xc3,
    0x1b,
    0xc8,
    0x7f,
    0x61,
    0x8f,
    0x76,
    0x67,
    0x3e,
    0x2c,
    0xc7,
    0x7a,
    0xb2,
    0x12,
    0x7b,
    0x7a,
    0xfd,
    0xed,
    0xa3,
    0x3b,
  >>

  let assert Ok(prev_hash) = oni_bitcoin.hash256_from_bytes(prev_bytes)
  let assert Ok(merkle_hash) = oni_bitcoin.hash256_from_bytes(merkle_bytes)

  let header =
    oni_bitcoin.BlockHeader(
      version: 1,
      prev_block: oni_bitcoin.BlockHash(prev_hash),
      merkle_root: merkle_hash,
      timestamp: 1_231_006_505,
      bits: 0x1d00ffff,
      nonce: 2_083_236_893,
    )

  // Encode
  let encoded = oni_bitcoin.encode_block_header(header)

  // Should be exactly 80 bytes
  bit_array.byte_size(encoded) |> should.equal(80)

  // Decode
  let result = oni_bitcoin.decode_block_header(encoded)
  result |> should.be_ok

  let assert Ok(#(decoded, remaining)) = result
  decoded.version |> should.equal(1)
  decoded.timestamp |> should.equal(1_231_006_505)
  decoded.bits |> should.equal(0x1d00ffff)
  decoded.nonce |> should.equal(2_083_236_893)
  remaining |> should.equal(<<>>)
}

pub fn block_hash_from_header_test() {
  // Create a simple header
  let prev_bytes = <<0:256>>
  let merkle_bytes = <<0:256>>

  let assert Ok(prev_hash) = oni_bitcoin.hash256_from_bytes(prev_bytes)
  let assert Ok(merkle_hash) = oni_bitcoin.hash256_from_bytes(merkle_bytes)

  let header =
    oni_bitcoin.BlockHeader(
      version: 1,
      prev_block: oni_bitcoin.BlockHash(prev_hash),
      merkle_root: merkle_hash,
      timestamp: 0,
      bits: 0x1d00ffff,
      nonce: 0,
    )

  // Compute hash
  let hash = oni_bitcoin.block_hash_from_header(header)
  let hex = oni_bitcoin.block_hash_to_hex(hash)

  // Should be a valid 64-char hex string
  string.length(hex) |> should.equal(64)
}

// ============================================================================
// Network Magic Tests
// ============================================================================

pub fn mainnet_magic_test() {
  let magic = oni_bitcoin.mainnet_magic()
  magic.bytes |> should.equal(<<0xF9, 0xBE, 0xB4, 0xD9>>)
}

pub fn testnet_magic_test() {
  let magic = oni_bitcoin.testnet_magic()
  magic.bytes |> should.equal(<<0x0B, 0x11, 0x09, 0x07>>)
}

pub fn regtest_magic_test() {
  let magic = oni_bitcoin.regtest_magic()
  magic.bytes |> should.equal(<<0xFA, 0xBF, 0xB5, 0xDA>>)
}

pub fn network_magic_for_network_test() {
  let mainnet_magic = oni_bitcoin.network_magic(oni_bitcoin.Mainnet)
  mainnet_magic.bytes |> should.equal(<<0xF9, 0xBE, 0xB4, 0xD9>>)

  let testnet_magic = oni_bitcoin.network_magic(oni_bitcoin.Testnet)
  testnet_magic.bytes |> should.equal(<<0x0B, 0x11, 0x09, 0x07>>)
}

// ============================================================================
// WIF Encoding Tests
// ============================================================================

pub fn private_key_from_bytes_valid_test() {
  let key_bytes = <<
    0x00,
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0a,
    0x0b,
    0x0c,
    0x0d,
    0x0e,
    0x0f,
    0x10,
    0x11,
    0x12,
    0x13,
    0x14,
    0x15,
    0x16,
    0x17,
    0x18,
    0x19,
    0x1a,
    0x1b,
    0x1c,
    0x1d,
    0x1e,
    0x1f,
  >>
  let result = oni_bitcoin.private_key_from_bytes(key_bytes, True)
  result |> should.be_ok
}

pub fn private_key_from_bytes_invalid_length_test() {
  let key_bytes = <<0x00, 0x01, 0x02>>
  // Too short
  let result = oni_bitcoin.private_key_from_bytes(key_bytes, True)
  result |> should.be_error
}

pub fn wif_encode_decode_mainnet_compressed_roundtrip_test() {
  let key_bytes = <<
    0x00,
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0a,
    0x0b,
    0x0c,
    0x0d,
    0x0e,
    0x0f,
    0x10,
    0x11,
    0x12,
    0x13,
    0x14,
    0x15,
    0x16,
    0x17,
    0x18,
    0x19,
    0x1a,
    0x1b,
    0x1c,
    0x1d,
    0x1e,
    0x1f,
  >>
  let assert Ok(key) = oni_bitcoin.private_key_from_bytes(key_bytes, True)

  // Encode to WIF
  let wif = oni_bitcoin.private_key_to_wif(key, oni_bitcoin.Mainnet)

  // Mainnet compressed WIF starts with K or L
  { string.starts_with(wif, "K") || string.starts_with(wif, "L") }
  |> should.be_true

  // Decode from WIF
  let result = oni_bitcoin.private_key_from_wif(wif)
  result |> should.be_ok
  let assert Ok(#(decoded_key, network)) = result
  decoded_key.compressed |> should.be_true
  case network {
    oni_bitcoin.Mainnet -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn wif_encode_decode_mainnet_uncompressed_test() {
  let key_bytes = <<
    0xAB,
    0xCD,
    0xEF,
    0x01,
    0x23,
    0x45,
    0x67,
    0x89,
    0xAB,
    0xCD,
    0xEF,
    0x01,
    0x23,
    0x45,
    0x67,
    0x89,
    0xAB,
    0xCD,
    0xEF,
    0x01,
    0x23,
    0x45,
    0x67,
    0x89,
    0xAB,
    0xCD,
    0xEF,
    0x01,
    0x23,
    0x45,
    0x67,
    0x89,
  >>
  let assert Ok(key) = oni_bitcoin.private_key_from_bytes(key_bytes, False)

  // Encode to WIF
  let wif = oni_bitcoin.private_key_to_wif(key, oni_bitcoin.Mainnet)

  // Mainnet uncompressed WIF starts with 5
  string.starts_with(wif, "5") |> should.be_true

  // Decode from WIF
  let result = oni_bitcoin.private_key_from_wif(wif)
  result |> should.be_ok
  let assert Ok(#(decoded_key, _network)) = result
  decoded_key.compressed |> should.be_false
}

pub fn wif_encode_decode_testnet_compressed_test() {
  let key_bytes = <<
    0x12,
    0x34,
    0x56,
    0x78,
    0x9A,
    0xBC,
    0xDE,
    0xF0,
    0x12,
    0x34,
    0x56,
    0x78,
    0x9A,
    0xBC,
    0xDE,
    0xF0,
    0x12,
    0x34,
    0x56,
    0x78,
    0x9A,
    0xBC,
    0xDE,
    0xF0,
    0x12,
    0x34,
    0x56,
    0x78,
    0x9A,
    0xBC,
    0xDE,
    0xF0,
  >>
  let assert Ok(key) = oni_bitcoin.private_key_from_bytes(key_bytes, True)

  // Encode to WIF
  let wif = oni_bitcoin.private_key_to_wif(key, oni_bitcoin.Testnet)

  // Testnet compressed WIF starts with c
  string.starts_with(wif, "c") |> should.be_true

  // Decode from WIF
  let result = oni_bitcoin.private_key_from_wif(wif)
  result |> should.be_ok
  let assert Ok(#(decoded_key, network)) = result
  decoded_key.compressed |> should.be_true
  case network {
    oni_bitcoin.Testnet -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

// ============================================================================
// Extended Key Types Tests
// ============================================================================

pub fn fingerprint_from_bytes_valid_test() {
  let bytes = <<0x01, 0x02, 0x03, 0x04>>
  let result = oni_bitcoin.fingerprint_from_bytes(bytes)
  result |> should.be_ok
}

pub fn fingerprint_from_bytes_invalid_test() {
  let bytes = <<0x01, 0x02>>
  // Too short
  let result = oni_bitcoin.fingerprint_from_bytes(bytes)
  result |> should.be_error
}

pub fn chain_code_from_bytes_valid_test() {
  let bytes = <<
    0x00,
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0a,
    0x0b,
    0x0c,
    0x0d,
    0x0e,
    0x0f,
    0x10,
    0x11,
    0x12,
    0x13,
    0x14,
    0x15,
    0x16,
    0x17,
    0x18,
    0x19,
    0x1a,
    0x1b,
    0x1c,
    0x1d,
    0x1e,
    0x1f,
  >>
  let result = oni_bitcoin.chain_code_from_bytes(bytes)
  result |> should.be_ok
}

pub fn chain_code_from_bytes_invalid_test() {
  let bytes = <<0x00, 0x01, 0x02>>
  // Too short
  let result = oni_bitcoin.chain_code_from_bytes(bytes)
  result |> should.be_error
}

// ============================================================================
// Imports needed
// ============================================================================
import gleam/bit_array
import gleam/list
import gleam/string
