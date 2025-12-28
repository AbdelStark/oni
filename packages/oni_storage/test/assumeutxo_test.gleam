// assumeutxo_test.gleam - Tests for AssumeUTXO snapshot support

import gleam/option.{None, Some}
import assumeutxo.{
  Mainnet, Regtest, Testnet,
}

// ============================================================================
// Known Snapshot Tests
// ============================================================================

pub fn mainnet_snapshots_exist_test() {
  let snapshots = assumeutxo.mainnet_snapshots()

  // Should have at least one snapshot
  let assert True = list_length(snapshots) > 0
}

pub fn testnet_snapshots_exist_test() {
  let snapshots = assumeutxo.testnet_snapshots()

  // Should have snapshots
  let assert True = list_length(snapshots) > 0
}

pub fn get_known_snapshots_by_network_test() {
  let mainnet = assumeutxo.get_known_snapshots(Mainnet)
  let testnet = assumeutxo.get_known_snapshots(Testnet)
  let regtest = assumeutxo.get_known_snapshots(Regtest)

  let assert True = list_length(mainnet) > 0
  let assert True = list_length(testnet) > 0
  // Regtest typically has no snapshots
  let assert True = list_length(regtest) == 0
}

pub fn find_latest_snapshot_test() {
  let result = assumeutxo.find_latest_snapshot(Mainnet)

  case result {
    Some(snapshot) -> {
      // Should be a reasonable height
      let assert True = snapshot.metadata.height > 0
      let assert True = snapshot.metadata.num_utxos > 0
    }
    None -> panic as "Should find latest mainnet snapshot"
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
          let assert True = found.metadata.height == first.metadata.height
        }
        None -> panic as "Should find snapshot at known height"
      }
    }
    [] -> panic as "Should have mainnet snapshots"
  }
}

pub fn find_snapshot_at_invalid_height_test() {
  // Height 12345 is unlikely to have a snapshot
  let result = assumeutxo.find_snapshot_at_height(Mainnet, 12345)

  let assert True = result == None
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

  let assert True = loader.coins_loaded == 0
  let assert True = loader.bytes_read == 0
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

  let assert True = loader2.coins_loaded == 1
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

  let assert True = progress.total_bytes == 1000
  let assert True = progress.total_utxos == 100
  let assert True = progress.utxos_loaded == 0
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

  let assert True = validator.current_height == 0
  let assert True = validator.blocks_validated == 0
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

  let assert True = validator2.current_height == 1
  let assert True = validator2.blocks_validated == 1
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

  let assert True = assumeutxo.is_caught_up(validator) == False
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

  let assert True = assumeutxo.is_caught_up(validator2) == True
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

  let assert True = progress.current_height == 50
  let assert True = progress.snapshot_height == 100
  let assert True = progress.is_caught_up == False
}

// ============================================================================
// Serialization Tests
// ============================================================================

pub fn snapshot_header_constants_test() {
  // Verify magic bytes
  let assert True = assumeutxo.snapshot_magic == 0x55_54_58_4F  // "UTXO"
  let assert True = assumeutxo.snapshot_version == 1
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
      let assert True = magic == assumeutxo.snapshot_magic
    }
    _ -> panic as "Serialized header should start with magic"
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
      let assert True = parsed.magic == header.magic
      let assert True = parsed.version == header.version
      let assert True = parsed.height == header.height
      let assert True = parsed.num_utxos == header.num_utxos
    }
    Error(_) -> panic as "Should parse valid header"
  }
}

pub fn parse_invalid_magic_fails_test() {
  // Wrong magic
  let data = <<0x12_34_56_78:32-big, 1:16-little, 0:8, 0:256, 100:32-little, 1000:64-little>>

  let result = assumeutxo.parse_header(data)

  case result {
    Error(assumeutxo.InvalidFormat) -> Nil
    _ -> panic as "Should fail with invalid magic"
  }
}

pub fn parse_unsupported_version_fails_test() {
  // Wrong version
  let data = <<0x55_54_58_4F:32-big, 99:16-little, 0:8, 0:256, 100:32-little, 1000:64-little>>

  let result = assumeutxo.parse_header(data)

  case result {
    Error(assumeutxo.UnsupportedVersion) -> Nil
    _ -> panic as "Should fail with unsupported version"
  }
}

// ============================================================================
// Download State Tests
// ============================================================================

pub fn new_download_test() {
  let expected_hash = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
                        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32>>
  let state = assumeutxo.new_download(expected_hash, 1_000_000)

  let assert True = state.total_bytes == 1_000_000
  let assert True = state.bytes_downloaded == 0
  let assert True = state.chunks_received == 0
}

pub fn process_chunk_updates_state_test() {
  let expected_hash = <<0:256>>
  let state = assumeutxo.new_download(expected_hash, 1000)

  let chunk = <<1, 2, 3, 4, 5>>
  let state2 = assumeutxo.process_chunk(state, chunk)

  let assert True = state2.bytes_downloaded == 5
  let assert True = state2.chunks_received == 1
}

pub fn is_download_complete_false_initially_test() {
  let state = assumeutxo.new_download(<<0:256>>, 1000)

  let assert True = assumeutxo.is_download_complete(state) == False
}

pub fn is_download_complete_true_when_done_test() {
  let state = assumeutxo.new_download(<<0:256>>, 10)

  // Download 10 bytes
  let chunk = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
  let state2 = assumeutxo.process_chunk(state, chunk)

  let assert True = assumeutxo.is_download_complete(state2) == True
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
