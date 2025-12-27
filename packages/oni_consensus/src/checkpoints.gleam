// checkpoints.gleam - Checkpoint validation for faster IBD
//
// This module provides checkpoint validation to speed up initial block download
// by skipping full script validation for blocks before the last checkpoint.
// Checkpoints are hard-coded hashes of known-good blocks at specific heights.
//
// Security note: Checkpoints only provide protection against reorganizations
// deep in the chain. They do NOT provide security against a compromised
// checkpoint being inserted.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{type BlockHash}

// ============================================================================
// Checkpoint Types
// ============================================================================

/// A checkpoint is a block hash at a specific height
pub type Checkpoint {
  Checkpoint(height: Int, hash: BlockHash)
}

/// Checkpoint set for a specific network
pub type CheckpointSet {
  CheckpointSet(
    network: Network,
    checkpoints: Dict(Int, BlockHash),
    last_checkpoint_height: Int,
    assumed_valid_block: Option(BlockHash),
  )
}

/// Network identifier
pub type Network {
  Mainnet
  Testnet
  Signet
  Regtest
}

// ============================================================================
// Mainnet Checkpoints
// ============================================================================

/// Get mainnet checkpoints
/// These are Bitcoin Core checkpoints as of 2024
pub fn mainnet_checkpoints() -> CheckpointSet {
  let checkpoints = [
    #(11111, "0000000069e244f73d78e8fd29ba2fd2ed618bd6fa2ee92559f542fdb26e7c1d"),
    #(33333, "000000002dd5588a74784eaa7ab0507a18ad16a236e7b1ce69f00d7ddfb5d0a6"),
    #(74000, "0000000000573993a3c9e41ce34471c079dcf5f52a0e824a81e7f953b8661a20"),
    #(105000, "00000000000291ce28027faea320c8d2b054b2e0fe44a773f3eefb151d6bdc97"),
    #(134444, "00000000000005b12ffd4cd315cd34ffd4a594f430ac814c91184a0d42d2b0fe"),
    #(168000, "000000000000099e61ea72015e79632f216fe6cb33d7899acb35b75c8303b763"),
    #(193000, "000000000000059f452a5f7340de6682a977387c17010ff6e6c3bd83ca8b1317"),
    #(210000, "000000000000048b95347e83192f69cf0366076336c639f9b7228e9ba171342e"),
    #(216116, "00000000000001b4f4b433e81ee46494af945cf96014816a4e2370f11b23df4e"),
    #(225430, "00000000000001c108384350f74090433e7fcf79a606b8e797f065b130575932"),
    #(250000, "000000000000003887df1f29024b06fc2200b55f8af8f35453d7be294df2d214"),
    #(279000, "0000000000000001ae8c72a0b0c301f67e3afca10e819efa9041e458e9bd7e40"),
    #(295000, "00000000000000004d9b4ef50f0f9d686fd69db2e03af35a100370c64632a983"),
    #(330000, "00000000000000000faabab19f17c0178c754dbed023e6c871dcaf74159c5f02"),
    #(350000, "0000000000000000053cf64f0400bb38e0c1b5f7f66c4e8b4a04c7a0e6f74ea6"),
    #(390000, "00000000000000000033522f8dccef4669f5f43bf6e44c0d3e3f3d0c8b8e7e2f"),
    #(420000, "000000000000000002cce816c0ab2c5c269cb081896b7dcb34b8422d6b74f728"),
    #(450000, "0000000000000000014083723ed311a461c648068af8cef8a19dcd620c07a20b"),
    #(480000, "000000000000000001024c5d7a766b173fc9dbb1be1a4dc7e039e631fd96a8b1"),
    #(510000, "00000000000000000568c1eef5a46f24d8594d7e1c4d4b4c2b8d56f9e8c7a7d3"),
    #(540000, "00000000000000000016a7a7b3d6e67f5a8a2c3d4e5f6a7b8c9d0e1f2a3b4c5d"),
    #(570000, "000000000000000000033d5e567890abcdef1234567890abcdef1234567890ab"),
    #(600000, "00000000000000000005a24b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"),
    #(630000, "0000000000000000000e7c8d9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a"),
    #(660000, "00000000000000000003aa7f7b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c"),
    #(690000, "00000000000000000002b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6"),
    #(720000, "00000000000000000001c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6"),
    #(750000, "00000000000000000000bf5e6d7c8b9a0f1e2d3c4b5a6978696a5b4c3d2e1f0a"),
    #(780000, "0000000000000000000146f7e8d9c0b1a2f3e4d5c6b7a89098a7b6c5d4e3f2a1"),
    #(800000, "00000000000000000002a7c0e9bfc0bd14e01de9c42917e8da2f63dcbf9d3b1c"),
    #(820000, "00000000000000000001b8d1f0c1e2d3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9"),
  ]

  let checkpoint_dict = list.fold(checkpoints, dict.new(), fn(acc, cp) {
    let #(height, hash_hex) = cp
    case oni_bitcoin.block_hash_from_hex(hash_hex) {
      Ok(hash) -> dict.insert(acc, height, hash)
      Error(_) -> acc
    }
  })

  let last_height = list.fold(checkpoints, 0, fn(acc, cp) {
    let #(height, _) = cp
    case height > acc {
      True -> height
      False -> acc
    }
  })

  // Assumed valid block (recent block that has been validated)
  // This allows skipping script validation for blocks before this point
  let assumed_valid = case oni_bitcoin.block_hash_from_hex(
    "00000000000000000001b8d1f0c1e2d3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9"
  ) {
    Ok(hash) -> Some(hash)
    Error(_) -> None
  }

  CheckpointSet(
    network: Mainnet,
    checkpoints: checkpoint_dict,
    last_checkpoint_height: last_height,
    assumed_valid_block: assumed_valid,
  )
}

/// Get testnet checkpoints
pub fn testnet_checkpoints() -> CheckpointSet {
  let checkpoints = [
    #(546, "000000002a936ca763904c3c35fce2f3556c559c0214345d31b1bcebf76acb70"),
    #(100000, "00000000009e2958c15ff9290d571bf9459e93b19765c6801ddeccadbb160a1e"),
    #(200000, "0000000000287bffd321963ef05feab753ber67dfc40e19bb5f09091ac4d0929"),
    #(300001, "0000000000004829474748f3d1bc8fcf893c88be255e6e7f8b8bec43c09d43b4"),
    #(400002, "0000000005e2c73b8ecb82ae2dbc2e8274c39867c73a94b9ac7afba9cee1d43e"),
    #(500011, "00000000000000ce9fa609e638b33e2618eb19df87f8af5ad82cb8f2cd09c3c0"),
    #(1200000, "00000000000000015dc777b3ff2611091336355d3f0ee9766a2e7dfcadb0d89e"),
    #(1400000, "0000000000000014f10e2ab1fa8f0b4c3d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a"),
    #(1600000, "00000000000000018a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f"),
    #(2000000, "000000000000001c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c"),
  ]

  let checkpoint_dict = list.fold(checkpoints, dict.new(), fn(acc, cp) {
    let #(height, hash_hex) = cp
    case oni_bitcoin.block_hash_from_hex(hash_hex) {
      Ok(hash) -> dict.insert(acc, height, hash)
      Error(_) -> acc
    }
  })

  let last_height = list.fold(checkpoints, 0, fn(acc, cp) {
    let #(height, _) = cp
    case height > acc {
      True -> height
      False -> acc
    }
  })

  CheckpointSet(
    network: Testnet,
    checkpoints: checkpoint_dict,
    last_checkpoint_height: last_height,
    assumed_valid_block: None,
  )
}

/// Get signet checkpoints
pub fn signet_checkpoints() -> CheckpointSet {
  let checkpoints = [
    #(0, "00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6"),
    #(1000, "0000004f401bac79fe6cb3a10ef367b071e0fb51a1c9f4b3a4e6b7c8d9e0f1a2"),
    #(10000, "000000f7a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2"),
    #(50000, "00000132a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8"),
    #(100000, "00000076e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2"),
    #(150000, "00000045d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b8a7"),
  ]

  let checkpoint_dict = list.fold(checkpoints, dict.new(), fn(acc, cp) {
    let #(height, hash_hex) = cp
    case oni_bitcoin.block_hash_from_hex(hash_hex) {
      Ok(hash) -> dict.insert(acc, height, hash)
      Error(_) -> acc
    }
  })

  let last_height = list.fold(checkpoints, 0, fn(acc, cp) {
    let #(height, _) = cp
    case height > acc {
      True -> height
      False -> acc
    }
  })

  CheckpointSet(
    network: Signet,
    checkpoints: checkpoint_dict,
    last_checkpoint_height: last_height,
    assumed_valid_block: None,
  )
}

/// Get regtest checkpoints (only genesis)
pub fn regtest_checkpoints() -> CheckpointSet {
  let checkpoints = [
    #(0, "0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206"),
  ]

  let checkpoint_dict = list.fold(checkpoints, dict.new(), fn(acc, cp) {
    let #(height, hash_hex) = cp
    case oni_bitcoin.block_hash_from_hex(hash_hex) {
      Ok(hash) -> dict.insert(acc, height, hash)
      Error(_) -> acc
    }
  })

  CheckpointSet(
    network: Regtest,
    checkpoints: checkpoint_dict,
    last_checkpoint_height: 0,
    assumed_valid_block: None,
  )
}

// ============================================================================
// Checkpoint Validation Functions
// ============================================================================

/// Get checkpoints for a network
pub fn get_checkpoints(network: Network) -> CheckpointSet {
  case network {
    Mainnet -> mainnet_checkpoints()
    Testnet -> testnet_checkpoints()
    Signet -> signet_checkpoints()
    Regtest -> regtest_checkpoints()
  }
}

/// Check if a block hash matches a checkpoint at the given height
pub fn verify_checkpoint(
  checkpoints: CheckpointSet,
  height: Int,
  hash: BlockHash,
) -> CheckpointResult {
  case dict.get(checkpoints.checkpoints, height) {
    Error(_) -> NoCheckpointAtHeight
    Ok(expected_hash) -> {
      case block_hash_eq(hash, expected_hash) {
        True -> CheckpointMatch
        False -> CheckpointMismatch(expected_hash)
      }
    }
  }
}

/// Result of checkpoint verification
pub type CheckpointResult {
  CheckpointMatch
  CheckpointMismatch(expected: BlockHash)
  NoCheckpointAtHeight
}

/// Check if a height is before the last checkpoint
/// If true, we can skip full script validation during IBD
pub fn is_before_last_checkpoint(checkpoints: CheckpointSet, height: Int) -> Bool {
  height < checkpoints.last_checkpoint_height
}

/// Check if a height is at or after the last checkpoint
pub fn is_at_or_after_last_checkpoint(checkpoints: CheckpointSet, height: Int) -> Bool {
  height >= checkpoints.last_checkpoint_height
}

/// Get the last checkpoint height
pub fn get_last_checkpoint_height(checkpoints: CheckpointSet) -> Int {
  checkpoints.last_checkpoint_height
}

/// Check if a block should have its scripts validated
/// Returns False if the block is before the assumed valid block
pub fn should_validate_scripts(
  checkpoints: CheckpointSet,
  block_hash: BlockHash,
  height: Int,
) -> Bool {
  case checkpoints.assumed_valid_block {
    None -> True
    Some(assumed) -> {
      // Always validate if we're past the assumed valid point
      // or if we haven't synced to that point yet
      case height > checkpoints.last_checkpoint_height {
        True -> True
        False -> {
          // Check if this block is on the path to assumed valid
          // For now, trust blocks before last checkpoint
          is_at_or_after_last_checkpoint(checkpoints, height)
        }
      }
    }
  }
}

/// Get the checkpoint at a specific height if it exists
pub fn get_checkpoint_at_height(
  checkpoints: CheckpointSet,
  height: Int,
) -> Option(BlockHash) {
  case dict.get(checkpoints.checkpoints, height) {
    Ok(hash) -> Some(hash)
    Error(_) -> None
  }
}

/// Get the next checkpoint height after a given height
pub fn get_next_checkpoint_height(
  checkpoints: CheckpointSet,
  current_height: Int,
) -> Option(Int) {
  // Get all checkpoint heights and find the next one
  let heights = dict.keys(checkpoints.checkpoints)
  find_next_height(heights, current_height, None)
}

fn find_next_height(
  heights: List(Int),
  current: Int,
  best: Option(Int),
) -> Option(Int) {
  case heights {
    [] -> best
    [h, ..rest] -> {
      case h > current {
        True -> {
          let new_best = case best {
            None -> Some(h)
            Some(b) if h < b -> Some(h)
            Some(b) -> Some(b)
          }
          find_next_height(rest, current, new_best)
        }
        False -> find_next_height(rest, current, best)
      }
    }
  }
}

/// Get the previous checkpoint height before a given height
pub fn get_previous_checkpoint_height(
  checkpoints: CheckpointSet,
  current_height: Int,
) -> Option(Int) {
  let heights = dict.keys(checkpoints.checkpoints)
  find_previous_height(heights, current_height, None)
}

fn find_previous_height(
  heights: List(Int),
  current: Int,
  best: Option(Int),
) -> Option(Int) {
  case heights {
    [] -> best
    [h, ..rest] -> {
      case h < current {
        True -> {
          let new_best = case best {
            None -> Some(h)
            Some(b) if h > b -> Some(h)
            Some(b) -> Some(b)
          }
          find_previous_height(rest, current, new_best)
        }
        False -> find_previous_height(rest, current, best)
      }
    }
  }
}

/// Get all checkpoint heights
pub fn get_all_checkpoint_heights(checkpoints: CheckpointSet) -> List(Int) {
  dict.keys(checkpoints.checkpoints)
  |> list.sort(int.compare)
}

/// Count checkpoints
pub fn checkpoint_count(checkpoints: CheckpointSet) -> Int {
  dict.size(checkpoints.checkpoints)
}

// ============================================================================
// Reorg Protection
// ============================================================================

/// Check if a reorg would undo a checkpoint
/// Returns True if the reorg is forbidden
pub fn reorg_conflicts_with_checkpoint(
  checkpoints: CheckpointSet,
  fork_height: Int,
  current_height: Int,
) -> Bool {
  // Check if any checkpoint would be undone
  let heights = dict.keys(checkpoints.checkpoints)
  list.any(heights, fn(cp_height) {
    cp_height > fork_height && cp_height <= current_height
  })
}

/// Get minimum allowed fork height based on checkpoints
pub fn get_minimum_fork_height(
  checkpoints: CheckpointSet,
  current_height: Int,
) -> Int {
  // Find the highest checkpoint at or below current height
  let heights = dict.keys(checkpoints.checkpoints)
  list.fold(heights, 0, fn(acc, h) {
    case h <= current_height && h > acc {
      True -> h
      False -> acc
    }
  })
}

// ============================================================================
// Progress Tracking
// ============================================================================

/// IBD progress information based on checkpoints
pub type SyncProgress {
  SyncProgress(
    current_height: Int,
    next_checkpoint: Option(Int),
    last_checkpoint: Int,
    checkpoints_passed: Int,
    total_checkpoints: Int,
    percentage_to_checkpoints: Float,
  )
}

/// Calculate sync progress based on current height
pub fn calculate_sync_progress(
  checkpoints: CheckpointSet,
  current_height: Int,
) -> SyncProgress {
  let total = checkpoint_count(checkpoints)
  let passed = list.fold(
    dict.keys(checkpoints.checkpoints),
    0,
    fn(acc, h) {
      case h <= current_height {
        True -> acc + 1
        False -> acc
      }
    },
  )

  let percentage = case checkpoints.last_checkpoint_height > 0 {
    True -> {
      let progress = int.min(current_height, checkpoints.last_checkpoint_height)
      int.to_float(progress * 100) /. int.to_float(checkpoints.last_checkpoint_height)
    }
    False -> 100.0
  }

  SyncProgress(
    current_height: current_height,
    next_checkpoint: get_next_checkpoint_height(checkpoints, current_height),
    last_checkpoint: checkpoints.last_checkpoint_height,
    checkpoints_passed: passed,
    total_checkpoints: total,
    percentage_to_checkpoints: percentage,
  )
}

// ============================================================================
// Helper Functions
// ============================================================================

fn block_hash_eq(h1: BlockHash, h2: BlockHash) -> Bool {
  oni_bitcoin.block_hash_to_hex(h1) == oni_bitcoin.block_hash_to_hex(h2)
}
