// db_backend_test.gleam - Tests for persistent database backend
//
// These tests verify the dets-based persistent storage layer.

import db_backend.{
  BatchDelete, BatchPut, Closed, KeyNotFound, db_batch, db_close, db_count,
  db_delete, db_get, db_get_schema_version, db_has, db_keys, db_open, db_put,
  db_set_schema_version, db_sync, default_options,
}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Basic Open/Close Tests
// ============================================================================

pub fn db_opens_and_closes_test() {
  let path = "/tmp/oni_test_db_1"
  cleanup_db(path)

  // Open database
  let result = db_open(path, default_options())
  should.be_ok(result)

  case result {
    Ok(handle) -> {
      // Close database
      let close_result = db_close(handle)
      should.be_ok(close_result)
    }
    Error(_) -> should.fail()
  }

  cleanup_db(path)
}

pub fn db_creates_file_test() {
  let path = "/tmp/oni_test_db_2"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Put some data to ensure file is created
  let assert Ok(_) = db_put(handle, <<"key">>, <<"value">>)
  let assert Ok(_) = db_sync(handle)
  let assert Ok(_) = db_close(handle)

  // Reopen should work
  let assert Ok(handle2) = db_open(path, default_options())
  let assert Ok(_) = db_close(handle2)

  cleanup_db(path)
}

// ============================================================================
// Get/Put Tests
// ============================================================================

pub fn db_put_and_get_test() {
  let path = "/tmp/oni_test_db_3"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Put a value
  let key = <<"test_key">>
  let value = <<"test_value">>
  let put_result = db_put(handle, key, value)
  should.be_ok(put_result)

  // Get it back
  let get_result = db_get(handle, key)
  should.be_ok(get_result)
  should.equal(get_result, Ok(value))

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

pub fn db_get_missing_key_test() {
  let path = "/tmp/oni_test_db_4"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Get a key that doesn't exist
  let result = db_get(handle, <<"nonexistent">>)
  should.be_error(result)
  should.equal(result, Error(KeyNotFound))

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

pub fn db_put_overwrites_test() {
  let path = "/tmp/oni_test_db_5"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  let key = <<"key">>

  // Put first value
  let assert Ok(_) = db_put(handle, key, <<"value1">>)
  let assert Ok(v1) = db_get(handle, key)
  should.equal(v1, <<"value1">>)

  // Overwrite with second value
  let assert Ok(_) = db_put(handle, key, <<"value2">>)
  let assert Ok(v2) = db_get(handle, key)
  should.equal(v2, <<"value2">>)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

// ============================================================================
// Delete Tests
// ============================================================================

pub fn db_delete_test() {
  let path = "/tmp/oni_test_db_6"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  let key = <<"to_delete">>

  // Put and verify
  let assert Ok(_) = db_put(handle, key, <<"value">>)
  let assert Ok(_) = db_get(handle, key)

  // Delete
  let assert Ok(_) = db_delete(handle, key)

  // Should be gone
  let result = db_get(handle, key)
  should.equal(result, Error(KeyNotFound))

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

pub fn db_delete_nonexistent_test() {
  let path = "/tmp/oni_test_db_7"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Delete a key that doesn't exist - should be ok
  let result = db_delete(handle, <<"nonexistent">>)
  should.be_ok(result)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

// ============================================================================
// Has Tests
// ============================================================================

pub fn db_has_test() {
  let path = "/tmp/oni_test_db_8"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  let key = <<"exists">>

  // Should not exist initially
  should.equal(db_has(handle, key), False)

  // Add it
  let assert Ok(_) = db_put(handle, key, <<"value">>)

  // Should exist now
  should.equal(db_has(handle, key), True)

  // Delete it
  let assert Ok(_) = db_delete(handle, key)

  // Should not exist anymore
  should.equal(db_has(handle, key), False)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

// ============================================================================
// Batch Tests
// ============================================================================

pub fn db_batch_put_test() {
  let path = "/tmp/oni_test_db_9"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Batch put multiple keys
  let ops = [
    BatchPut(<<"k1">>, <<"v1">>),
    BatchPut(<<"k2">>, <<"v2">>),
    BatchPut(<<"k3">>, <<"v3">>),
  ]

  let result = db_batch(handle, ops)
  should.be_ok(result)

  // Verify all keys
  let assert Ok(v1) = db_get(handle, <<"k1">>)
  let assert Ok(v2) = db_get(handle, <<"k2">>)
  let assert Ok(v3) = db_get(handle, <<"k3">>)

  should.equal(v1, <<"v1">>)
  should.equal(v2, <<"v2">>)
  should.equal(v3, <<"v3">>)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

pub fn db_batch_mixed_test() {
  let path = "/tmp/oni_test_db_10"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // First put some keys
  let assert Ok(_) = db_put(handle, <<"a">>, <<"1">>)
  let assert Ok(_) = db_put(handle, <<"b">>, <<"2">>)

  // Batch with mixed operations
  let ops = [
    BatchPut(<<"c">>, <<"3">>),
    // Add new
    BatchDelete(<<"a">>),
    // Delete existing
    BatchPut(<<"b">>, <<"22">>),
    // Update existing
  ]

  let assert Ok(_) = db_batch(handle, ops)

  // Verify
  should.equal(db_get(handle, <<"a">>), Error(KeyNotFound))
  should.equal(db_get(handle, <<"b">>), Ok(<<"22">>))
  should.equal(db_get(handle, <<"c">>), Ok(<<"3">>))

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

// ============================================================================
// Keys and Count Tests
// ============================================================================

pub fn db_count_test() {
  let path = "/tmp/oni_test_db_11"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Initially empty
  let assert Ok(count0) = db_count(handle)
  should.equal(count0, 0)

  // Add some keys
  let assert Ok(_) = db_put(handle, <<"a">>, <<"1">>)
  let assert Ok(count1) = db_count(handle)
  should.equal(count1, 1)

  let assert Ok(_) = db_put(handle, <<"b">>, <<"2">>)
  let assert Ok(count2) = db_count(handle)
  should.equal(count2, 2)

  // Delete one
  let assert Ok(_) = db_delete(handle, <<"a">>)
  let assert Ok(count3) = db_count(handle)
  should.equal(count3, 1)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

pub fn db_keys_test() {
  let path = "/tmp/oni_test_db_12"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Add some keys
  let assert Ok(_) = db_put(handle, <<"key1">>, <<"v1">>)
  let assert Ok(_) = db_put(handle, <<"key2">>, <<"v2">>)
  let assert Ok(_) = db_put(handle, <<"key3">>, <<"v3">>)

  let assert Ok(keys) = db_keys(handle)

  // Should have 3 keys (order not guaranteed)
  should.equal(list_length(keys), 3)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

// ============================================================================
// Schema Versioning Tests
// ============================================================================

pub fn db_schema_version_default_test() {
  let path = "/tmp/oni_test_db_13"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Default version should be 0
  let assert Ok(version) = db_get_schema_version(handle)
  should.equal(version, 0)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

pub fn db_schema_version_set_get_test() {
  let path = "/tmp/oni_test_db_14"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Set version
  let assert Ok(_) = db_set_schema_version(handle, 5)

  // Get it back
  let assert Ok(version) = db_get_schema_version(handle)
  should.equal(version, 5)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

pub fn db_schema_version_persists_test() {
  let path = "/tmp/oni_test_db_15"
  cleanup_db(path)

  // Open and set version
  let assert Ok(handle1) = db_open(path, default_options())
  let assert Ok(_) = db_set_schema_version(handle1, 42)
  let assert Ok(_) = db_close(handle1)

  // Reopen and verify
  let assert Ok(handle2) = db_open(path, default_options())
  let assert Ok(version) = db_get_schema_version(handle2)
  should.equal(version, 42)

  let assert Ok(_) = db_close(handle2)
  cleanup_db(path)
}

// ============================================================================
// Persistence Tests
// ============================================================================

pub fn db_data_persists_test() {
  let path = "/tmp/oni_test_db_16"
  cleanup_db(path)

  // Write data
  let assert Ok(handle1) = db_open(path, default_options())
  let assert Ok(_) =
    db_put(handle1, <<"persistent_key">>, <<"persistent_value">>)
  let assert Ok(_) = db_sync(handle1)
  let assert Ok(_) = db_close(handle1)

  // Reopen and read
  let assert Ok(handle2) = db_open(path, default_options())
  let assert Ok(value) = db_get(handle2, <<"persistent_key">>)
  should.equal(value, <<"persistent_value">>)

  let assert Ok(_) = db_close(handle2)
  cleanup_db(path)
}

// ============================================================================
// Closed Handle Tests
// ============================================================================

pub fn db_operations_fail_on_closed_test() {
  let path = "/tmp/oni_test_db_17"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())
  let assert Ok(_) = db_close(handle)

  // Create a closed handle manually (is_open = False)
  let closed_handle =
    db_backend.DbHandle(name: handle.name, path: handle.path, is_open: False)

  // Operations should fail
  should.equal(db_get(closed_handle, <<"key">>), Error(Closed))
  should.equal(db_put(closed_handle, <<"key">>, <<"value">>), Error(Closed))
  should.equal(db_delete(closed_handle, <<"key">>), Error(Closed))
  should.equal(db_has(closed_handle, <<"key">>), False)
  should.equal(db_count(closed_handle), Error(Closed))
  should.equal(db_keys(closed_handle), Error(Closed))
  should.equal(db_batch(closed_handle, []), Error(Closed))
  should.equal(db_sync(closed_handle), Error(Closed))

  cleanup_db(path)
}

// ============================================================================
// Binary Key/Value Tests
// ============================================================================

pub fn db_binary_keys_test() {
  let path = "/tmp/oni_test_db_18"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Use binary keys (like block hashes)
  let key = <<0x00, 0x01, 0x02, 0xff, 0xfe, 0xfd>>
  let value = <<0xaa, 0xbb, 0xcc, 0xdd>>

  let assert Ok(_) = db_put(handle, key, value)
  let assert Ok(result) = db_get(handle, key)
  should.equal(result, value)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

pub fn db_large_value_test() {
  let path = "/tmp/oni_test_db_19"
  cleanup_db(path)

  let assert Ok(handle) = db_open(path, default_options())

  // Create a larger value (simulating a serialized block)
  let key = <<"large_block">>
  let value = create_large_value(10_000)

  let assert Ok(_) = db_put(handle, key, value)
  let assert Ok(result) = db_get(handle, key)
  should.equal(bit_array_size(result), 10_000)

  let assert Ok(_) = db_close(handle)
  cleanup_db(path)
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Clean up test database file
fn cleanup_db(path: String) -> Nil {
  // Delete the dets file if it exists
  let _ = delete_file(path)
  Nil
}

/// Get length of a list
fn list_length(list: List(a)) -> Int {
  do_list_length(list, 0)
}

fn do_list_length(list: List(a), acc: Int) -> Int {
  case list {
    [] -> acc
    [_, ..rest] -> do_list_length(rest, acc + 1)
  }
}

/// Create a large binary value for testing
fn create_large_value(size: Int) -> BitArray {
  create_large_value_loop(size, <<>>)
}

fn create_large_value_loop(remaining: Int, acc: BitArray) -> BitArray {
  case remaining <= 0 {
    True -> acc
    False -> create_large_value_loop(remaining - 1, <<0xab, acc:bits>>)
  }
}

/// Get bit array size
fn bit_array_size(bits: BitArray) -> Int {
  do_bit_array_size(bits)
}

@external(erlang, "erlang", "byte_size")
fn do_bit_array_size(bits: BitArray) -> Int

/// Delete a file
@external(erlang, "file", "delete")
fn delete_file(path: String) -> Result(Nil, Nil)
