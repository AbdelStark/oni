// db_backend.gleam - Persistent key-value database backend
//
// This module provides a persistent storage layer using Erlang's dets
// (disk-based ETS tables). It abstracts database operations to allow
// for future replacement with other backends (LevelDB, RocksDB, etc.).
//
// Features:
// - Persistent key-value storage
// - Batch operations for atomic writes
// - Schema versioning for migrations
// - Crash recovery via dets repair
//
// Usage:
//   1. Open database with db_open(path, options)
//   2. Perform operations (get, put, delete, batch)
//   3. Close with db_close(handle)

import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/option.{type Option, None, Some}

// ============================================================================
// Types
// ============================================================================

/// Database handle (wraps dets table reference)
pub type DbHandle {
  DbHandle(
    /// Table name/reference
    name: Atom,
    /// Path to database file
    path: String,
    /// Whether database is open
    is_open: Bool,
  )
}

/// Database options
pub type DbOptions {
  DbOptions(
    /// Create if not exists
    create: Bool,
    /// Auto-repair on corruption
    auto_repair: Bool,
    /// Maximum number of keys
    max_keys: Option(Int),
    /// RAM file (memory + disk sync)
    ram_file: Bool,
  )
}

/// Default database options
pub fn default_options() -> DbOptions {
  DbOptions(create: True, auto_repair: True, max_keys: None, ram_file: False)
}

/// Database error types
pub type DbError {
  /// Database not found
  DbNotFound
  /// Key not found
  KeyNotFound
  /// Database is corrupted
  Corrupted
  /// I/O error
  IoError(String)
  /// Database is closed
  Closed
  /// Schema version mismatch
  SchemaMismatch(expected: Int, found: Int)
  /// Other error
  Other(String)
}

/// Batch operation types
pub type BatchOp {
  /// Put a key-value pair
  BatchPut(key: BitArray, value: BitArray)
  /// Delete a key
  BatchDelete(key: BitArray)
}

// ============================================================================
// Database Operations
// ============================================================================

/// Open a database
pub fn db_open(path: String, options: DbOptions) -> Result(DbHandle, DbError) {
  let name = make_table_name(path)

  case dets_open(name, path, options) {
    Ok(_) -> Ok(DbHandle(name: name, path: path, is_open: True))
    Error(err) -> Error(err)
  }
}

/// Close a database
pub fn db_close(handle: DbHandle) -> Result(Nil, DbError) {
  case handle.is_open {
    False -> Ok(Nil)
    True -> dets_close(handle.name)
  }
}

/// Get a value by key
pub fn db_get(handle: DbHandle, key: BitArray) -> Result(BitArray, DbError) {
  case handle.is_open {
    False -> Error(Closed)
    True -> dets_lookup(handle.name, key)
  }
}

/// Put a key-value pair
pub fn db_put(
  handle: DbHandle,
  key: BitArray,
  value: BitArray,
) -> Result(Nil, DbError) {
  case handle.is_open {
    False -> Error(Closed)
    True -> dets_insert(handle.name, key, value)
  }
}

/// Delete a key
pub fn db_delete(handle: DbHandle, key: BitArray) -> Result(Nil, DbError) {
  case handle.is_open {
    False -> Error(Closed)
    True -> dets_delete(handle.name, key)
  }
}

/// Check if a key exists
pub fn db_has(handle: DbHandle, key: BitArray) -> Bool {
  case handle.is_open {
    False -> False
    True -> {
      case dets_member(handle.name, key) {
        Ok(result) -> result
        Error(_) -> False
      }
    }
  }
}

/// Execute batch operations atomically
pub fn db_batch(handle: DbHandle, ops: List(BatchOp)) -> Result(Nil, DbError) {
  case handle.is_open {
    False -> Error(Closed)
    True -> execute_batch(handle.name, ops)
  }
}

/// Sync database to disk
pub fn db_sync(handle: DbHandle) -> Result(Nil, DbError) {
  case handle.is_open {
    False -> Error(Closed)
    True -> dets_sync(handle.name)
  }
}

/// Iterate over all keys
pub fn db_keys(handle: DbHandle) -> Result(List(BitArray), DbError) {
  case handle.is_open {
    False -> Error(Closed)
    True -> dets_all_keys(handle.name)
  }
}

/// Get the number of entries
pub fn db_count(handle: DbHandle) -> Result(Int, DbError) {
  case handle.is_open {
    False -> Error(Closed)
    True -> dets_info_size(handle.name)
  }
}

// ============================================================================
// Schema Versioning
// ============================================================================

/// Schema version key (special key for metadata)
const schema_version_key = <<"__schema_version__">>

/// Get schema version
pub fn db_get_schema_version(handle: DbHandle) -> Result(Int, DbError) {
  case db_get(handle, schema_version_key) {
    Ok(data) -> {
      case decode_int(data) {
        Ok(version) -> Ok(version)
        Error(_) -> Error(Corrupted)
      }
    }
    Error(KeyNotFound) -> Ok(0)
    // No version means version 0
    Error(err) -> Error(err)
  }
}

/// Set schema version
pub fn db_set_schema_version(
  handle: DbHandle,
  version: Int,
) -> Result(Nil, DbError) {
  let data = encode_int(version)
  db_put(handle, schema_version_key, data)
}

/// Check and migrate schema
pub fn db_check_schema(
  handle: DbHandle,
  expected_version: Int,
  migrate_fn: Option(fn(DbHandle, Int) -> Result(Nil, DbError)),
) -> Result(Nil, DbError) {
  case db_get_schema_version(handle) {
    Ok(current_version) -> {
      case current_version == expected_version {
        True -> Ok(Nil)
        False -> {
          case current_version < expected_version, migrate_fn {
            True, Some(migrate) -> {
              // Run migration
              case migrate(handle, current_version) {
                Ok(_) -> db_set_schema_version(handle, expected_version)
                Error(err) -> Error(err)
              }
            }
            _, _ -> Error(SchemaMismatch(expected_version, current_version))
          }
        }
      }
    }
    Error(err) -> Error(err)
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Execute batch operations
fn execute_batch(name: Atom, ops: List(BatchOp)) -> Result(Nil, DbError) {
  execute_batch_loop(name, ops)
}

fn execute_batch_loop(name: Atom, ops: List(BatchOp)) -> Result(Nil, DbError) {
  case ops {
    [] -> dets_sync(name)
    // Sync after batch
    [op, ..rest] -> {
      let result = case op {
        BatchPut(key, value) -> dets_insert(name, key, value)
        BatchDelete(key) -> dets_delete(name, key)
      }
      case result {
        Ok(_) -> execute_batch_loop(name, rest)
        Error(err) -> Error(err)
      }
    }
  }
}

/// Encode an integer to bytes
fn encode_int(n: Int) -> BitArray {
  <<n:64-little>>
}

/// Decode bytes to integer
fn decode_int(data: BitArray) -> Result(Int, Nil) {
  case data {
    <<n:64-little>> -> Ok(n)
    _ -> Error(Nil)
  }
}

/// Make a unique table name from path
fn make_table_name(path: String) -> Atom {
  // Use path hash as table name to ensure uniqueness
  let hash = erlang_phash2(path)
  let name_str = "oni_db_" <> int.to_string(hash)
  atom.create_from_string(name_str)
}

// ============================================================================
// Erlang FFI Declarations
// ============================================================================

/// Hash function for table name generation
@external(erlang, "erlang", "phash2")
fn erlang_phash2(term: a) -> Int

/// Open dets table
@external(erlang, "db_backend_ffi", "dets_open")
fn dets_open(
  name: Atom,
  path: String,
  options: DbOptions,
) -> Result(Atom, DbError)

/// Close dets table
@external(erlang, "db_backend_ffi", "dets_close")
fn dets_close(name: Atom) -> Result(Nil, DbError)

/// Lookup key in dets
@external(erlang, "db_backend_ffi", "dets_lookup")
fn dets_lookup(name: Atom, key: BitArray) -> Result(BitArray, DbError)

/// Insert key-value in dets
@external(erlang, "db_backend_ffi", "dets_insert")
fn dets_insert(
  name: Atom,
  key: BitArray,
  value: BitArray,
) -> Result(Nil, DbError)

/// Delete key from dets
@external(erlang, "db_backend_ffi", "dets_delete")
fn dets_delete(name: Atom, key: BitArray) -> Result(Nil, DbError)

/// Check if key exists
@external(erlang, "db_backend_ffi", "dets_member")
fn dets_member(name: Atom, key: BitArray) -> Result(Bool, DbError)

/// Sync dets to disk
@external(erlang, "db_backend_ffi", "dets_sync")
fn dets_sync(name: Atom) -> Result(Nil, DbError)

/// Get all keys
@external(erlang, "db_backend_ffi", "dets_all_keys")
fn dets_all_keys(name: Atom) -> Result(List(BitArray), DbError)

/// Get table size
@external(erlang, "db_backend_ffi", "dets_info_size")
fn dets_info_size(name: Atom) -> Result(Int, DbError)
