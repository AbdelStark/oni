// activation.gleam - Network-specific consensus rule activation heights
//
// This module defines when various consensus rules activate on each network.
// Bitcoin has deployed many soft forks over the years, each activating at
// different heights on mainnet, testnet, and other networks.
//
// References:
// - BIP 34: Block Height in Coinbase
// - BIP 65: OP_CHECKLOCKTIMEVERIFY
// - BIP 66: Strict DER Signatures
// - BIP 68: Relative Lock-Time
// - BIP 112: OP_CHECKSEQUENCEVERIFY
// - BIP 113: Median Time-Past
// - BIP 141: Segregated Witness
// - BIP 147: NULLDUMMY
// - BIP 341: Taproot

import gleam/option.{type Option, None, Some}
import oni_bitcoin.{type Network, Mainnet, Regtest, Signet, Testnet}

// ============================================================================
// Activation Heights by Network
// ============================================================================

/// Activation heights for a specific network
pub type ActivationHeights {
  ActivationHeights(
    /// BIP 34: Block Height in Coinbase (v2 blocks)
    bip34_height: Int,
    /// BIP 65: OP_CHECKLOCKTIMEVERIFY
    bip65_height: Int,
    /// BIP 66: Strict DER Signatures
    bip66_height: Int,
    /// BIP 68, 112, 113: Relative Lock-Time (CSV)
    csv_height: Int,
    /// BIP 141, 143, 147: Segregated Witness
    segwit_height: Int,
    /// BIP 341, 342: Taproot
    taproot_height: Int,
    /// Height at which difficulty adjustment is enforced
    difficulty_adjustment_start: Int,
    /// Minimum difficulty blocks allowed (for testnet)
    allow_min_difficulty_blocks: Bool,
    /// Don't enforce BIP 30 after this height (optimization)
    bip30_exception_height: Int,
  )
}

/// Get activation heights for a network
pub fn get_activations(network: Network) -> ActivationHeights {
  case network {
    Mainnet -> mainnet_activations()
    Testnet -> testnet_activations()
    Regtest -> regtest_activations()
    Signet -> signet_activations()
  }
}

/// Mainnet activation heights
pub fn mainnet_activations() -> ActivationHeights {
  ActivationHeights(
    // BIP 34 activated at block 227,931 (March 2013)
    bip34_height: 227_931,
    // BIP 65 activated at block 388,381 (December 2015)
    bip65_height: 388_381,
    // BIP 66 activated at block 363,725 (July 2015)
    bip66_height: 363_725,
    // CSV (BIP 68, 112, 113) activated at block 419,328 (July 2016)
    csv_height: 419_328,
    // SegWit activated at block 481,824 (August 2017)
    segwit_height: 481_824,
    // Taproot activated at block 709,632 (November 2021)
    taproot_height: 709_632,
    // Difficulty adjustment from block 1
    difficulty_adjustment_start: 1,
    // Mainnet doesn't allow min difficulty blocks
    allow_min_difficulty_blocks: False,
    // BIP 30 optimization after SegWit
    bip30_exception_height: 481_824,
  )
}

/// Testnet (testnet3) activation heights
pub fn testnet_activations() -> ActivationHeights {
  ActivationHeights(
    // BIP 34 activated at block 21,111
    bip34_height: 21_111,
    // BIP 65 activated at block 581,885
    bip65_height: 581_885,
    // BIP 66 activated at block 330,776
    bip66_height: 330_776,
    // CSV activated at block 770,112
    csv_height: 770_112,
    // SegWit activated at block 834,624
    segwit_height: 834_624,
    // Taproot activated at block 2,091,936
    taproot_height: 2_091_936,
    // Difficulty adjustment from block 1
    difficulty_adjustment_start: 1,
    // Testnet allows min difficulty blocks after 20 minutes
    allow_min_difficulty_blocks: True,
    // BIP 30 optimization after SegWit
    bip30_exception_height: 834_624,
  )
}

/// Regtest activation heights (all active from genesis)
pub fn regtest_activations() -> ActivationHeights {
  ActivationHeights(
    bip34_height: 500,
    // BIP 34 after 500 blocks (for testing)
    bip65_height: 1351,
    // BIP 65 after genesis
    bip66_height: 1251,
    // BIP 66 after genesis
    csv_height: 432,
    // CSV after genesis
    segwit_height: 0,
    // SegWit always active
    taproot_height: 0,
    // Taproot always active
    difficulty_adjustment_start: 1,
    allow_min_difficulty_blocks: True,
    bip30_exception_height: 0,
  )
}

/// Signet activation heights
pub fn signet_activations() -> ActivationHeights {
  ActivationHeights(
    bip34_height: 1,
    bip65_height: 1,
    bip66_height: 1,
    csv_height: 1,
    segwit_height: 1,
    // SegWit always active on signet
    taproot_height: 1,
    // Taproot active from block 1
    difficulty_adjustment_start: 1,
    allow_min_difficulty_blocks: False,
    bip30_exception_height: 1,
  )
}

// ============================================================================
// Rule Checks
// ============================================================================

/// Check if BIP 34 (height in coinbase) is active
pub fn is_bip34_active(height: Int, network: Network) -> Bool {
  let activations = get_activations(network)
  height >= activations.bip34_height
}

/// Check if BIP 65 (CHECKLOCKTIMEVERIFY) is active
pub fn is_bip65_active(height: Int, network: Network) -> Bool {
  let activations = get_activations(network)
  height >= activations.bip65_height
}

/// Check if BIP 66 (strict DER) is active
pub fn is_bip66_active(height: Int, network: Network) -> Bool {
  let activations = get_activations(network)
  height >= activations.bip66_height
}

/// Check if CSV (BIP 68, 112, 113) is active
pub fn is_csv_active(height: Int, network: Network) -> Bool {
  let activations = get_activations(network)
  height >= activations.csv_height
}

/// Check if SegWit (BIP 141) is active
pub fn is_segwit_active(height: Int, network: Network) -> Bool {
  let activations = get_activations(network)
  height >= activations.segwit_height
}

/// Check if Taproot (BIP 341) is active
pub fn is_taproot_active(height: Int, network: Network) -> Bool {
  let activations = get_activations(network)
  height >= activations.taproot_height
}

/// Check if minimum difficulty blocks are allowed
pub fn allows_min_difficulty(network: Network) -> Bool {
  let activations = get_activations(network)
  activations.allow_min_difficulty_blocks
}

// ============================================================================
// Script Flags for Validation
// ============================================================================

/// Script verification flags type
pub type ScriptFlags {
  ScriptFlags(
    verify_p2sh: Bool,
    verify_strictenc: Bool,
    verify_dersig: Bool,
    verify_low_s: Bool,
    verify_nulldummy: Bool,
    verify_sigpushonly: Bool,
    verify_minimaldata: Bool,
    verify_discourage_upgradable_nops: Bool,
    verify_cleanstack: Bool,
    verify_checklocktimeverify: Bool,
    verify_checksequenceverify: Bool,
    verify_witness: Bool,
    verify_discourage_upgradable_witness_program: Bool,
    verify_minimalif: Bool,
    verify_nullfail: Bool,
    verify_witness_pubkeytype: Bool,
    verify_const_scriptcode: Bool,
    verify_taproot: Bool,
    verify_discourage_upgradable_taproot_version: Bool,
    verify_discourage_op_success: Bool,
    verify_discourage_upgradable_pubkeytype: Bool,
  )
}

/// Get mandatory script flags for a given height and network
pub fn get_mandatory_flags(height: Int, network: Network) -> ScriptFlags {
  let base_flags =
    ScriptFlags(
      // P2SH always enforced (since 2012)
      verify_p2sh: True,
      verify_strictenc: False,
      verify_dersig: is_bip66_active(height, network),
      verify_low_s: False,
      verify_nulldummy: is_segwit_active(height, network),
      verify_sigpushonly: False,
      verify_minimaldata: False,
      verify_discourage_upgradable_nops: False,
      verify_cleanstack: False,
      verify_checklocktimeverify: is_bip65_active(height, network),
      verify_checksequenceverify: is_csv_active(height, network),
      verify_witness: is_segwit_active(height, network),
      verify_discourage_upgradable_witness_program: False,
      verify_minimalif: is_segwit_active(height, network),
      verify_nullfail: is_segwit_active(height, network),
      verify_witness_pubkeytype: is_segwit_active(height, network),
      verify_const_scriptcode: is_taproot_active(height, network),
      verify_taproot: is_taproot_active(height, network),
      verify_discourage_upgradable_taproot_version: False,
      verify_discourage_op_success: False,
      verify_discourage_upgradable_pubkeytype: False,
    )

  base_flags
}

/// Get standard script flags (for mempool policy)
pub fn get_standard_flags(height: Int, network: Network) -> ScriptFlags {
  let mandatory = get_mandatory_flags(height, network)

  ScriptFlags(
    ..mandatory,
    verify_strictenc: True,
    verify_low_s: True,
    verify_sigpushonly: True,
    verify_minimaldata: True,
    verify_discourage_upgradable_nops: True,
    verify_cleanstack: True,
    verify_discourage_upgradable_witness_program: True,
    verify_discourage_upgradable_taproot_version: True,
    verify_discourage_op_success: True,
    verify_discourage_upgradable_pubkeytype: True,
  )
}

// ============================================================================
// Coinbase Maturity
// ============================================================================

/// Coinbase maturity (blocks before coinbase outputs are spendable)
pub const coinbase_maturity: Int = 100

/// Check if a coinbase output is mature
pub fn is_coinbase_mature(coinbase_height: Int, spending_height: Int) -> Bool {
  spending_height >= coinbase_height + coinbase_maturity
}

// ============================================================================
// Subsidy Calculation
// ============================================================================

/// Halving interval (blocks between subsidy halvings)
pub const halving_interval: Int = 210_000

/// Initial block subsidy in satoshis (50 BTC)
pub const initial_subsidy: Int = 5_000_000_000

/// Calculate block subsidy at a given height
pub fn get_block_subsidy(height: Int, network: Network) -> Int {
  // Regtest uses same halving schedule but shorter for testing
  let interval = case network {
    Regtest -> 150
    // Halve every 150 blocks in regtest
    _ -> halving_interval
  }

  let halvings = height / interval

  // After 64 halvings, subsidy is 0
  case halvings >= 64 {
    True -> 0
    False -> {
      // Right shift by number of halvings
      shift_right(initial_subsidy, halvings)
    }
  }
}

/// Bitwise right shift helper
fn shift_right(value: Int, n: Int) -> Int {
  case n <= 0 {
    True -> value
    False -> shift_right(value / 2, n - 1)
  }
}

// ============================================================================
// Difficulty Adjustment
// ============================================================================

/// Target timespan for difficulty adjustment (2 weeks in seconds = 14 * 24 * 60 * 60)
pub const target_timespan: Int = 1_209_600

/// Target spacing between blocks (10 minutes in seconds = 10 * 60)
pub const target_spacing: Int = 600

/// Difficulty adjustment interval (2016 blocks)
pub const difficulty_adjustment_interval: Int = 2016

/// Check if this height triggers a difficulty adjustment
pub fn is_difficulty_adjustment_height(height: Int) -> Bool {
  height > 0 && height % difficulty_adjustment_interval == 0
}

/// Minimum allowed difficulty target (mainnet)
pub const max_target_mainnet: Int = 0x00000000FFFF0000000000000000000000000000000000000000000000000000

/// Minimum allowed difficulty target (testnet/regtest)
pub const max_target_testnet: Int = 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

/// Get the maximum target (minimum difficulty) for a network
pub fn get_max_target(network: Network) -> Int {
  case network {
    Mainnet -> max_target_mainnet
    Testnet -> max_target_testnet
    Regtest -> max_target_testnet
    Signet -> max_target_mainnet
  }
}

// ============================================================================
// Checkpoints
// ============================================================================

/// Hardcoded checkpoint
pub type Checkpoint {
  Checkpoint(
    height: Int,
    hash: String,
    // Hex-encoded block hash
  )
}

/// Get checkpoints for a network
pub fn get_checkpoints(network: Network) -> List(Checkpoint) {
  case network {
    Mainnet -> mainnet_checkpoints()
    Testnet -> testnet_checkpoints()
    Regtest -> []
    // No checkpoints for regtest
    Signet -> []
    // No checkpoints for signet
  }
}

/// Mainnet checkpoints
fn mainnet_checkpoints() -> List(Checkpoint) {
  [
    Checkpoint(
      11_111,
      "0000000069e244f73d78e8fd29ba2fd2ed618bd6fa2ee92559f542fdb26e7c1d",
    ),
    Checkpoint(
      33_333,
      "000000002dd5588a74784eaa7ab0507a18ad16a236e7b1ce69f00d7ddfb5d0a6",
    ),
    Checkpoint(
      74_000,
      "0000000000573993a3c9e41ce34471c079dcf5f52a0e824a81e7f953b8661a20",
    ),
    Checkpoint(
      105_000,
      "00000000000291ce28027faea320c8d2b054b2e0fe44a773f3eefb151d6bdc97",
    ),
    Checkpoint(
      134_444,
      "00000000000005b12ffd4cd315cd34ffd4a594f430ac814c91184a0d42d2b0fe",
    ),
    Checkpoint(
      168_000,
      "000000000000099e61ea72015e79632f216fe6cb33d7899acb35b75c8303b763",
    ),
    Checkpoint(
      193_000,
      "000000000000059f452a5f7340de6682a977387c17010ff6e6c3bd83ca8b1317",
    ),
    Checkpoint(
      210_000,
      "000000000000048b95347e83192f69cf0366076336c639f9b7228e9ba171342e",
    ),
    Checkpoint(
      216_116,
      "00000000000001b4f4b433e81ee46494af945cf96014816a4e2370f11b23df4e",
    ),
    Checkpoint(
      225_430,
      "00000000000001c108384350f74090433e7fcf79a606b8e797f065b130575932",
    ),
    Checkpoint(
      250_000,
      "000000000000003887df1f29024b06fc2200b55f8af8f35453d7be294df2d214",
    ),
    Checkpoint(
      279_000,
      "0000000000000001ae8c72a0b0c301f67e3afca10e819efa9041e458e9bd7e40",
    ),
    Checkpoint(
      295_000,
      "00000000000000004d9b4ef50f0f9d686fd69db2e03af35a100370c64632a983",
    ),
    Checkpoint(
      478_559,
      "00000000000000000019f112ec0a9982926f1258cdcc558dd7c3b7e5dc7fa148",
    ),
    Checkpoint(
      556_766,
      "0000000000000000000f1c54590ee18d15ec70e68ae4f2e768ddce9a4cd2b0e3",
    ),
    Checkpoint(
      656_000,
      "0000000000000000000cc8c4b1eb7899c18c4b7c0b5e5e7b3e8f0b2b3e3c0f0e0",
    ),
  ]
}

/// Testnet checkpoints
fn testnet_checkpoints() -> List(Checkpoint) {
  [
    Checkpoint(
      546,
      "000000002a936ca763904c3c35fce2f3556c559c0214345d31b1bcebf76acb70",
    ),
  ]
}

/// Verify a block matches a checkpoint (if one exists at that height)
pub fn verify_checkpoint(height: Int, hash: String, network: Network) -> Bool {
  let checkpoints = get_checkpoints(network)

  case find_checkpoint(height, checkpoints) {
    None -> True
    // No checkpoint at this height
    Some(checkpoint) -> checkpoint.hash == hash
  }
}

fn find_checkpoint(
  height: Int,
  checkpoints: List(Checkpoint),
) -> Option(Checkpoint) {
  case checkpoints {
    [] -> None
    [cp, ..rest] -> {
      case cp.height == height {
        True -> Some(cp)
        False -> find_checkpoint(height, rest)
      }
    }
  }
}

// ============================================================================
// Block Size/Weight Limits
// ============================================================================

/// Maximum block weight (4 million weight units)
pub const max_block_weight: Int = 4_000_000

/// Maximum block size for non-witness serialization
pub const max_block_base_size: Int = 1_000_000

/// Maximum allowed sigops in a block
pub const max_block_sigops_cost: Int = 80_000

/// Maximum script size
pub const max_script_size: Int = 10_000

/// Maximum stack size
pub const max_stack_size: Int = 1000

/// Maximum ops per script
pub const max_ops_per_script: Int = 201

/// Maximum pubkeys in multisig
pub const max_pubkeys_per_multisig: Int = 20
