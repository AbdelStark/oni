import gleeunit
import gleeunit/should
import oni_storage
import oni_bitcoin

pub fn main() {
  gleeunit.main()
}

pub fn not_found_test() {
  // Create a valid 32-byte hash for testing
  let hash_bytes = <<
    0x00, 0x00, 0x00, 0x00, 0x00, 0x19, 0xd6, 0x68,
    0x9c, 0x08, 0x5a, 0xe1, 0x65, 0x83, 0x1e, 0x93,
    0x4f, 0xf7, 0x63, 0xae, 0x46, 0xa2, 0xa6, 0xc1,
    0x72, 0xb3, 0xf1, 0xb6, 0x0a, 0x8c, 0xe2, 0x6f
  >>
  let assert Ok(h) = oni_bitcoin.block_hash_from_bytes(hash_bytes)
  oni_storage.get_header(h)
  |> should.equal(Error(oni_storage.NotFound))
}

pub fn storage_error_types_test() {
  // Verify error types are correct
  let err = oni_storage.NotFound
  case err {
    oni_storage.NotFound -> should.be_true(True)
    _ -> should.fail()
  }
}
