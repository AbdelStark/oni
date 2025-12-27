// assumeutxo_test.gleam - Tests for AssumeUTXO snapshot support

import gleam/bit_array
import gleam/option.{None, Some}
import oni_storage/assumeutxo.{
  Mainnet, Regtest, Testnet,
}

// ============================================================================
// Known Snapshot Tests
// ============================================================================

pub fn mainnet_snapshots_exist_test() {
  let snapshots = assumeutxo.mainnet_snapshots()

  // Should have at least one snapshot
  assert list_length(snapshots) > 0
}

pub fn testnet_snapshots_exist_test() {
  let snapshots = assumeutxo.testnet_snapshots()

  // Should have snapshots
  assert list_length(snapshots) > 0
}

pub fn get_known_snapshots_by_network_test() {
  let mainnet = assumeutxo.get_known_snapshots(Mainnet)
  let testnet = assumeutxo.get_known_snapshots(Testnet)
  let regtest = assumeutxo.get_known_snapshots(Regtest)

  assert list_length(mainnet) > 0
  assert list_length(testnet) > 0
  // Regtest typically has no snapshots
  assert list_length(regtest) == 0
}

pub fn find_latest_snapshot_test() {
  let result = assumeutxo.find_latest_snapshot(Mainnet)

  case result {
    Some(snapshot) -> {
      // Should be a reasonable height
      assert snapshot.metadata.height > 0
      assert snapshot.metadata.num_utxos > 0
    }
    None -> assert False
  }
}

pub fn find_snapshot_at_height_test() {
  // Find a snapshot at a specific height (using the first known snapshot)
  let snapshots = assumeutxo.mainnet_snapshots()

  case snapshots {
    [first, ..] -> {
      let result = assumeutxo.find_snapshot_at_height(Mainnet, first.metadata.height)
      case result {
        Some(found) -> {
          assert found.metadata.height == first.metadata.height
        }
        None -> assert False
      }
    }
    [] -> assert False
  }
}

pub fn find_snapshot_at_invalid_height_test() {
  // Height 12345 is unlikely to have a snapshot
  let result = assumeutxo.find_snapshot_at_height(Mainnet, 12345)

  assert result == None
}

// ============================================================================
// Snapshot Loader Tests
// ============================================================================

pub fn create_new_loader_test() {
  let metadata = assumeutxo.SnapshotMetadata(
    block_hash: create_dummy_block_hash(),
    height: 820_000,
    num_utxos: 1000,
    num_txs: 500,
    total_amount: 1_000_000_000,
    muhash: <<0:256>>,
    snapshot_hash: <<0:256>>,
  )

  let loader = assumeutxo.new_loader(metadata)

  assert loader.coins_loaded == 0
  assert loader.bytes_read == 0
}

pub fn load_coin_increments_counter_test() {
  let metadata = assumeutxo.SnapshotMetadata(
    block_hash: create_dummy_block_hash(),
    height: 100,
    num_utxos: 10,
    num_txs: 5,
    total_amount: 1_000_000,
    muhash: <<0:256>>,
    snapshot_hash: <<0:256>>,
  )

  let loader = assumeutxo.new_loader(metadata)

  // Create a dummy coin
  let outpoint = create_dummy_outpoint()
  let coin = create_dummy_coin()

  let loader2 = assumeutxo.load_coin(loader, outpoint, coin)

  assert loader2.coins_loaded == 1
}

pub fn get_load_progress_test() {
  let metadata = assumeutxo.SnapshotMetadata(
    block_hash: create_dummy_block_hash(),
    height: 100,
    num_utxos: 100,
    num_txs: 50,
    total_amount: 1_000_000,
    muhash: <<0:256>>,
    snapshot_hash: <<0:256>>,
  )

  let loader = assumeutxo.new_loader(metadata)
  let progress = assumeutxo.get_load_progress(loader, 1000)

  assert progress.total_bytes == 1000
  assert progress.total_utxos == 100
  assert progress.utxos_loaded == 0
}

// ============================================================================
// Background Validator Tests
// ============================================================================

pub fn create_new_validator_test() {
  let metadata = assumeutxo.SnapshotMetadata(
    block_hash: create_dummy_block_hash(),
    height: 820_000,
    num_utxos: 1000,
    num_txs: 500,
    total_amount: 1_000_000_000,
    muhash: <<0:256>>,
    snapshot_hash: <<0:256>>,
  )

  let validator = assumeutxo.new_validator(metadata)

  assert validator.current_height == 0
  assert validator.blocks_validated == 0
}

pub fn record_validated_block_test() {
  let metadata = assumeutxo.SnapshotMetadata(
    block_hash: create_dummy_block_hash(),
    height: 100,
    num_utxos: 10,
    num_txs: 5,
    total_amount: 1_000_000,
    muhash: <<0:256>>,
    snapshot_hash: <<0:256>>,
  )

  let validator = assumeutxo.new_validator(metadata)
  let validator2 = assumeutxo.record_validated_block(
    validator,
    1,
    create_dummy_block_hash(),
  )

  assert validator2.current_height == 1
  assert validator2.blocks_validated == 1
}

pub fn is_caught_up_false_initially_test() {
  let metadata = assumeutxo.SnapshotMetadata(
    block_hash: create_dummy_block_hash(),
    height: 100,
    num_utxos: 10,
    num_txs: 5,
    total_amount: 1_000_000,
    muhash: <<0:256>>,
    snapshot_hash: <<0:256>>,
  )

  let validator = assumeutxo.new_validator(metadata)

  assert assumeutxo.is_caught_up(validator) == False
}

pub fn is_caught_up_true_when_synced_test() {
  let metadata = assumeutxo.SnapshotMetadata(
    block_hash: create_dummy_block_hash(),
    height: 10,
    num_utxos: 10,
    num_txs: 5,
    total_amount: 1_000_000,
    muhash: <<0:256>>,
    snapshot_hash: <<0:256>>,
  )

  let validator = assumeutxo.new_validator(metadata)

  // Simulate validating 10 blocks
  let validator2 = validate_n_blocks(validator, 10)

  assert assumeutxo.is_caught_up(validator2) == True
}

fn validate_n_blocks(
  validator: assumeutxo.BackgroundValidator,
  n: Int,
) -> assumeutxo.BackgroundValidator {
  case n <= 0 {
    True -> validator
    False -> {
      let new = assumeutxo.record_validated_block(
        validator,
        validator.current_height + 1,
        create_dummy_block_hash(),
      )
      validate_n_blocks(new, n - 1)
    }
  }
}

pub fn get_validation_progress_test() {
  let metadata = assumeutxo.SnapshotMetadata(
    block_hash: create_dummy_block_hash(),
    height: 100,
    num_utxos: 10,
    num_txs: 5,
    total_amount: 1_000_000,
    muhash: <<0:256>>,
    snapshot_hash: <<0:256>>,
  )

  let validator = assumeutxo.new_validator(metadata)
  let validator2 = assumeutxo.record_validated_block(
    validator,
    50,
    create_dummy_block_hash(),
  )

  let progress = assumeutxo.get_validation_progress(validator2)

  assert progress.current_height == 50
  assert progress.snapshot_height == 100
  assert progress.is_caught_up == False
}

// ============================================================================
// Serialization Tests
// ============================================================================

pub fn snapshot_header_constants_test() {
  // Verify magic bytes
  assert assumeutxo.snapshot_magic == 0x55_54_58_4F  // "UTXO"
  assert assumeutxo.snapshot_version == 1
}

pub fn serialize_header_test() {
  let header = assumeutxo.SnapshotHeader(
    magic: assumeutxo.snapshot_magic,
    version: assumeutxo.snapshot_version,
    network: 0,  // Mainnet
    block_hash: create_dummy_block_hash(),
    height: 100,
    num_utxos: 1000,
  )

  let serialized = assumeutxo.serialize_header(header)

  // Should start with magic
  case serialized {
    <<magic:32-big, _rest:bits>> -> {
      assert magic == assumeutxo.snapshot_magic
    }
    _ -> assert False
  }
}

pub fn parse_header_test() {
  let header = assumeutxo.SnapshotHeader(
    magic: assumeutxo.snapshot_magic,
    version: assumeutxo.snapshot_version,
    network: 0,
    block_hash: create_dummy_block_hash(),
    height: 100,
    num_utxos: 1000,
  )

  let serialized = assumeutxo.serialize_header(header)
  let result = assumeutxo.parse_header(serialized)

  case result {
    Ok(#(parsed, _rest)) -> {
      assert parsed.magic == header.magic
      assert parsed.version == header.version
      assert parsed.height == header.height
      assert parsed.num_utxos == header.num_utxos
    }
    Error(_) -> assert False
  }
}

pub fn parse_invalid_magic_fails_test() {
  // Wrong magic
  let data = <<0x12_34_56_78:32-big, 1:16-little, 0:8, 0:256, 100:32-little, 1000:64-little>>

  let result = assumeutxo.parse_header(data)

  case result {
    Error(assumeutxo.InvalidFormat) -> assert True
    _ -> assert False
  }
}

pub fn parse_unsupported_version_fails_test() {
  // Wrong version
  let data = <<0x55_54_58_4F:32-big, 99:16-little, 0:8, 0:256, 100:32-little, 1000:64-little>>

  let result = assumeutxo.parse_header(data)

  case result {
    Error(assumeutxo.UnsupportedVersion) -> assert True
    _ -> assert False
  }
}

// ============================================================================
// Download State Tests
// ============================================================================

pub fn new_download_test() {
  let expected_hash = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
                        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32>>
  let state = assumeutxo.new_download(expected_hash, 1_000_000)

  assert state.total_bytes == 1_000_000
  assert state.bytes_downloaded == 0
  assert state.chunks_received == 0
}

pub fn process_chunk_updates_state_test() {
  let expected_hash = <<0:256>>
  let state = assumeutxo.new_download(expected_hash, 1000)

  let chunk = <<1, 2, 3, 4, 5>>
  let state2 = assumeutxo.process_chunk(state, chunk)

  assert state2.bytes_downloaded == 5
  assert state2.chunks_received == 1
}

pub fn is_download_complete_false_initially_test() {
  let state = assumeutxo.new_download(<<0:256>>, 1000)

  assert assumeutxo.is_download_complete(state) == False
}

pub fn is_download_complete_true_when_done_test() {
  let state = assumeutxo.new_download(<<0:256>>, 10)

  // Download 10 bytes
  let chunk = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
  let state2 = assumeutxo.process_chunk(state, chunk)

  assert assumeutxo.is_download_complete(state2) == True
}

// ============================================================================
// Helper Functions
// ============================================================================

fn create_dummy_block_hash() -> oni_bitcoin.BlockHash {
  case oni_bitcoin.block_hash_from_hex("0000000000000000000000000000000000000000000000000000000000000000") {
    Ok(h) -> h
    Error(_) -> oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))
  }
}

fn create_dummy_outpoint() -> oni_bitcoin.OutPoint {
  let txid = oni_bitcoin.Txid(oni_bitcoin.Hash256(<<0:256>>))
  oni_bitcoin.outpoint_new(txid, 0)
}

fn create_dummy_coin() -> oni_storage.Coin {
  let script = oni_bitcoin.script_from_bytes(<<0x00, 0x14, 0:160>>)
  let amount = case oni_bitcoin.amount_from_sats(1000) {
    Ok(a) -> a
    Error(_) -> oni_bitcoin.Amount(0)
  }
  let output = oni_bitcoin.TxOut(value: amount, script_pubkey: script)
  oni_storage.coin_new(output, 1, False)
}

fn list_length(list: List(a)) -> Int {
  case list {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

import oni_bitcoin
import oni_storage
