// wallet.gleam - Wallet module for oni Bitcoin node
//
// This module provides wallet functionality:
// - HD wallet key derivation (BIP32/BIP44/BIP84)
// - Key management and secure storage
// - Address generation
// - Transaction signing
// - Coin selection algorithms
// - UTXO tracking
//
// Security: Keys are stored encrypted, never logged, cleared from memory when possible

import gleam/bit_array
import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import oni_bitcoin

// ============================================================================
// Constants
// ============================================================================

/// BIP32 version bytes for mainnet xpub
pub const mainnet_xpub_version = 0x0488B21E

/// BIP32 version bytes for mainnet xprv
pub const mainnet_xprv_version = 0x0488ADE4

/// BIP32 version bytes for testnet tpub
pub const testnet_tpub_version = 0x043587CF

/// BIP32 version bytes for testnet tprv
pub const testnet_tprv_version = 0x04358394

/// BIP84 purpose for native SegWit
pub const bip84_purpose = 84

/// BIP44 purpose for legacy
pub const bip44_purpose = 44

/// Hardened key offset
pub const hardened_offset = 0x80000000

/// Default gap limit for address discovery
pub const default_gap_limit = 20

/// Maximum number of child keys to derive
pub const max_child_index = 2_147_483_647

// ============================================================================
// Core Types
// ============================================================================

/// Extended private key (BIP32)
pub type ExtendedPrivateKey {
  ExtendedPrivateKey(
    /// The 32-byte private key
    key: BitArray,
    /// The 32-byte chain code
    chain_code: BitArray,
    /// Depth in derivation tree
    depth: Int,
    /// Parent fingerprint (first 4 bytes of parent pubkey hash)
    parent_fingerprint: BitArray,
    /// Child index
    child_index: Int,
    /// Network (for serialization)
    network: WalletNetwork,
  )
}

/// Extended public key (BIP32)
pub type ExtendedPublicKey {
  ExtendedPublicKey(
    /// The 33-byte compressed public key
    key: BitArray,
    /// The 32-byte chain code
    chain_code: BitArray,
    /// Depth in derivation tree
    depth: Int,
    /// Parent fingerprint
    parent_fingerprint: BitArray,
    /// Child index
    child_index: Int,
    /// Network
    network: WalletNetwork,
  )
}

/// Wallet network type
pub type WalletNetwork {
  WalletMainnet
  WalletTestnet
  WalletRegtest
}

/// Derivation path
pub type DerivationPath {
  DerivationPath(components: List(PathComponent))
}

/// Path component (normal or hardened)
pub type PathComponent {
  Normal(Int)
  Hardened(Int)
}

/// Address type
pub type AddressType {
  /// Legacy P2PKH (1...)
  Legacy
  /// SegWit P2WPKH (bc1q...)
  NativeSegwit
  /// Nested SegWit P2SH-P2WPKH (3...)
  NestedSegwit
  /// Taproot P2TR (bc1p...)
  Taproot
}

/// Wallet address with metadata
pub type WalletAddress {
  WalletAddress(
    address: String,
    address_type: AddressType,
    derivation_path: DerivationPath,
    is_change: Bool,
    index: Int,
    used: Bool,
    script_pubkey: oni_bitcoin.Script,
  )
}

/// UTXO with wallet metadata
pub type WalletUtxo {
  WalletUtxo(
    outpoint: oni_bitcoin.OutPoint,
    amount: oni_bitcoin.Amount,
    script_pubkey: oni_bitcoin.Script,
    address: String,
    derivation_path: DerivationPath,
    confirmations: Int,
    is_coinbase: Bool,
    is_change: Bool,
  )
}

/// Wallet state
pub type Wallet {
  Wallet(
    /// Master extended private key (encrypted)
    master_key: Option(EncryptedKey),
    /// Account extended public keys (for watch-only)
    account_xpubs: Dict(Int, ExtendedPublicKey),
    /// Generated addresses
    addresses: Dict(String, WalletAddress),
    /// Known UTXOs
    utxos: Dict(String, WalletUtxo),
    /// Next receive address index
    next_receive_index: Int,
    /// Next change address index
    next_change_index: Int,
    /// Wallet network
    network: WalletNetwork,
    /// Default address type
    default_address_type: AddressType,
    /// Gap limit for address discovery
    gap_limit: Int,
    /// Total balance in satoshis
    balance: Int,
    /// Unconfirmed balance
    unconfirmed_balance: Int,
  )
}

/// Encrypted key storage
pub type EncryptedKey {
  EncryptedKey(
    /// Encrypted key data
    ciphertext: BitArray,
    /// Initialization vector
    iv: BitArray,
    /// Salt for key derivation
    salt: BitArray,
    /// Authentication tag
    auth_tag: BitArray,
  )
}

/// Coin selection result
pub type CoinSelection {
  CoinSelection(
    /// Selected UTXOs
    inputs: List(WalletUtxo),
    /// Total input amount
    total_input: Int,
    /// Required output amount
    target_amount: Int,
    /// Fee amount
    fee: Int,
    /// Change amount (if any)
    change: Int,
  )
}

/// Coin selection strategy
pub type SelectionStrategy {
  /// Minimize total input (fewest UTXOs first)
  MinimizeInputs
  /// Minimize fees (optimal UTXO selection)
  MinimizeFees
  /// Maximize privacy (avoid change, use oldest UTXOs)
  MaximizePrivacy
  /// Branch and bound (find exact match if possible)
  BranchAndBound
}

/// Transaction signing request
pub type SigningRequest {
  SigningRequest(
    /// Unsigned transaction
    tx: oni_bitcoin.Transaction,
    /// Inputs to sign with their derivation paths
    inputs: List(SigningInput),
    /// Sighash type
    sighash_type: Int,
  )
}

/// Input to sign
pub type SigningInput {
  SigningInput(
    /// Input index
    input_index: Int,
    /// Previous output value
    amount: oni_bitcoin.Amount,
    /// Script pubkey of previous output
    script_pubkey: oni_bitcoin.Script,
    /// Derivation path for signing key
    derivation_path: DerivationPath,
    /// Address type (determines signing method)
    address_type: AddressType,
  )
}

/// Wallet errors
pub type WalletError {
  InvalidMnemonic
  InvalidDerivationPath(String)
  KeyNotFound
  InsufficientFunds
  InvalidPassword
  EncryptionError
  SigningError(String)
  AddressGenerationError
  InvalidNetwork
  UtxoNotFound
  TransactionError(String)
}

// ============================================================================
// Wallet Creation
// ============================================================================

/// Create a new empty wallet
pub fn new_wallet(network: WalletNetwork) -> Wallet {
  Wallet(
    master_key: None,
    account_xpubs: dict.new(),
    addresses: dict.new(),
    utxos: dict.new(),
    next_receive_index: 0,
    next_change_index: 0,
    network: network,
    default_address_type: NativeSegwit,
    gap_limit: default_gap_limit,
    balance: 0,
    unconfirmed_balance: 0,
  )
}

/// Create wallet from mnemonic seed phrase
pub fn from_mnemonic(
  mnemonic: String,
  passphrase: String,
  network: WalletNetwork,
) -> Result(Wallet, WalletError) {
  // Validate mnemonic word count
  let words = string.split(mnemonic, " ")
  let word_count = list.length(words)

  case word_count == 12 || word_count == 24 {
    False -> Error(InvalidMnemonic)
    True -> {
      // Generate seed from mnemonic using PBKDF2
      let salt = "mnemonic" <> passphrase
      let seed = pbkdf2_sha512(mnemonic, salt, 2048, 64)

      // Derive master key from seed
      case derive_master_key(seed, network) {
        Error(_) -> Error(InvalidMnemonic)
        Ok(master_key) -> {
          // Create wallet with master key
          let wallet = new_wallet(network)

          // Derive account keys for BIP84 (native SegWit)
          case derive_account_key(master_key, bip84_purpose, 0) {
            Error(e) -> Error(e)
            Ok(account_key) -> {
              let account_xpub = to_extended_public_key(account_key)
              let account_xpubs = dict.insert(wallet.account_xpubs, 0, account_xpub)

              Ok(Wallet(
                ..wallet,
                master_key: Some(encrypt_key(master_key, "")), // TODO: proper encryption
                account_xpubs: account_xpubs,
              ))
            }
          }
        }
      }
    }
  }
}

/// Create watch-only wallet from extended public key
pub fn from_xpub(
  xpub: String,
  network: WalletNetwork,
) -> Result(Wallet, WalletError) {
  case parse_extended_public_key(xpub) {
    Error(_) -> Error(InvalidDerivationPath("Invalid xpub"))
    Ok(account_xpub) -> {
      let wallet = new_wallet(network)
      let account_xpubs = dict.insert(wallet.account_xpubs, 0, account_xpub)

      Ok(Wallet(
        ..wallet,
        account_xpubs: account_xpubs,
      ))
    }
  }
}

// ============================================================================
// Key Derivation (BIP32)
// ============================================================================

/// Derive master key from seed
fn derive_master_key(
  seed: BitArray,
  network: WalletNetwork,
) -> Result(ExtendedPrivateKey, WalletError) {
  // HMAC-SHA512 with key "Bitcoin seed"
  let hmac_result = hmac_sha512(<<"Bitcoin seed">>, seed)

  case hmac_result {
    <<private_key:bytes-size(32), chain_code:bytes-size(32)>> -> {
      Ok(ExtendedPrivateKey(
        key: private_key,
        chain_code: chain_code,
        depth: 0,
        parent_fingerprint: <<0, 0, 0, 0>>,
        child_index: 0,
        network: network,
      ))
    }
    _ -> Error(InvalidMnemonic)
  }
}

/// Derive child key at path
pub fn derive_path(
  parent: ExtendedPrivateKey,
  path: DerivationPath,
) -> Result(ExtendedPrivateKey, WalletError) {
  list.fold(path.components, Ok(parent), fn(acc, component) {
    case acc {
      Error(e) -> Error(e)
      Ok(key) -> derive_child(key, component)
    }
  })
}

/// Derive child key for single component
fn derive_child(
  parent: ExtendedPrivateKey,
  component: PathComponent,
) -> Result(ExtendedPrivateKey, WalletError) {
  let index = case component {
    Normal(i) -> i
    Hardened(i) -> i + hardened_offset
  }

  // Build data for HMAC
  let data = case component {
    Hardened(_) -> {
      // Hardened: 0x00 || private_key || index
      bit_array.concat([<<0>>, parent.key, <<index:32-big>>])
    }
    Normal(_) -> {
      // Normal: public_key || index
      let pubkey = private_to_public(parent.key)
      bit_array.concat([pubkey, <<index:32-big>>])
    }
  }

  let hmac_result = hmac_sha512(parent.chain_code, data)

  case hmac_result {
    <<il:bytes-size(32), ir:bytes-size(32)>> -> {
      // Add IL to parent key (mod curve order)
      let child_key = add_private_keys(parent.key, il)
      let fingerprint = compute_fingerprint(parent)

      Ok(ExtendedPrivateKey(
        key: child_key,
        chain_code: ir,
        depth: parent.depth + 1,
        parent_fingerprint: fingerprint,
        child_index: index,
        network: parent.network,
      ))
    }
    _ -> Error(InvalidDerivationPath("HMAC failed"))
  }
}

/// Derive account key (m/purpose'/coin'/account')
fn derive_account_key(
  master: ExtendedPrivateKey,
  purpose: Int,
  account: Int,
) -> Result(ExtendedPrivateKey, WalletError) {
  let coin_type = case master.network {
    WalletMainnet -> 0
    WalletTestnet | WalletRegtest -> 1
  }

  let path = DerivationPath(components: [
    Hardened(purpose),
    Hardened(coin_type),
    Hardened(account),
  ])

  derive_path(master, path)
}

/// Convert private key to public key
fn to_extended_public_key(private: ExtendedPrivateKey) -> ExtendedPublicKey {
  ExtendedPublicKey(
    key: private_to_public(private.key),
    chain_code: private.chain_code,
    depth: private.depth,
    parent_fingerprint: private.parent_fingerprint,
    child_index: private.child_index,
    network: private.network,
  )
}

/// Derive child public key (for non-hardened derivation)
pub fn derive_public_child(
  parent: ExtendedPublicKey,
  index: Int,
) -> Result(ExtendedPublicKey, WalletError) {
  case index >= hardened_offset {
    True -> Error(InvalidDerivationPath("Cannot derive hardened from public key"))
    False -> {
      let data = bit_array.concat([parent.key, <<index:32-big>>])
      let hmac_result = hmac_sha512(parent.chain_code, data)

      case hmac_result {
        <<il:bytes-size(32), ir:bytes-size(32)>> -> {
          // Add IL*G to parent point
          let child_key = add_public_keys(parent.key, il)
          let fingerprint = hash160(parent.key)
          let fingerprint_4 = case fingerprint {
            <<fp:bytes-size(4), _:bytes>> -> fp
            _ -> <<0, 0, 0, 0>>
          }

          Ok(ExtendedPublicKey(
            key: child_key,
            chain_code: ir,
            depth: parent.depth + 1,
            parent_fingerprint: fingerprint_4,
            child_index: index,
            network: parent.network,
          ))
        }
        _ -> Error(InvalidDerivationPath("HMAC failed"))
      }
    }
  }
}

// ============================================================================
// Address Generation
// ============================================================================

/// Generate next receive address
pub fn get_next_receive_address(
  wallet: Wallet,
) -> Result(#(Wallet, WalletAddress), WalletError) {
  generate_address(wallet, False, wallet.next_receive_index)
}

/// Generate next change address
pub fn get_next_change_address(
  wallet: Wallet,
) -> Result(#(Wallet, WalletAddress), WalletError) {
  generate_address(wallet, True, wallet.next_change_index)
}

/// Generate address at specific index
fn generate_address(
  wallet: Wallet,
  is_change: Bool,
  index: Int,
) -> Result(#(Wallet, WalletAddress), WalletError) {
  // Get account xpub
  case dict.get(wallet.account_xpubs, 0) {
    Error(_) -> Error(KeyNotFound)
    Ok(account_xpub) -> {
      // Derive external (0) or internal (1) chain
      let chain = case is_change {
        False -> 0
        True -> 1
      }

      use chain_key <- result.try(derive_public_child(account_xpub, chain))
      use address_key <- result.try(derive_public_child(chain_key, index))

      // Generate address based on type
      let #(address, script) = case wallet.default_address_type {
        NativeSegwit -> generate_p2wpkh_address(address_key, wallet.network)
        Legacy -> generate_p2pkh_address(address_key, wallet.network)
        NestedSegwit -> generate_p2sh_p2wpkh_address(address_key, wallet.network)
        Taproot -> generate_p2tr_address(address_key, wallet.network)
      }

      let path = DerivationPath(components: [
        Hardened(bip84_purpose),
        Hardened(network_coin_type(wallet.network)),
        Hardened(0),
        Normal(chain),
        Normal(index),
      ])

      let wallet_addr = WalletAddress(
        address: address,
        address_type: wallet.default_address_type,
        derivation_path: path,
        is_change: is_change,
        index: index,
        used: False,
        script_pubkey: script,
      )

      // Update wallet state
      let new_addresses = dict.insert(wallet.addresses, address, wallet_addr)
      let new_wallet = case is_change {
        False -> Wallet(
          ..wallet,
          addresses: new_addresses,
          next_receive_index: index + 1,
        )
        True -> Wallet(
          ..wallet,
          addresses: new_addresses,
          next_change_index: index + 1,
        )
      }

      Ok(#(new_wallet, wallet_addr))
    }
  }
}

/// Generate P2WPKH (native SegWit) address
fn generate_p2wpkh_address(
  key: ExtendedPublicKey,
  network: WalletNetwork,
) -> #(String, oni_bitcoin.Script) {
  let pubkey_hash = hash160(key.key)

  // Script: OP_0 <20-byte-key-hash>
  let script = oni_bitcoin.script_from_bytes(<<0x00, 0x14, pubkey_hash:bits>>)

  // Bech32 address
  let hrp = case network {
    WalletMainnet -> "bc"
    WalletTestnet -> "tb"
    WalletRegtest -> "bcrt"
  }

  let address = encode_bech32(hrp, 0, pubkey_hash)
  #(address, script)
}

/// Generate P2PKH (legacy) address
fn generate_p2pkh_address(
  key: ExtendedPublicKey,
  network: WalletNetwork,
) -> #(String, oni_bitcoin.Script) {
  let pubkey_hash = hash160(key.key)

  // Script: OP_DUP OP_HASH160 <20-byte-key-hash> OP_EQUALVERIFY OP_CHECKSIG
  let script = oni_bitcoin.script_from_bytes(<<
    0x76, 0xa9, 0x14, pubkey_hash:bits, 0x88, 0xac
  >>)

  // Base58Check address
  let version = case network {
    WalletMainnet -> 0x00
    WalletTestnet | WalletRegtest -> 0x6F
  }

  let address = encode_base58check(<<version, pubkey_hash:bits>>)
  #(address, script)
}

/// Generate P2SH-P2WPKH (nested SegWit) address
fn generate_p2sh_p2wpkh_address(
  key: ExtendedPublicKey,
  network: WalletNetwork,
) -> #(String, oni_bitcoin.Script) {
  let pubkey_hash = hash160(key.key)

  // Redeem script: OP_0 <20-byte-key-hash>
  let redeem_script = <<0x00, 0x14, pubkey_hash:bits>>
  let script_hash = hash160(redeem_script)

  // Script: OP_HASH160 <20-byte-script-hash> OP_EQUAL
  let script = oni_bitcoin.script_from_bytes(<<0xa9, 0x14, script_hash:bits, 0x87>>)

  // Base58Check address
  let version = case network {
    WalletMainnet -> 0x05
    WalletTestnet | WalletRegtest -> 0xC4
  }

  let address = encode_base58check(<<version, script_hash:bits>>)
  #(address, script)
}

/// Generate P2TR (Taproot) address
fn generate_p2tr_address(
  key: ExtendedPublicKey,
  network: WalletNetwork,
) -> #(String, oni_bitcoin.Script) {
  // Convert to x-only public key (32 bytes)
  let x_only_key = case key.key {
    <<_prefix:8, x:bytes-size(32)>> -> x
    _ -> <<0:256>>
  }

  // Tweak the key (simplified - real implementation needs proper tweaking)
  let tweaked_key = x_only_key

  // Script: OP_1 <32-byte-x-only-key>
  let script = oni_bitcoin.script_from_bytes(<<0x51, 0x20, tweaked_key:bits>>)

  // Bech32m address
  let hrp = case network {
    WalletMainnet -> "bc"
    WalletTestnet -> "tb"
    WalletRegtest -> "bcrt"
  }

  let address = encode_bech32m(hrp, 1, tweaked_key)
  #(address, script)
}

// ============================================================================
// Coin Selection
// ============================================================================

/// Select coins for transaction
pub fn select_coins(
  wallet: Wallet,
  target_amount: Int,
  fee_rate: Float,
  strategy: SelectionStrategy,
) -> Result(CoinSelection, WalletError) {
  let available_utxos = dict.values(wallet.utxos)
    |> list.filter(fn(u) { u.confirmations > 0 || !u.is_coinbase })

  case list.is_empty(available_utxos) {
    True -> Error(InsufficientFunds)
    False -> {
      case strategy {
        MinimizeInputs -> select_largest_first(available_utxos, target_amount, fee_rate)
        MinimizeFees -> select_minimize_fees(available_utxos, target_amount, fee_rate)
        MaximizePrivacy -> select_privacy_focused(available_utxos, target_amount, fee_rate)
        BranchAndBound -> select_branch_and_bound(available_utxos, target_amount, fee_rate)
      }
    }
  }
}

/// Largest first selection (minimize inputs)
fn select_largest_first(
  utxos: List(WalletUtxo),
  target: Int,
  fee_rate: Float,
) -> Result(CoinSelection, WalletError) {
  // Sort by value descending
  let sorted = list.sort(utxos, fn(a, b) {
    let va = oni_bitcoin.amount_to_sats(a.amount)
    let vb = oni_bitcoin.amount_to_sats(b.amount)
    case va > vb {
      True -> order.Lt
      False -> case va < vb {
        True -> order.Gt
        False -> order.Eq
      }
    }
  })

  accumulate_inputs(sorted, target, fee_rate, [], 0)
}

fn accumulate_inputs(
  utxos: List(WalletUtxo),
  target: Int,
  fee_rate: Float,
  selected: List(WalletUtxo),
  total: Int,
) -> Result(CoinSelection, WalletError) {
  let num_inputs = list.length(selected)
  let estimated_size = estimate_tx_size(num_inputs, 2) // 2 outputs (payment + change)
  let fee = float.ceiling(fee_rate *. int.to_float(estimated_size)) |> float.truncate

  let required = target + fee

  case total >= required {
    True -> {
      let change = total - required
      Ok(CoinSelection(
        inputs: list.reverse(selected),
        total_input: total,
        target_amount: target,
        fee: fee,
        change: change,
      ))
    }
    False -> {
      case utxos {
        [] -> Error(InsufficientFunds)
        [utxo, ..rest] -> {
          let value = oni_bitcoin.amount_to_sats(utxo.amount)
          accumulate_inputs(rest, target, fee_rate, [utxo, ..selected], total + value)
        }
      }
    }
  }
}

/// Minimize fees selection
fn select_minimize_fees(
  utxos: List(WalletUtxo),
  target: Int,
  fee_rate: Float,
) -> Result(CoinSelection, WalletError) {
  // Try to find exact match first, then fall back to largest first
  case find_exact_match(utxos, target, fee_rate) {
    Ok(selection) -> Ok(selection)
    Error(_) -> select_largest_first(utxos, target, fee_rate)
  }
}

/// Privacy-focused selection (oldest UTXOs, avoid change)
fn select_privacy_focused(
  utxos: List(WalletUtxo),
  target: Int,
  fee_rate: Float,
) -> Result(CoinSelection, WalletError) {
  // Sort by confirmations descending (oldest first)
  let sorted = list.sort(utxos, fn(a, b) {
    case a.confirmations > b.confirmations {
      True -> order.Lt
      False -> case a.confirmations < b.confirmations {
        True -> order.Gt
        False -> order.Eq
      }
    }
  })

  accumulate_inputs(sorted, target, fee_rate, [], 0)
}

/// Branch and bound selection (find exact match if possible)
fn select_branch_and_bound(
  utxos: List(WalletUtxo),
  target: Int,
  fee_rate: Float,
) -> Result(CoinSelection, WalletError) {
  case find_exact_match(utxos, target, fee_rate) {
    Ok(selection) -> Ok(selection)
    Error(_) -> select_largest_first(utxos, target, fee_rate)
  }
}

/// Try to find an exact match (no change needed)
fn find_exact_match(
  utxos: List(WalletUtxo),
  target: Int,
  fee_rate: Float,
) -> Result(CoinSelection, WalletError) {
  // Simple implementation: try single UTXOs that match exactly
  let matching = list.filter(utxos, fn(u) {
    let value = oni_bitcoin.amount_to_sats(u.amount)
    let fee = float.ceiling(fee_rate *. int.to_float(estimate_tx_size(1, 1))) |> float.truncate
    value == target + fee
  })

  case matching {
    [utxo, ..] -> {
      let value = oni_bitcoin.amount_to_sats(utxo.amount)
      let fee = float.ceiling(fee_rate *. int.to_float(estimate_tx_size(1, 1))) |> float.truncate
      Ok(CoinSelection(
        inputs: [utxo],
        total_input: value,
        target_amount: target,
        fee: fee,
        change: 0,
      ))
    }
    [] -> Error(InsufficientFunds)
  }
}

/// Estimate transaction size in virtual bytes
fn estimate_tx_size(num_inputs: Int, num_outputs: Int) -> Int {
  // P2WPKH estimates:
  // Base: 10.5 vB (version, locktime, witness header)
  // Per input: 68 vB
  // Per output: 31 vB
  let base = 11
  let per_input = 68
  let per_output = 31

  base + num_inputs * per_input + num_outputs * per_output
}

// ============================================================================
// Transaction Signing
// ============================================================================

/// Sign a transaction
pub fn sign_transaction(
  wallet: Wallet,
  request: SigningRequest,
  password: String,
) -> Result(oni_bitcoin.Transaction, WalletError) {
  // Decrypt master key
  case wallet.master_key {
    None -> Error(KeyNotFound)
    Some(encrypted_key) -> {
      case decrypt_key(encrypted_key, password) {
        Error(_) -> Error(InvalidPassword)
        Ok(master_key) -> {
          // Sign each input
          sign_inputs(master_key, request.tx, request.inputs, request.sighash_type)
        }
      }
    }
  }
}

fn sign_inputs(
  master_key: ExtendedPrivateKey,
  tx: oni_bitcoin.Transaction,
  inputs: List(SigningInput),
  sighash_type: Int,
) -> Result(oni_bitcoin.Transaction, WalletError) {
  list.fold(inputs, Ok(tx), fn(acc, input) {
    case acc {
      Error(e) -> Error(e)
      Ok(current_tx) -> sign_single_input(master_key, current_tx, input, sighash_type)
    }
  })
}

fn sign_single_input(
  master_key: ExtendedPrivateKey,
  tx: oni_bitcoin.Transaction,
  input: SigningInput,
  sighash_type: Int,
) -> Result(oni_bitcoin.Transaction, WalletError) {
  // Derive signing key
  case derive_path(master_key, input.derivation_path) {
    Error(e) -> Error(e)
    Ok(signing_key) -> {
      // Compute signature based on address type
      case input.address_type {
        NativeSegwit | NestedSegwit -> {
          sign_segwit_input(tx, input, signing_key, sighash_type)
        }
        Legacy -> {
          sign_legacy_input(tx, input, signing_key, sighash_type)
        }
        Taproot -> {
          sign_taproot_input(tx, input, signing_key, sighash_type)
        }
      }
    }
  }
}

fn sign_segwit_input(
  tx: oni_bitcoin.Transaction,
  input: SigningInput,
  key: ExtendedPrivateKey,
  sighash_type: Int,
) -> Result(oni_bitcoin.Transaction, WalletError) {
  // Compute BIP143 sighash
  let sighash = compute_segwit_sighash(tx, input, sighash_type)

  // Sign with ECDSA
  let signature = ecdsa_sign(key.key, sighash)
  let sig_with_type = bit_array.concat([signature, <<sighash_type:8>>])

  // Get public key
  let pubkey = private_to_public(key.key)

  // Create witness
  let witness = [sig_with_type, pubkey]

  // Update transaction with witness
  let updated_tx = update_tx_witness(tx, input.input_index, witness)
  Ok(updated_tx)
}

fn sign_legacy_input(
  tx: oni_bitcoin.Transaction,
  input: SigningInput,
  key: ExtendedPrivateKey,
  sighash_type: Int,
) -> Result(oni_bitcoin.Transaction, WalletError) {
  // Compute legacy sighash
  let sighash = compute_legacy_sighash(tx, input, sighash_type)

  // Sign with ECDSA
  let signature = ecdsa_sign(key.key, sighash)
  let sig_with_type = bit_array.concat([signature, <<sighash_type:8>>])

  // Get public key
  let pubkey = private_to_public(key.key)

  // Create scriptSig: <sig> <pubkey>
  let script_sig = build_p2pkh_scriptsig(sig_with_type, pubkey)

  // Update transaction input
  let updated_tx = update_tx_scriptsig(tx, input.input_index, script_sig)
  Ok(updated_tx)
}

fn sign_taproot_input(
  tx: oni_bitcoin.Transaction,
  input: SigningInput,
  key: ExtendedPrivateKey,
  sighash_type: Int,
) -> Result(oni_bitcoin.Transaction, WalletError) {
  // Compute BIP341 sighash (Taproot)
  let sighash = compute_taproot_sighash(tx, input, sighash_type)

  // Sign with Schnorr
  let signature = schnorr_sign(key.key, sighash)

  // For default sighash, signature is 64 bytes
  // For other types, append sighash byte
  let witness_sig = case sighash_type {
    0 | 1 -> signature  // SIGHASH_DEFAULT or SIGHASH_ALL
    _ -> bit_array.concat([signature, <<sighash_type:8>>])
  }

  // Create witness (just signature for key path spend)
  let witness = [witness_sig]

  let updated_tx = update_tx_witness(tx, input.input_index, witness)
  Ok(updated_tx)
}

// ============================================================================
// UTXO Management
// ============================================================================

/// Add a UTXO to wallet
pub fn add_utxo(wallet: Wallet, utxo: WalletUtxo) -> Wallet {
  let key = outpoint_key(utxo.outpoint)
  let new_utxos = dict.insert(wallet.utxos, key, utxo)
  let value = oni_bitcoin.amount_to_sats(utxo.amount)

  let new_balance = case utxo.confirmations > 0 {
    True -> wallet.balance + value
    False -> wallet.balance
  }

  let new_unconfirmed = case utxo.confirmations == 0 {
    True -> wallet.unconfirmed_balance + value
    False -> wallet.unconfirmed_balance
  }

  Wallet(
    ..wallet,
    utxos: new_utxos,
    balance: new_balance,
    unconfirmed_balance: new_unconfirmed,
  )
}

/// Remove a UTXO from wallet (spent)
pub fn remove_utxo(wallet: Wallet, outpoint: oni_bitcoin.OutPoint) -> Wallet {
  let key = outpoint_key(outpoint)

  case dict.get(wallet.utxos, key) {
    Error(_) -> wallet
    Ok(utxo) -> {
      let value = oni_bitcoin.amount_to_sats(utxo.amount)
      let new_utxos = dict.delete(wallet.utxos, key)

      let new_balance = case utxo.confirmations > 0 {
        True -> wallet.balance - value
        False -> wallet.balance
      }

      let new_unconfirmed = case utxo.confirmations == 0 {
        True -> wallet.unconfirmed_balance - value
        False -> wallet.unconfirmed_balance
      }

      Wallet(
        ..wallet,
        utxos: new_utxos,
        balance: int.max(0, new_balance),
        unconfirmed_balance: int.max(0, new_unconfirmed),
      )
    }
  }
}

/// Mark address as used
pub fn mark_address_used(wallet: Wallet, address: String) -> Wallet {
  case dict.get(wallet.addresses, address) {
    Error(_) -> wallet
    Ok(addr) -> {
      let updated = WalletAddress(..addr, used: True)
      let new_addresses = dict.insert(wallet.addresses, address, updated)
      Wallet(..wallet, addresses: new_addresses)
    }
  }
}

/// Get wallet balance
pub fn get_balance(wallet: Wallet) -> #(Int, Int) {
  #(wallet.balance, wallet.unconfirmed_balance)
}

/// List all addresses
pub fn list_addresses(wallet: Wallet) -> List(WalletAddress) {
  dict.values(wallet.addresses)
}

/// List all UTXOs
pub fn list_utxos(wallet: Wallet) -> List(WalletUtxo) {
  dict.values(wallet.utxos)
}

// ============================================================================
// Serialization
// ============================================================================

/// Serialize extended public key to xpub format
pub fn serialize_xpub(key: ExtendedPublicKey) -> String {
  let version = case key.network {
    WalletMainnet -> mainnet_xpub_version
    WalletTestnet | WalletRegtest -> testnet_tpub_version
  }

  let data = bytes_builder.new()
    |> bytes_builder.append(<<version:32-big>>)
    |> bytes_builder.append(<<key.depth:8>>)
    |> bytes_builder.append(key.parent_fingerprint)
    |> bytes_builder.append(<<key.child_index:32-big>>)
    |> bytes_builder.append(key.chain_code)
    |> bytes_builder.append(key.key)
    |> bytes_builder.to_bit_array

  encode_base58check(data)
}

/// Parse extended public key from xpub string
fn parse_extended_public_key(xpub: String) -> Result(ExtendedPublicKey, Nil) {
  case decode_base58check(xpub) {
    Error(_) -> Error(Nil)
    Ok(data) -> {
      case data {
        <<version:32-big, depth:8, fingerprint:bytes-size(4),
          child_index:32-big, chain_code:bytes-size(32),
          key:bytes-size(33)>> -> {
          let network = case version {
            v if v == mainnet_xpub_version -> WalletMainnet
            _ -> WalletTestnet
          }

          Ok(ExtendedPublicKey(
            key: key,
            chain_code: chain_code,
            depth: depth,
            parent_fingerprint: fingerprint,
            child_index: child_index,
            network: network,
          ))
        }
        _ -> Error(Nil)
      }
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn network_coin_type(network: WalletNetwork) -> Int {
  case network {
    WalletMainnet -> 0
    WalletTestnet | WalletRegtest -> 1
  }
}

fn outpoint_key(outpoint: oni_bitcoin.OutPoint) -> String {
  oni_bitcoin.txid_to_hex(outpoint.txid) <> ":" <> int.to_string(outpoint.vout)
}

fn compute_fingerprint(key: ExtendedPrivateKey) -> BitArray {
  let pubkey = private_to_public(key.key)
  let hash = hash160(pubkey)
  case hash {
    <<fp:bytes-size(4), _:bytes>> -> fp
    _ -> <<0, 0, 0, 0>>
  }
}

// Placeholder cryptographic functions (would use NIFs in production)

fn hmac_sha512(key: BitArray, data: BitArray) -> BitArray {
  // Placeholder - would use actual HMAC-SHA512
  oni_bitcoin.sha256(bit_array.concat([key, data]))
  |> fn(h) { bit_array.concat([h, h]) }
}

fn pbkdf2_sha512(_password: String, _salt: String, _iterations: Int, _length: Int) -> BitArray {
  // Placeholder - would use actual PBKDF2
  <<0:512>>
}

fn private_to_public(private_key: BitArray) -> BitArray {
  // Placeholder - would use secp256k1 point multiplication
  let _ = private_key
  <<0x02, 0:256>>  // Compressed public key
}

fn add_private_keys(a: BitArray, b: BitArray) -> BitArray {
  // Placeholder - would add mod curve order
  let _ = b
  a
}

fn add_public_keys(point: BitArray, scalar: BitArray) -> BitArray {
  // Placeholder - would add scalar*G to point
  let _ = scalar
  point
}

fn hash160(data: BitArray) -> BitArray {
  // RIPEMD160(SHA256(data))
  oni_bitcoin.hash160(data)
}

fn ecdsa_sign(private_key: BitArray, message: BitArray) -> BitArray {
  // Placeholder - would use secp256k1 ECDSA signing
  let _ = private_key
  let _ = message
  <<0:576>>  // DER encoded signature (up to 72 bytes)
}

fn schnorr_sign(private_key: BitArray, message: BitArray) -> BitArray {
  // Placeholder - would use BIP340 Schnorr signing
  let _ = private_key
  let _ = message
  <<0:512>>  // 64-byte Schnorr signature
}

fn compute_segwit_sighash(
  _tx: oni_bitcoin.Transaction,
  _input: SigningInput,
  _sighash_type: Int,
) -> BitArray {
  // Placeholder - would compute BIP143 sighash
  <<0:256>>
}

fn compute_legacy_sighash(
  _tx: oni_bitcoin.Transaction,
  _input: SigningInput,
  _sighash_type: Int,
) -> BitArray {
  // Placeholder - would compute legacy sighash
  <<0:256>>
}

fn compute_taproot_sighash(
  _tx: oni_bitcoin.Transaction,
  _input: SigningInput,
  _sighash_type: Int,
) -> BitArray {
  // Placeholder - would compute BIP341 sighash
  <<0:256>>
}

fn update_tx_witness(
  tx: oni_bitcoin.Transaction,
  _index: Int,
  _witness: List(BitArray),
) -> oni_bitcoin.Transaction {
  // Placeholder - would update witness stack
  tx
}

fn update_tx_scriptsig(
  tx: oni_bitcoin.Transaction,
  _index: Int,
  _script_sig: oni_bitcoin.Script,
) -> oni_bitcoin.Transaction {
  // Placeholder - would update scriptSig
  tx
}

fn build_p2pkh_scriptsig(
  signature: BitArray,
  pubkey: BitArray,
) -> oni_bitcoin.Script {
  let sig_len = bit_array.byte_size(signature)
  let pk_len = bit_array.byte_size(pubkey)
  oni_bitcoin.script_from_bytes(<<sig_len:8, signature:bits, pk_len:8, pubkey:bits>>)
}

fn encrypt_key(key: ExtendedPrivateKey, _password: String) -> EncryptedKey {
  // Placeholder - would use AES-256-GCM
  EncryptedKey(
    ciphertext: key.key,
    iv: <<0:96>>,
    salt: <<0:128>>,
    auth_tag: <<0:128>>,
  )
}

fn decrypt_key(encrypted: EncryptedKey, _password: String) -> Result(ExtendedPrivateKey, Nil) {
  // Placeholder - would decrypt with AES-256-GCM
  Ok(ExtendedPrivateKey(
    key: encrypted.ciphertext,
    chain_code: <<0:256>>,
    depth: 0,
    parent_fingerprint: <<0, 0, 0, 0>>,
    child_index: 0,
    network: WalletMainnet,
  ))
}

fn encode_base58check(data: BitArray) -> String {
  // Placeholder - would use actual Base58Check encoding
  let _ = data
  ""
}

fn decode_base58check(_s: String) -> Result(BitArray, Nil) {
  // Placeholder
  Error(Nil)
}

fn encode_bech32(_hrp: String, _version: Int, _data: BitArray) -> String {
  // Placeholder - would use actual Bech32 encoding
  ""
}

fn encode_bech32m(_hrp: String, _version: Int, _data: BitArray) -> String {
  // Placeholder - would use actual Bech32m encoding
  ""
}
