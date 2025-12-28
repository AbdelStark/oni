// descriptors.gleam - Output Script Descriptors (BIP-380, BIP-381, BIP-382, BIP-386)
//
// This module implements Bitcoin output script descriptors, which are a
// human-readable language for describing how to derive and use Bitcoin
// scripts. Descriptors are used for:
//   - Wallet backup and recovery
//   - Watch-only wallets
//   - Multi-signature setups
//   - Hardware wallet integration
//
// Supported descriptor types:
//   - pk(KEY)           - Pay to pubkey (legacy)
//   - pkh(KEY)          - Pay to pubkey hash (P2PKH)
//   - wpkh(KEY)         - Pay to witness pubkey hash (P2WPKH)
//   - sh(SCRIPT)        - Pay to script hash (P2SH)
//   - wsh(SCRIPT)       - Pay to witness script hash (P2WSH)
//   - tr(KEY[,TREE])    - Pay to taproot (P2TR)
//   - multi(k,KEY,...)  - k-of-n multisig
//   - sortedmulti(...)  - sorted k-of-n multisig
//
// References:
//   - BIP-380: Output Script Descriptors General Operation
//   - BIP-381: Non-Segwit Output Script Descriptors
//   - BIP-382: Segwit Output Script Descriptors
//   - BIP-386: Taproot Output Script Descriptors

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// ============================================================================
// Descriptor Types
// ============================================================================

/// A parsed output descriptor
pub type Descriptor {
  /// pk(KEY) - Pay to pubkey
  PkDescriptor(key: DescriptorKey)
  /// pkh(KEY) - Pay to pubkey hash
  PkhDescriptor(key: DescriptorKey)
  /// wpkh(KEY) - Pay to witness pubkey hash
  WpkhDescriptor(key: DescriptorKey)
  /// sh(SCRIPT) - Pay to script hash
  ShDescriptor(inner: Descriptor)
  /// wsh(SCRIPT) - Pay to witness script hash
  WshDescriptor(inner: Descriptor)
  /// tr(KEY[,TREE]) - Pay to taproot
  TrDescriptor(internal_key: DescriptorKey, tree: Option(TapTree))
  /// multi(k,KEY,...) - k-of-n multisig
  MultiDescriptor(threshold: Int, keys: List(DescriptorKey))
  /// sortedmulti(k,KEY,...) - sorted k-of-n multisig
  SortedMultiDescriptor(threshold: Int, keys: List(DescriptorKey))
  /// addr(ADDRESS) - raw address (for import)
  AddrDescriptor(address: String)
  /// raw(HEX) - raw script
  RawDescriptor(script: BitArray)
  /// combo(KEY) - all standard scripts for a key
  ComboDescriptor(key: DescriptorKey)
}

/// A key in a descriptor (can be a pubkey, xpub, or private key)
pub type DescriptorKey {
  /// Raw public key (33 or 65 bytes hex)
  RawPubKey(key: BitArray, compressed: Bool)
  /// Extended public key (xpub/tpub with derivation path)
  ExtendedPubKey(
    key: String,
    fingerprint: Option(BitArray),
    derivation: List(DerivationStep),
    wildcard: Option(Wildcard),
  )
  /// Extended private key (xprv/tprv with derivation path)
  ExtendedPrivKey(
    key: String,
    fingerprint: Option(BitArray),
    derivation: List(DerivationStep),
    wildcard: Option(Wildcard),
  )
  /// WIF-encoded private key
  WifKey(wif: String)
}

/// A step in a derivation path
pub type DerivationStep {
  /// Normal derivation (index < 2^31)
  Normal(index: Int)
  /// Hardened derivation (index >= 2^31)
  Hardened(index: Int)
}

/// Wildcard type for ranged descriptors
pub type Wildcard {
  /// Unhardened wildcard: /*
  UnhardenedWildcard
  /// Hardened wildcard: /*'
  HardenedWildcard
}

/// Taproot script tree
pub type TapTree {
  /// A single leaf script
  TapLeaf(script: TapScript)
  /// A branch with two children
  TapBranch(left: TapTree, right: TapTree)
}

/// A taproot leaf script
pub type TapScript {
  TapScript(
    version: Int,
    script: Descriptor,
  )
}

/// Checksum for descriptor
pub type DescriptorChecksum {
  DescriptorChecksum(value: String)
}

// ============================================================================
// Descriptor Parsing
// ============================================================================

/// Parse a descriptor string (with optional checksum)
pub fn parse(descriptor_str: String) -> Result(Descriptor, DescriptorError) {
  // Split off checksum if present
  let #(descriptor, checksum) = split_checksum(descriptor_str)

  // Verify checksum if present
  case checksum {
    Some(cs) -> {
      let computed = compute_checksum(descriptor)
      case cs == computed {
        False -> Error(InvalidChecksum)
        True -> parse_inner(descriptor)
      }
    }
    None -> parse_inner(descriptor)
  }
}

/// Parse descriptor without checksum validation
fn parse_inner(s: String) -> Result(Descriptor, DescriptorError) {
  let trimmed = string.trim(s)

  case trimmed {
    "pk(" <> rest -> parse_pk(rest)
    "pkh(" <> rest -> parse_pkh(rest)
    "wpkh(" <> rest -> parse_wpkh(rest)
    "sh(" <> rest -> parse_sh(rest)
    "wsh(" <> rest -> parse_wsh(rest)
    "tr(" <> rest -> parse_tr(rest)
    "multi(" <> rest -> parse_multi(rest, False)
    "sortedmulti(" <> rest -> parse_multi(rest, True)
    "addr(" <> rest -> parse_addr(rest)
    "raw(" <> rest -> parse_raw(rest)
    "combo(" <> rest -> parse_combo(rest)
    _ -> Error(UnknownDescriptorType)
  }
}

fn parse_pk(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let key_str = string.drop_right(s, 1)
      case parse_key(key_str) {
        Error(e) -> Error(e)
        Ok(key) -> Ok(PkDescriptor(key))
      }
    }
  }
}

fn parse_pkh(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let key_str = string.drop_right(s, 1)
      case parse_key(key_str) {
        Error(e) -> Error(e)
        Ok(key) -> Ok(PkhDescriptor(key))
      }
    }
  }
}

fn parse_wpkh(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let key_str = string.drop_right(s, 1)
      case parse_key(key_str) {
        Error(e) -> Error(e)
        Ok(key) -> Ok(WpkhDescriptor(key))
      }
    }
  }
}

fn parse_sh(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let inner_str = string.drop_right(s, 1)
      case parse_inner(inner_str) {
        Error(e) -> Error(e)
        Ok(inner) -> Ok(ShDescriptor(inner))
      }
    }
  }
}

fn parse_wsh(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let inner_str = string.drop_right(s, 1)
      case parse_inner(inner_str) {
        Error(e) -> Error(e)
        Ok(inner) -> Ok(WshDescriptor(inner))
      }
    }
  }
}

fn parse_tr(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let content = string.drop_right(s, 1)
      // Check for tree
      case string.split_once(content, ",") {
        Error(_) -> {
          // No tree, just internal key
          case parse_key(content) {
            Error(e) -> Error(e)
            Ok(key) -> Ok(TrDescriptor(key, None))
          }
        }
        Ok(#(key_str, tree_str)) -> {
          case parse_key(key_str) {
            Error(e) -> Error(e)
            Ok(key) -> {
              case parse_tap_tree(tree_str) {
                Error(e) -> Error(e)
                Ok(tree) -> Ok(TrDescriptor(key, Some(tree)))
              }
            }
          }
        }
      }
    }
  }
}

fn parse_multi(s: String, sorted: Bool) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let content = string.drop_right(s, 1)
      let parts = string.split(content, ",")
      case parts {
        [] -> Error(InvalidMultisig)
        [threshold_str, ..key_strs] -> {
          case int.parse(string.trim(threshold_str)) {
            Error(_) -> Error(InvalidMultisig)
            Ok(threshold) -> {
              case parse_key_list(key_strs) {
                Error(e) -> Error(e)
                Ok(keys) -> {
                  case sorted {
                    True -> Ok(SortedMultiDescriptor(threshold, keys))
                    False -> Ok(MultiDescriptor(threshold, keys))
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn parse_addr(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let addr = string.drop_right(s, 1) |> string.trim
      Ok(AddrDescriptor(addr))
    }
  }
}

fn parse_raw(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let hex = string.drop_right(s, 1) |> string.trim
      case hex_decode(hex) {
        Error(_) -> Error(InvalidHex)
        Ok(script) -> Ok(RawDescriptor(script))
      }
    }
  }
}

fn parse_combo(s: String) -> Result(Descriptor, DescriptorError) {
  case string.ends_with(s, ")") {
    False -> Error(MissingClosingParen)
    True -> {
      let key_str = string.drop_right(s, 1)
      case parse_key(key_str) {
        Error(e) -> Error(e)
        Ok(key) -> Ok(ComboDescriptor(key))
      }
    }
  }
}

fn parse_key_list(strs: List(String)) -> Result(List(DescriptorKey), DescriptorError) {
  list.try_map(strs, fn(s) { parse_key(string.trim(s)) })
}

fn parse_tap_tree(_s: String) -> Result(TapTree, DescriptorError) {
  // Simplified: just create a placeholder
  // Full implementation would parse tree structure
  Error(UnsupportedFeature)
}

// ============================================================================
// Key Parsing
// ============================================================================

/// Parse a descriptor key
pub fn parse_key(s: String) -> Result(DescriptorKey, DescriptorError) {
  let trimmed = string.trim(s)

  // Check for extended key prefixes
  case trimmed {
    "xpub" <> _ -> parse_extended_key(trimmed, False)
    "xprv" <> _ -> parse_extended_key(trimmed, True)
    "tpub" <> _ -> parse_extended_key(trimmed, False)
    "tprv" <> _ -> parse_extended_key(trimmed, True)
    _ -> {
      // Check for WIF
      case string.starts_with(trimmed, "5") ||
           string.starts_with(trimmed, "K") ||
           string.starts_with(trimmed, "L") ||
           string.starts_with(trimmed, "c") {
        True -> Ok(WifKey(trimmed))
        False -> {
          // Try as raw hex pubkey
          case hex_decode(trimmed) {
            Error(_) -> Error(InvalidKey)
            Ok(bytes) -> {
              let len = bit_array.byte_size(bytes)
              case len {
                33 -> Ok(RawPubKey(bytes, True))
                65 -> Ok(RawPubKey(bytes, False))
                _ -> Error(InvalidKey)
              }
            }
          }
        }
      }
    }
  }
}

fn parse_extended_key(s: String, is_private: Bool) -> Result(DescriptorKey, DescriptorError) {
  // Parse: [fingerprint/path]xpub.../derivation/*
  case string.split_once(s, "[") {
    Error(_) -> {
      // No origin info, just key and derivation
      parse_key_with_derivation(s, None, is_private)
    }
    Ok(#(_before, rest)) -> {
      case string.split_once(rest, "]") {
        Error(_) -> Error(InvalidKey)
        Ok(#(origin, after_origin)) -> {
          let fingerprint = parse_origin_fingerprint(origin)
          parse_key_with_derivation(after_origin, fingerprint, is_private)
        }
      }
    }
  }
}

fn parse_key_with_derivation(
  s: String,
  fingerprint: Option(BitArray),
  is_private: Bool,
) -> Result(DescriptorKey, DescriptorError) {
  // Split by / to get derivation path
  let parts = string.split(s, "/")
  case parts {
    [] -> Error(InvalidKey)
    [key_part, ..derivation_parts] -> {
      let #(derivation, wildcard) = parse_derivation_path(derivation_parts)
      case is_private {
        True ->
          Ok(ExtendedPrivKey(key_part, fingerprint, derivation, wildcard))
        False ->
          Ok(ExtendedPubKey(key_part, fingerprint, derivation, wildcard))
      }
    }
  }
}

fn parse_derivation_path(parts: List(String)) -> #(List(DerivationStep), Option(Wildcard)) {
  parse_derivation_steps(parts, [], None)
}

fn parse_derivation_steps(
  parts: List(String),
  acc: List(DerivationStep),
  wildcard: Option(Wildcard),
) -> #(List(DerivationStep), Option(Wildcard)) {
  case parts {
    [] -> #(list.reverse(acc), wildcard)
    [part, ..rest] -> {
      let trimmed = string.trim(part)
      case trimmed {
        "*" -> parse_derivation_steps(rest, acc, Some(UnhardenedWildcard))
        "*'" -> parse_derivation_steps(rest, acc, Some(HardenedWildcard))
        "*h" -> parse_derivation_steps(rest, acc, Some(HardenedWildcard))
        _ -> {
          // Check for hardened
          case string.ends_with(trimmed, "'") || string.ends_with(trimmed, "h") {
            True -> {
              let num_str = string.drop_right(trimmed, 1)
              case int.parse(num_str) {
                Ok(n) -> parse_derivation_steps(rest, [Hardened(n), ..acc], wildcard)
                Error(_) -> parse_derivation_steps(rest, acc, wildcard)
              }
            }
            False -> {
              case int.parse(trimmed) {
                Ok(n) -> parse_derivation_steps(rest, [Normal(n), ..acc], wildcard)
                Error(_) -> parse_derivation_steps(rest, acc, wildcard)
              }
            }
          }
        }
      }
    }
  }
}

fn parse_origin_fingerprint(origin: String) -> Option(BitArray) {
  // Origin format: fingerprint/path
  case string.split_once(origin, "/") {
    Error(_) -> {
      // Just fingerprint
      case hex_decode(origin) {
        Ok(bytes) -> {
          case bit_array.byte_size(bytes) == 4 {
            True -> Some(bytes)
            False -> None
          }
        }
        _ -> None
      }
    }
    Ok(#(fp_hex, _path)) -> {
      case hex_decode(fp_hex) {
        Ok(bytes) -> {
          case bit_array.byte_size(bytes) == 4 {
            True -> Some(bytes)
            False -> None
          }
        }
        _ -> None
      }
    }
  }
}

// ============================================================================
// Descriptor Serialization
// ============================================================================

/// Convert descriptor to string
pub fn to_string(descriptor: Descriptor) -> String {
  to_string_inner(descriptor)
}

fn to_string_inner(descriptor: Descriptor) -> String {
  case descriptor {
    PkDescriptor(key) -> "pk(" <> key_to_string(key) <> ")"
    PkhDescriptor(key) -> "pkh(" <> key_to_string(key) <> ")"
    WpkhDescriptor(key) -> "wpkh(" <> key_to_string(key) <> ")"
    ShDescriptor(inner) -> "sh(" <> to_string_inner(inner) <> ")"
    WshDescriptor(inner) -> "wsh(" <> to_string_inner(inner) <> ")"
    TrDescriptor(key, None) -> "tr(" <> key_to_string(key) <> ")"
    TrDescriptor(key, Some(tree)) ->
      "tr(" <> key_to_string(key) <> "," <> tree_to_string(tree) <> ")"
    MultiDescriptor(threshold, keys) ->
      "multi(" <> int.to_string(threshold) <> "," <> keys_to_string(keys) <> ")"
    SortedMultiDescriptor(threshold, keys) ->
      "sortedmulti(" <> int.to_string(threshold) <> "," <> keys_to_string(keys) <> ")"
    AddrDescriptor(addr) -> "addr(" <> addr <> ")"
    RawDescriptor(script) -> "raw(" <> hex_encode(script) <> ")"
    ComboDescriptor(key) -> "combo(" <> key_to_string(key) <> ")"
  }
}

fn key_to_string(key: DescriptorKey) -> String {
  case key {
    RawPubKey(bytes, _) -> hex_encode(bytes)
    ExtendedPubKey(k, fingerprint, derivation, wildcard) ->
      format_extended_key(k, fingerprint, derivation, wildcard)
    ExtendedPrivKey(k, fingerprint, derivation, wildcard) ->
      format_extended_key(k, fingerprint, derivation, wildcard)
    WifKey(wif) -> wif
  }
}

fn format_extended_key(
  key: String,
  fingerprint: Option(BitArray),
  derivation: List(DerivationStep),
  wildcard: Option(Wildcard),
) -> String {
  let origin = case fingerprint {
    None -> ""
    Some(fp) -> "[" <> hex_encode(fp) <> "]"
  }

  let path = list.map(derivation, step_to_string) |> string.join("/")
  let path_str = case path {
    "" -> ""
    p -> "/" <> p
  }

  let wildcard_str = case wildcard {
    None -> ""
    Some(UnhardenedWildcard) -> "/*"
    Some(HardenedWildcard) -> "/*'"
  }

  origin <> key <> path_str <> wildcard_str
}

fn step_to_string(step: DerivationStep) -> String {
  case step {
    Normal(n) -> int.to_string(n)
    Hardened(n) -> int.to_string(n) <> "'"
  }
}

fn keys_to_string(keys: List(DescriptorKey)) -> String {
  list.map(keys, key_to_string) |> string.join(",")
}

fn tree_to_string(_tree: TapTree) -> String {
  // Simplified
  "..."
}

/// Convert descriptor to string with checksum
pub fn to_string_with_checksum(descriptor: Descriptor) -> String {
  let base = to_string(descriptor)
  let checksum = compute_checksum(base)
  base <> "#" <> checksum
}

// ============================================================================
// Checksum
// ============================================================================

/// Character set for descriptor checksums (bech32-like)
const checksum_charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

/// Compute checksum for a descriptor string
pub fn compute_checksum(descriptor: String) -> String {
  // Simplified checksum computation
  // In production: use the polymod-based checksum from BIP-380
  let hash = sha256(bit_array.from_string(descriptor))
  let checksum_bytes = case bit_array.slice(hash, 0, 4) {
    Ok(b) -> b
    Error(_) -> <<0, 0, 0, 0>>
  }

  // Convert to charset
  bytes_to_checksum(checksum_bytes)
}

fn bytes_to_checksum(bytes: BitArray) -> String {
  case bytes {
    <<a:5, b:5, c:5, d:5, e:5, f:5, g:5, h:5, _:bits>> ->
      char_at(a) <> char_at(b) <> char_at(c) <> char_at(d) <>
      char_at(e) <> char_at(f) <> char_at(g) <> char_at(h)
    _ -> "00000000"
  }
}

fn char_at(index: Int) -> String {
  string.slice(checksum_charset, index, 1)
}

fn split_checksum(s: String) -> #(String, Option(String)) {
  case string.split_once(s, "#") {
    Error(_) -> #(s, None)
    Ok(#(descriptor, checksum)) -> #(descriptor, Some(checksum))
  }
}

// ============================================================================
// Script Derivation
// ============================================================================

/// Derive script pubkey for a descriptor at index
pub fn derive_script(
  descriptor: Descriptor,
  index: Int,
) -> Result(BitArray, DescriptorError) {
  case descriptor {
    PkhDescriptor(key) -> {
      case derive_pubkey(key, index) {
        Error(e) -> Error(e)
        Ok(pubkey) -> Ok(create_p2pkh_script(pubkey))
      }
    }
    WpkhDescriptor(key) -> {
      case derive_pubkey(key, index) {
        Error(e) -> Error(e)
        Ok(pubkey) -> Ok(create_p2wpkh_script(pubkey))
      }
    }
    ShDescriptor(inner) -> {
      case derive_script(inner, index) {
        Error(e) -> Error(e)
        Ok(inner_script) -> Ok(create_p2sh_script(inner_script))
      }
    }
    WshDescriptor(inner) -> {
      case derive_script(inner, index) {
        Error(e) -> Error(e)
        Ok(inner_script) -> Ok(create_p2wsh_script(inner_script))
      }
    }
    RawDescriptor(script) -> Ok(script)
    AddrDescriptor(_addr) -> Error(UnsupportedFeature)
    _ -> Error(UnsupportedFeature)
  }
}

fn derive_pubkey(key: DescriptorKey, _index: Int) -> Result(BitArray, DescriptorError) {
  case key {
    RawPubKey(bytes, _) -> Ok(bytes)
    ExtendedPubKey(_, _, _, _) -> {
      // In production: derive child key at index
      // Placeholder: return dummy pubkey
      Ok(<<2, 0:256>>)
    }
    _ -> Error(UnsupportedFeature)
  }
}

// ============================================================================
// Script Creation
// ============================================================================

fn create_p2pkh_script(pubkey: BitArray) -> BitArray {
  let pubkey_hash = hash160(pubkey)
  // OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
  <<0x76, 0xA9, 0x14, pubkey_hash:bits, 0x88, 0xAC>>
}

fn create_p2wpkh_script(pubkey: BitArray) -> BitArray {
  let pubkey_hash = hash160(pubkey)
  // OP_0 <20 bytes>
  <<0x00, 0x14, pubkey_hash:bits>>
}

fn create_p2sh_script(redeem_script: BitArray) -> BitArray {
  let script_hash = hash160(redeem_script)
  // OP_HASH160 <20 bytes> OP_EQUAL
  <<0xA9, 0x14, script_hash:bits, 0x87>>
}

fn create_p2wsh_script(witness_script: BitArray) -> BitArray {
  let script_hash = sha256(witness_script)
  // OP_0 <32 bytes>
  <<0x00, 0x20, script_hash:bits>>
}

// ============================================================================
// Address Derivation
// ============================================================================

/// Derive address for a descriptor at index
pub fn derive_address(
  descriptor: Descriptor,
  index: Int,
  network: Network,
) -> Result(String, DescriptorError) {
  case descriptor {
    PkhDescriptor(key) -> {
      case derive_pubkey(key, index) {
        Error(e) -> Error(e)
        Ok(pubkey) -> {
          let pubkey_hash = hash160(pubkey)
          Ok(encode_p2pkh_address(pubkey_hash, network))
        }
      }
    }
    WpkhDescriptor(key) -> {
      case derive_pubkey(key, index) {
        Error(e) -> Error(e)
        Ok(pubkey) -> {
          let pubkey_hash = hash160(pubkey)
          Ok(encode_bech32_address(pubkey_hash, 0, network))
        }
      }
    }
    ShDescriptor(WpkhDescriptor(key)) -> {
      case derive_pubkey(key, index) {
        Error(e) -> Error(e)
        Ok(pubkey) -> {
          let pubkey_hash = hash160(pubkey)
          let redeem_script = <<0x00, 0x14, pubkey_hash:bits>>
          let script_hash = hash160(redeem_script)
          Ok(encode_p2sh_address(script_hash, network))
        }
      }
    }
    TrDescriptor(key, _) -> {
      case derive_pubkey(key, index) {
        Error(e) -> Error(e)
        Ok(pubkey) -> {
          // Taproot: use x-only pubkey
          let tweaked_pubkey = case pubkey {
            <<_:8, rest:bits>> -> rest
            _ -> <<0:256>>
          }
          Ok(encode_bech32m_address(tweaked_pubkey, 1, network))
        }
      }
    }
    _ -> Error(UnsupportedFeature)
  }
}

/// Network type for address encoding
pub type Network {
  Mainnet
  Testnet
  Regtest
}

fn encode_p2pkh_address(pubkey_hash: BitArray, network: Network) -> String {
  let version = case network {
    Mainnet -> 0x00
    Testnet -> 0x6F
    Regtest -> 0x6F
  }
  base58check_encode(<<version:8, pubkey_hash:bits>>)
}

fn encode_p2sh_address(script_hash: BitArray, network: Network) -> String {
  let version = case network {
    Mainnet -> 0x05
    Testnet -> 0xC4
    Regtest -> 0xC4
  }
  base58check_encode(<<version:8, script_hash:bits>>)
}

fn encode_bech32_address(data: BitArray, witness_version: Int, network: Network) -> String {
  let hrp = case network {
    Mainnet -> "bc"
    Testnet -> "tb"
    Regtest -> "bcrt"
  }
  bech32_encode(hrp, witness_version, data)
}

fn encode_bech32m_address(data: BitArray, witness_version: Int, network: Network) -> String {
  let hrp = case network {
    Mainnet -> "bc"
    Testnet -> "tb"
    Regtest -> "bcrt"
  }
  bech32m_encode(hrp, witness_version, data)
}

// ============================================================================
// Error Types
// ============================================================================

/// Descriptor parsing/operation errors
pub type DescriptorError {
  InvalidChecksum
  UnknownDescriptorType
  MissingClosingParen
  InvalidKey
  InvalidHex
  InvalidMultisig
  UnsupportedFeature
  DerivationFailed
  AddressEncodingFailed
}

// ============================================================================
// Helper Functions (Stubs)
// ============================================================================

fn hex_decode(s: String) -> Result(BitArray, Nil) {
  // Placeholder - use oni_bitcoin hex decode
  case bit_array.base16_decode(string.uppercase(s)) {
    Ok(bytes) -> Ok(bytes)
    Error(_) -> Error(Nil)
  }
}

fn hex_encode(bytes: BitArray) -> String {
  bit_array.base16_encode(bytes)
  |> string.lowercase
}

fn sha256(data: BitArray) -> BitArray {
  crypto_hash(<<"sha256">>, data)
}

fn hash160(data: BitArray) -> BitArray {
  let sha = sha256(data)
  ripemd160(sha)
}

fn ripemd160(data: BitArray) -> BitArray {
  crypto_hash(<<"ripemd160">>, data)
}

@external(erlang, "crypto", "hash")
fn crypto_hash(algorithm: BitArray, data: BitArray) -> BitArray

fn base58check_encode(_data: BitArray) -> String {
  // Placeholder - use oni_bitcoin base58check
  "placeholder"
}

fn bech32_encode(_hrp: String, _version: Int, _data: BitArray) -> String {
  // Placeholder - use oni_bitcoin bech32
  "bc1qplaceholder"
}

fn bech32m_encode(_hrp: String, _version: Int, _data: BitArray) -> String {
  // Placeholder - use oni_bitcoin bech32m
  "bc1pplaceholder"
}
