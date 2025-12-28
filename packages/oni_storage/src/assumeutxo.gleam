// assumeutxo.gleam - AssumeUTXO snapshot support (Phase 10+)
//
// This module implements AssumeUTXO functionality for fast node bootstrap.
// AssumeUTXO allows a node to start syncing from a recent UTXO snapshot
// instead of validating from genesis, dramatically reducing sync time.
//
// Security model:
//   - Snapshot is validated against a hardcoded hash
//   - Background validation continues from genesis
//   - Node is "assumed valid" until background sync catches up
//
// Reference: https://github.com/bitcoin/bitcoin/blob/master/doc/design/assumeutxo.md

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{type BlockHash, type OutPoint, type TxOut}
import oni_storage.{type Coin, type StorageError, type UtxoView}

// ============================================================================
// AssumeUTXO Types
// ============================================================================

/// AssumeUTXO snapshot metadata
pub type SnapshotMetadata {
  SnapshotMetadata(
    /// Block hash at which snapshot was taken
    block_hash: BlockHash,
    /// Block height of snapshot
    height: Int,
    /// Number of UTXOs in snapshot
    num_utxos: Int,
    /// Number of transactions with unspent outputs
    num_txs: Int,
    /// Total amount in all UTXOs (satoshis)
    total_amount: Int,
    /// MuHash of the UTXO set
    muhash: BitArray,
    /// Serialized snapshot hash (for verification)
    snapshot_hash: BitArray,
  )
}

/// Known snapshot for a network
pub type KnownSnapshot {
  KnownSnapshot(
    metadata: SnapshotMetadata,
    network: Network,
  )
}

/// Network type
pub type Network {
  Mainnet
  Testnet
  Signet
  Regtest
}

/// Snapshot validation state
pub type SnapshotState {
  /// No snapshot loaded
  NoSnapshot
  /// Snapshot loading in progress
  Loading(progress: LoadProgress)
  /// Snapshot loaded and active
  Active(metadata: SnapshotMetadata)
  /// Background validation in progress
  Validating(metadata: SnapshotMetadata, progress: ValidationProgress)
  /// Fully validated (background sync caught up)
  Validated(metadata: SnapshotMetadata)
  /// Snapshot failed validation
  Invalid(reason: SnapshotError)
}

/// Snapshot loading progress
pub type LoadProgress {
  LoadProgress(
    bytes_read: Int,
    total_bytes: Int,
    utxos_loaded: Int,
    total_utxos: Int,
  )
}

/// Background validation progress
pub type ValidationProgress {
  ValidationProgress(
    current_height: Int,
    snapshot_height: Int,
    blocks_validated: Int,
    is_caught_up: Bool,
  )
}

/// Snapshot errors
pub type SnapshotError {
  HashMismatch
  InvalidFormat
  IncompleteSnapshot
  UnsupportedVersion
  NetworkMismatch
  HeightMismatch
  IoError(String)
  ValidationFailed(String)
}

// ============================================================================
// Hardcoded Snapshots
// ============================================================================

/// Get known snapshots for mainnet
pub fn mainnet_snapshots() -> List(KnownSnapshot) {
  // These are example snapshots - real ones would be generated from Bitcoin Core
  [
    KnownSnapshot(
      metadata: SnapshotMetadata(
        block_hash: create_block_hash("000000000000000000035c3f2816b3c6e92a61e7f5c7f3f7c5e3f2a1b0c9d8e7"),
        height: 820000,
        num_utxos: 95_000_000,
        num_txs: 45_000_000,
        total_amount: 1_940_000_000_000_000,
        muhash: <<0:256>>,  // Placeholder
        snapshot_hash: <<0:256>>,  // Placeholder
      ),
      network: Mainnet,
    ),
  ]
}

/// Get known snapshots for testnet
pub fn testnet_snapshots() -> List(KnownSnapshot) {
  [
    KnownSnapshot(
      metadata: SnapshotMetadata(
        block_hash: create_block_hash("00000000000000015dc777b3ff2611091336355d3f0ee9766a2e7dfcadb0d89e"),
        height: 2_500_000,
        num_utxos: 30_000_000,
        num_txs: 15_000_000,
        total_amount: 2_000_000_000_000_000,
        muhash: <<0:256>>,
        snapshot_hash: <<0:256>>,
      ),
      network: Testnet,
    ),
  ]
}

/// Get known snapshots for a network
pub fn get_known_snapshots(network: Network) -> List(KnownSnapshot) {
  case network {
    Mainnet -> mainnet_snapshots()
    Testnet -> testnet_snapshots()
    Signet -> []
    Regtest -> []
  }
}

/// Find a snapshot at a specific height
pub fn find_snapshot_at_height(
  network: Network,
  height: Int,
) -> Option(KnownSnapshot) {
  let snapshots = get_known_snapshots(network)
  list.find(snapshots, fn(s) { s.metadata.height == height })
  |> option.from_result
}

/// Find the latest known snapshot
pub fn find_latest_snapshot(network: Network) -> Option(KnownSnapshot) {
  let snapshots = get_known_snapshots(network)
  list.fold(snapshots, None, fn(acc: Option(KnownSnapshot), snap: KnownSnapshot) {
    case acc {
      None -> Some(snap)
      Some(current) -> {
        case snap.metadata.height > current.metadata.height {
          True -> Some(snap)
          False -> acc
        }
      }
    }
  })
}

// ============================================================================
// Snapshot Loading
// ============================================================================

/// Snapshot loader state
pub type SnapshotLoader {
  SnapshotLoader(
    expected_metadata: SnapshotMetadata,
    utxo_view: UtxoView,
    coins_loaded: Int,
    bytes_read: Int,
    hasher: MuHasher,
  )
}

/// MuHash accumulator for UTXO set hashing
pub type MuHasher {
  MuHasher(state: BitArray)
}

/// Create a new snapshot loader
pub fn new_loader(metadata: SnapshotMetadata) -> SnapshotLoader {
  SnapshotLoader(
    expected_metadata: metadata,
    utxo_view: oni_storage.utxo_view_new(),
    coins_loaded: 0,
    bytes_read: 0,
    hasher: muhash_new(),
  )
}

/// Load a coin into the snapshot
pub fn load_coin(
  loader: SnapshotLoader,
  outpoint: OutPoint,
  coin: Coin,
) -> SnapshotLoader {
  let new_view = oni_storage.utxo_add(loader.utxo_view, outpoint, coin)
  let new_hasher = muhash_add(loader.hasher, outpoint, coin)

  SnapshotLoader(
    ..loader,
    utxo_view: new_view,
    coins_loaded: loader.coins_loaded + 1,
    hasher: new_hasher,
  )
}

/// Finalize snapshot loading and verify hash
pub fn finalize_loader(
  loader: SnapshotLoader,
) -> Result(#(UtxoView, SnapshotMetadata), SnapshotError) {
  // Verify coin count matches
  case loader.coins_loaded == loader.expected_metadata.num_utxos {
    False -> Error(IncompleteSnapshot)
    True -> {
      // Verify MuHash
      let computed_hash = muhash_finalize(loader.hasher)
      case bit_array_eq(computed_hash, loader.expected_metadata.muhash) {
        False -> Error(HashMismatch)
        True -> Ok(#(loader.utxo_view, loader.expected_metadata))
      }
    }
  }
}

/// Get loading progress
pub fn get_load_progress(
  loader: SnapshotLoader,
  total_bytes: Int,
) -> LoadProgress {
  LoadProgress(
    bytes_read: loader.bytes_read,
    total_bytes: total_bytes,
    utxos_loaded: loader.coins_loaded,
    total_utxos: loader.expected_metadata.num_utxos,
  )
}

// ============================================================================
// Snapshot Serialization Format
// ============================================================================

/// Snapshot file header
pub type SnapshotHeader {
  SnapshotHeader(
    magic: Int,
    version: Int,
    network: Int,
    block_hash: BlockHash,
    height: Int,
    num_utxos: Int,
  )
}

/// Snapshot magic bytes
pub const snapshot_magic = 0x55_54_58_4F  // "UTXO"

/// Current snapshot version
pub const snapshot_version = 1

/// Serialize snapshot header
pub fn serialize_header(header: SnapshotHeader) -> BitArray {
  let hash_bytes = block_hash_to_bytes(header.block_hash)
  <<
    header.magic:32-big,
    header.version:16-little,
    header.network:8,
    hash_bytes:bits,
    header.height:32-little,
    header.num_utxos:64-little,
  >>
}

/// Parse snapshot header
pub fn parse_header(data: BitArray) -> Result(#(SnapshotHeader, BitArray), SnapshotError) {
  case data {
    <<magic:32-big, version:16-little, network:8, hash:bytes-size(32),
      height:32-little, num_utxos:64-little, rest:bits>> -> {
      // Verify magic
      case magic == snapshot_magic {
        False -> Error(InvalidFormat)
        True -> {
          // Verify version
          case version == snapshot_version {
            False -> Error(UnsupportedVersion)
            True -> {
              let header = SnapshotHeader(
                magic: magic,
                version: version,
                network: network,
                block_hash: create_block_hash_from_bytes(hash),
                height: height,
                num_utxos: num_utxos,
              )
              Ok(#(header, rest))
            }
          }
        }
      }
    }
    _ -> Error(InvalidFormat)
  }
}

/// Coin serialization format (compact)
pub type SerializedCoin {
  SerializedCoin(
    outpoint: OutPoint,
    coin: Coin,
  )
}

/// Serialize a coin entry
pub fn serialize_coin(outpoint: OutPoint, coin: Coin) -> BitArray {
  let txid_bytes = txid_to_bytes(outpoint.txid)
  let script_bytes = oni_bitcoin.script_to_bytes(coin.output.script_pubkey)
  let script_len = bit_array.byte_size(script_bytes)
  let value = oni_bitcoin.amount_to_sats(coin.output.value)

  // Encode coinbase flag and height together
  let height_and_flag = case coin.is_coinbase {
    True -> coin.height * 2 + 1
    False -> coin.height * 2
  }

  <<
    txid_bytes:bits,
    outpoint.vout:32-little,
    { encode_varint(height_and_flag) }:bits,
    value:64-little,
    { encode_varint(script_len) }:bits,
    script_bytes:bits,
  >>
}

/// Parse a coin entry
pub fn parse_coin(data: BitArray) -> Result(#(OutPoint, Coin, BitArray), SnapshotError) {
  case data {
    <<txid_bytes:bytes-size(32), vout:32-little, rest1:bits>> -> {
      case parse_varint(rest1) {
        Error(_) -> Error(InvalidFormat)
        Ok(#(height_and_flag, rest2)) -> {
          let is_coinbase = int.modulo(height_and_flag, 2) == Ok(1)
          let height = height_and_flag / 2

          case rest2 {
            <<value:64-little, rest3:bits>> -> {
              case parse_varint(rest3) {
                Error(_) -> Error(InvalidFormat)
                Ok(#(script_len, rest4)) -> {
                  case extract_bytes(rest4, script_len) {
                    Error(_) -> Error(InvalidFormat)
                    Ok(#(script_bytes, remaining)) -> {
                      let txid = create_txid_from_bytes(txid_bytes)
                      let outpoint = oni_bitcoin.outpoint_new(txid, vout)
                      let script = oni_bitcoin.script_from_bytes(script_bytes)
                      let amount = case oni_bitcoin.amount_from_sats(value) {
                        Ok(a) -> a
                        Error(_) -> oni_bitcoin.Amount(0)
                      }
                      let output = oni_bitcoin.TxOut(value: amount, script_pubkey: script)
                      let coin = oni_storage.coin_new(output, height, is_coinbase)

                      Ok(#(outpoint, coin, remaining))
                    }
                  }
                }
              }
            }
            _ -> Error(InvalidFormat)
          }
        }
      }
    }
    _ -> Error(InvalidFormat)
  }
}

// ============================================================================
// Background Validation
// ============================================================================

/// Background validation state
pub type BackgroundValidator {
  BackgroundValidator(
    snapshot_metadata: SnapshotMetadata,
    current_height: Int,
    blocks_validated: Int,
    last_validated_hash: BlockHash,
  )
}

/// Create a new background validator
pub fn new_validator(metadata: SnapshotMetadata) -> BackgroundValidator {
  BackgroundValidator(
    snapshot_metadata: metadata,
    current_height: 0,
    blocks_validated: 0,
    last_validated_hash: create_block_hash("0000000000000000000000000000000000000000000000000000000000000000"),
  )
}

/// Record a validated block
pub fn record_validated_block(
  validator: BackgroundValidator,
  height: Int,
  hash: BlockHash,
) -> BackgroundValidator {
  BackgroundValidator(
    ..validator,
    current_height: height,
    blocks_validated: validator.blocks_validated + 1,
    last_validated_hash: hash,
  )
}

/// Check if background validation has caught up to snapshot
pub fn is_caught_up(validator: BackgroundValidator) -> Bool {
  validator.current_height >= validator.snapshot_metadata.height
}

/// Get validation progress
pub fn get_validation_progress(validator: BackgroundValidator) -> ValidationProgress {
  ValidationProgress(
    current_height: validator.current_height,
    snapshot_height: validator.snapshot_metadata.height,
    blocks_validated: validator.blocks_validated,
    is_caught_up: is_caught_up(validator),
  )
}

/// Verify the snapshot once background validation catches up
pub fn verify_snapshot(
  validator: BackgroundValidator,
  utxo_view: UtxoView,
) -> Result(Nil, SnapshotError) {
  case is_caught_up(validator) {
    False -> Error(ValidationFailed("Background sync not complete"))
    True -> {
      // Compute MuHash of current UTXO set
      let computed_hash = compute_utxo_hash(utxo_view)
      case bit_array_eq(computed_hash, validator.snapshot_metadata.muhash) {
        True -> Ok(Nil)
        False -> Error(HashMismatch)
      }
    }
  }
}

// ============================================================================
// MuHash Implementation (Placeholder)
// ============================================================================

/// Create new MuHash accumulator
fn muhash_new() -> MuHasher {
  MuHasher(<<0:3072>>)  // 3072-bit state for secp256k1 field
}

/// Add element to MuHash
fn muhash_add(hasher: MuHasher, outpoint: OutPoint, coin: Coin) -> MuHasher {
  // In production: proper MuHash multiplication in the field
  let element = serialize_coin(outpoint, coin)
  let element_hash = sha256(element)
  let new_state = xor_bytes(hasher.state, element_hash)
  MuHasher(new_state)
}

/// Finalize MuHash to get hash
fn muhash_finalize(hasher: MuHasher) -> BitArray {
  sha256(hasher.state)
}

/// Compute hash of entire UTXO set
fn compute_utxo_hash(_view: UtxoView) -> BitArray {
  // In production: iterate through all UTXOs and compute MuHash
  <<0:256>>
}

// ============================================================================
// Snapshot Download
// ============================================================================

/// Snapshot download state
pub type DownloadState {
  DownloadState(
    expected_hash: BitArray,
    bytes_downloaded: Int,
    total_bytes: Int,
    chunks_received: Int,
    hasher: BitArray,
  )
}

/// Create new download state
pub fn new_download(expected_hash: BitArray, total_bytes: Int) -> DownloadState {
  DownloadState(
    expected_hash: expected_hash,
    bytes_downloaded: 0,
    total_bytes: total_bytes,
    chunks_received: 0,
    hasher: <<>>,
  )
}

/// Process downloaded chunk
pub fn process_chunk(
  state: DownloadState,
  chunk: BitArray,
) -> DownloadState {
  DownloadState(
    ..state,
    bytes_downloaded: state.bytes_downloaded + bit_array.byte_size(chunk),
    chunks_received: state.chunks_received + 1,
    hasher: sha256(<<state.hasher:bits, chunk:bits>>),
  )
}

/// Check if download is complete
pub fn is_download_complete(state: DownloadState) -> Bool {
  state.bytes_downloaded >= state.total_bytes
}

/// Verify downloaded snapshot
pub fn verify_download(state: DownloadState) -> Result(Nil, SnapshotError) {
  case is_download_complete(state) {
    False -> Error(IncompleteSnapshot)
    True -> {
      case bit_array_eq(state.hasher, state.expected_hash) {
        True -> Ok(Nil)
        False -> Error(HashMismatch)
      }
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn encode_varint(n: Int) -> BitArray {
  case n {
    _ if n < 0xFD -> <<n:8>>
    _ if n <= 0xFFFF -> <<0xFD, n:16-little>>
    _ if n <= 0xFFFFFFFF -> <<0xFE, n:32-little>>
    _ -> <<0xFF, n:64-little>>
  }
}

fn parse_varint(data: BitArray) -> Result(#(Int, BitArray), Nil) {
  case data {
    <<0xFD, n:16-little, rest:bits>> -> Ok(#(n, rest))
    <<0xFE, n:32-little, rest:bits>> -> Ok(#(n, rest))
    <<0xFF, n:64-little, rest:bits>> -> Ok(#(n, rest))
    <<n:8, rest:bits>> if n < 0xFD -> Ok(#(n, rest))
    _ -> Error(Nil)
  }
}

fn extract_bytes(data: BitArray, n: Int) -> Result(#(BitArray, BitArray), Nil) {
  case bit_array.slice(data, 0, n) {
    Error(_) -> Error(Nil)
    Ok(extracted) -> {
      case bit_array.slice(data, n, bit_array.byte_size(data) - n) {
        Error(_) -> Ok(#(extracted, <<>>))
        Ok(rest) -> Ok(#(extracted, rest))
      }
    }
  }
}

fn bit_array_eq(a: BitArray, b: BitArray) -> Bool {
  a == b
}

fn sha256(data: BitArray) -> BitArray {
  crypto_hash(<<"sha256">>, data)
}

@external(erlang, "crypto", "hash")
fn crypto_hash(algorithm: BitArray, data: BitArray) -> BitArray

fn xor_bytes(a: BitArray, b: BitArray) -> BitArray {
  // XOR two byte arrays (pad shorter one)
  crypto_exor(a, b)
}

@external(erlang, "crypto", "exor")
fn crypto_exor(a: BitArray, b: BitArray) -> BitArray

fn create_block_hash(hex: String) -> BlockHash {
  case oni_bitcoin.block_hash_from_hex(hex) {
    Ok(h) -> h
    Error(_) -> oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))
  }
}

fn create_block_hash_from_bytes(bytes: BitArray) -> BlockHash {
  case oni_bitcoin.block_hash_from_bytes(bytes) {
    Ok(h) -> h
    Error(_) -> oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))
  }
}

fn block_hash_to_bytes(hash: BlockHash) -> BitArray {
  hash.hash.bytes
}

fn create_txid_from_bytes(bytes: BitArray) -> oni_bitcoin.Txid {
  case oni_bitcoin.txid_from_bytes(bytes) {
    Ok(t) -> t
    Error(_) -> oni_bitcoin.Txid(oni_bitcoin.Hash256(<<0:256>>))
  }
}

fn txid_to_bytes(txid: oni_bitcoin.Txid) -> BitArray {
  txid.hash.bytes
}
