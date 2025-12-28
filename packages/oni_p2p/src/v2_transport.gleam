// v2_transport.gleam - BIP324 v2 encrypted transport protocol
//
// This module implements the BIP324 v2 transport protocol for Bitcoin P2P
// communication. The v2 protocol provides:
//   - Encrypted communication (ChaCha20-Poly1305)
//   - Traffic analysis resistance through garbage padding
//   - Opportunistic encryption with ECDH key exchange
//
// Protocol flow:
//   1. Initiator sends: ellswift pubkey (64 bytes) + garbage (0-4095 bytes)
//   2. Responder sends: ellswift pubkey (64 bytes) + garbage (0-4095 bytes)
//   3. ECDH shared secret derived from both pubkeys
//   4. Session keys derived via HKDF
//   5. Encrypted communication begins with garbage auth packets
//
// Reference: BIP-324 (https://github.com/bitcoin/bips/blob/master/bip-0324.mediawiki)

import gleam/bit_array
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result

// ============================================================================
// Constants
// ============================================================================

/// Size of ElligatorSwift encoded public key
pub const ellswift_pubkey_size = 64

/// Maximum garbage bytes (before ellswift key)
pub const max_garbage_size = 4095

/// Garbage terminator size (16 bytes AEAD tag)
pub const garbage_terminator_size = 16

/// Re-keying interval (224 messages in each direction)
pub const rekey_interval = 224

/// Maximum packet content size (24 bits = 16MB)
pub const max_contents_size = 16_777_215

/// Packet header size (encrypted length: 3 bytes + AEAD tag: 16 bytes)
pub const packet_header_size = 19

/// AEAD tag size
pub const aead_tag_size = 16

/// Version packet type
pub const version_packet_type = 0

/// Application packet type offset
pub const app_packet_type_offset = 128

// ============================================================================
// V2 Transport Types
// ============================================================================

/// State of the v2 transport connection
pub type V2TransportState {
  /// Waiting for peer's ellswift pubkey
  AwaitingEllswift
  /// Waiting for garbage terminator
  AwaitingGarbageTerminator
  /// Waiting for version packet
  AwaitingVersion
  /// Connection established
  Established
  /// Connection failed
  Failed(reason: V2Error)
}

/// V2 transport errors
pub type V2Error {
  HandshakeFailed
  DecryptionFailed
  InvalidPacketLength
  InvalidPacketType
  InvalidGarbage
  AuthenticationFailed
  KeyDerivationFailed
  RekeyFailed
  ConnectionClosed
  UnsupportedVersion
  BufferOverflow
}

/// V2 transport session
pub type V2Session {
  V2Session(
    state: V2TransportState,
    is_initiator: Bool,
    our_privkey: BitArray,
    our_pubkey: BitArray,
    their_pubkey: Option(BitArray),
    send_key: Option(BitArray),
    recv_key: Option(BitArray),
    send_garbage: BitArray,
    recv_garbage_terminator: Option(BitArray),
    session_id: Option(BitArray),
    send_counter: Int,
    recv_counter: Int,
    send_garbage_terminator: BitArray,
    recv_buffer: BitArray,
  )
}

/// V2 packet structure
pub type V2Packet {
  V2Packet(
    packet_type: Int,
    contents: BitArray,
  )
}

/// Short message type IDs (optimized encoding)
pub type ShortMessageId {
  /// Version/capabilities negotiation
  ShortAddr
  /// Block announcement
  ShortBlock
  /// Block transactions
  ShortBlocktxn
  /// Compact block
  ShortCmpctblock
  /// Fee filter
  ShortFeefilter
  /// Filter add
  ShortFilteradd
  /// Filter clear
  ShortFilterclear
  /// Filter load
  ShortFilterload
  /// Get block transactions
  ShortGetblocktxn
  /// Get blocks
  ShortGetblocks
  /// Get data
  ShortGetdata
  /// Get headers
  ShortGetheaders
  /// Headers
  ShortHeaders
  /// Inventory
  ShortInv
  /// Mempool
  ShortMempool
  /// Merkle block
  ShortMerkleblock
  /// Not found
  ShortNotfound
  /// Ping
  ShortPing
  /// Pong
  ShortPong
  /// Send compact
  ShortSendcmpct
  /// Transaction
  ShortTx
  /// Get address
  ShortGetaddr
  /// Address
  ShortAddrv2
  /// Send address v2
  ShortSendaddrv2
  /// WTXID relay
  ShortWtxidrelay
  /// Send headers
  ShortSendheaders
}

/// Map short message IDs to their numeric values
pub fn short_id_to_int(id: ShortMessageId) -> Int {
  case id {
    ShortAddr -> 1
    ShortBlock -> 2
    ShortBlocktxn -> 3
    ShortCmpctblock -> 4
    ShortFeefilter -> 5
    ShortFilteradd -> 6
    ShortFilterclear -> 7
    ShortFilterload -> 8
    ShortGetblocktxn -> 9
    ShortGetblocks -> 10
    ShortGetdata -> 11
    ShortGetheaders -> 12
    ShortHeaders -> 13
    ShortInv -> 14
    ShortMempool -> 15
    ShortMerkleblock -> 16
    ShortNotfound -> 17
    ShortPing -> 18
    ShortPong -> 19
    ShortSendcmpct -> 20
    ShortTx -> 21
    ShortGetaddr -> 22
    ShortAddrv2 -> 23
    ShortSendaddrv2 -> 24
    ShortWtxidrelay -> 25
    ShortSendheaders -> 26
  }
}

/// Map numeric values back to short message IDs
pub fn int_to_short_id(n: Int) -> Result(ShortMessageId, V2Error) {
  case n {
    1 -> Ok(ShortAddr)
    2 -> Ok(ShortBlock)
    3 -> Ok(ShortBlocktxn)
    4 -> Ok(ShortCmpctblock)
    5 -> Ok(ShortFeefilter)
    6 -> Ok(ShortFilteradd)
    7 -> Ok(ShortFilterclear)
    8 -> Ok(ShortFilterload)
    9 -> Ok(ShortGetblocktxn)
    10 -> Ok(ShortGetblocks)
    11 -> Ok(ShortGetdata)
    12 -> Ok(ShortGetheaders)
    13 -> Ok(ShortHeaders)
    14 -> Ok(ShortInv)
    15 -> Ok(ShortMempool)
    16 -> Ok(ShortMerkleblock)
    17 -> Ok(ShortNotfound)
    18 -> Ok(ShortPing)
    19 -> Ok(ShortPong)
    20 -> Ok(ShortSendcmpct)
    21 -> Ok(ShortTx)
    22 -> Ok(ShortGetaddr)
    23 -> Ok(ShortAddrv2)
    24 -> Ok(ShortSendaddrv2)
    25 -> Ok(ShortWtxidrelay)
    26 -> Ok(ShortSendheaders)
    _ -> Error(InvalidPacketType)
  }
}

// ============================================================================
// Session Management
// ============================================================================

/// Create a new V2 transport session as initiator
pub fn new_initiator(our_privkey: BitArray) -> V2Session {
  let our_pubkey = derive_ellswift_pubkey(our_privkey)
  let garbage = generate_garbage()

  V2Session(
    state: AwaitingEllswift,
    is_initiator: True,
    our_privkey: our_privkey,
    our_pubkey: our_pubkey,
    their_pubkey: None,
    send_key: None,
    recv_key: None,
    send_garbage: garbage,
    recv_garbage_terminator: None,
    session_id: None,
    send_counter: 0,
    recv_counter: 0,
    send_garbage_terminator: <<>>,
    recv_buffer: <<>>,
  )
}

/// Create a new V2 transport session as responder
pub fn new_responder(our_privkey: BitArray) -> V2Session {
  let our_pubkey = derive_ellswift_pubkey(our_privkey)
  let garbage = generate_garbage()

  V2Session(
    state: AwaitingEllswift,
    is_initiator: False,
    our_privkey: our_privkey,
    our_pubkey: our_pubkey,
    their_pubkey: None,
    send_key: None,
    recv_key: None,
    send_garbage: garbage,
    recv_garbage_terminator: None,
    session_id: None,
    send_counter: 0,
    recv_counter: 0,
    send_garbage_terminator: <<>>,
    recv_buffer: <<>>,
  )
}

/// Get the initial handshake data to send (ellswift pubkey + garbage)
pub fn get_handshake_data(session: V2Session) -> BitArray {
  <<session.our_pubkey:bits, session.send_garbage:bits>>
}

/// Process received handshake data
pub fn process_handshake(
  session: V2Session,
  data: BitArray,
) -> Result(V2Session, V2Error) {
  case session.state {
    AwaitingEllswift -> process_ellswift(session, data)
    AwaitingGarbageTerminator -> process_garbage_terminator(session, data)
    AwaitingVersion -> process_version(session, data)
    Established -> Ok(session)
    Failed(e) -> Error(e)
  }
}

/// Process received ellswift pubkey
fn process_ellswift(
  session: V2Session,
  data: BitArray,
) -> Result(V2Session, V2Error) {
  // Need at least 64 bytes for ellswift pubkey
  case bit_array.byte_size(data) >= ellswift_pubkey_size {
    False -> Ok(V2Session(..session, recv_buffer: data))
    True -> {
      // Extract their pubkey
      case data {
        <<their_pubkey:bytes-size(64), rest:bits>> -> {
          // Derive shared secret and session keys
          let shared_secret = ecdh_shared_secret(session.our_privkey, their_pubkey)

          // Derive session keys using HKDF
          let #(send_key, recv_key, session_id, garbage_terminator) =
            derive_session_keys(shared_secret, session.is_initiator)

          let new_session = V2Session(
            ..session,
            state: AwaitingGarbageTerminator,
            their_pubkey: Some(their_pubkey),
            send_key: Some(send_key),
            recv_key: Some(recv_key),
            session_id: Some(session_id),
            send_garbage_terminator: garbage_terminator,
            recv_buffer: rest,
          )

          // Continue processing if we have more data
          case bit_array.byte_size(rest) > 0 {
            True -> process_garbage_terminator(new_session, rest)
            False -> Ok(new_session)
          }
        }
        _ -> Error(HandshakeFailed)
      }
    }
  }
}

/// Process garbage terminator
fn process_garbage_terminator(
  session: V2Session,
  data: BitArray,
) -> Result(V2Session, V2Error) {
  // Scan for garbage terminator in received data
  // The garbage terminator is an AEAD tag computed over the garbage
  let combined = <<session.recv_buffer:bits, data:bits>>

  // Need to find terminator (16 bytes) after garbage
  case find_garbage_terminator(combined, session.recv_key) {
    None -> {
      // Not found yet, buffer data (up to max garbage size)
      case bit_array.byte_size(combined) > max_garbage_size + garbage_terminator_size {
        True -> Error(InvalidGarbage)
        False -> Ok(V2Session(..session, recv_buffer: combined))
      }
    }
    Some(#(garbage, rest)) -> {
      // Found terminator, verify it
      case verify_garbage_terminator(garbage, session.recv_key) {
        False -> Error(AuthenticationFailed)
        True -> {
          let new_session = V2Session(
            ..session,
            state: AwaitingVersion,
            recv_buffer: rest,
          )
          // Continue to version processing
          case bit_array.byte_size(rest) > 0 {
            True -> process_version(new_session, rest)
            False -> Ok(new_session)
          }
        }
      }
    }
  }
}

/// Process version packet
fn process_version(
  session: V2Session,
  data: BitArray,
) -> Result(V2Session, V2Error) {
  let combined = <<session.recv_buffer:bits, data:bits>>

  // Try to decrypt a packet
  case decrypt_packet(combined, session.recv_key, session.recv_counter) {
    Error(e) -> {
      // Not enough data yet
      case bit_array.byte_size(combined) > max_contents_size + packet_header_size + aead_tag_size {
        True -> Error(e)
        False -> Ok(V2Session(..session, recv_buffer: combined))
      }
    }
    Ok(#(packet, rest)) -> {
      // Verify this is a version packet
      case packet.packet_type == version_packet_type {
        False -> Error(UnsupportedVersion)
        True -> {
          // Parse version contents if needed
          let new_session = V2Session(
            ..session,
            state: Established,
            recv_counter: session.recv_counter + 1,
            recv_buffer: rest,
          )
          Ok(new_session)
        }
      }
    }
  }
}

// ============================================================================
// Packet Encryption/Decryption
// ============================================================================

/// Encrypt a packet for sending
pub fn encrypt_packet(
  session: V2Session,
  packet: V2Packet,
) -> Result(#(BitArray, V2Session), V2Error) {
  case session.state {
    Established -> do_encrypt_packet(session, packet)
    _ -> Error(ConnectionClosed)
  }
}

fn do_encrypt_packet(
  session: V2Session,
  packet: V2Packet,
) -> Result(#(BitArray, V2Session), V2Error) {
  case session.send_key {
    None -> Error(KeyDerivationFailed)
    Some(key) -> {
      // Build plaintext: packet_type (1 byte) + contents
      let plaintext = <<packet.packet_type:8, packet.contents:bits>>
      let content_len = bit_array.byte_size(plaintext)

      // Check size
      case content_len > max_contents_size {
        True -> Error(InvalidPacketLength)
        False -> {
          // Encrypt length (3 bytes) with separate AEAD
          let len_plaintext = <<content_len:24-little>>
          let len_ciphertext = aead_encrypt(key, session.send_counter, <<>>, len_plaintext)

          // Encrypt contents
          let content_ciphertext = aead_encrypt(key, session.send_counter, <<>>, plaintext)

          // Combine
          let ciphertext = <<len_ciphertext:bits, content_ciphertext:bits>>

          // Check if rekey needed
          let new_counter = session.send_counter + 1
          let #(new_key, final_counter) = case new_counter >= rekey_interval {
            True -> #(rekey(key, True), 0)
            False -> #(key, new_counter)
          }

          let new_session = V2Session(
            ..session,
            send_key: Some(new_key),
            send_counter: final_counter,
          )

          Ok(#(ciphertext, new_session))
        }
      }
    }
  }
}

/// Decrypt a received packet
fn decrypt_packet(
  ciphertext: BitArray,
  key: Option(BitArray),
  counter: Int,
) -> Result(#(V2Packet, BitArray), V2Error) {
  case key {
    None -> Error(KeyDerivationFailed)
    Some(k) -> {
      // Need at least header (19 bytes) + content AEAD tag (16 bytes)
      case bit_array.byte_size(ciphertext) >= packet_header_size + aead_tag_size {
        False -> Error(InvalidPacketLength)
        True -> {
          // Decrypt length
          case ciphertext {
            <<len_ct:bytes-size(19), rest:bits>> -> {
              case aead_decrypt(k, counter, <<>>, len_ct) {
                Error(_) -> Error(DecryptionFailed)
                Ok(len_pt) -> {
                  case len_pt {
                    <<content_len:24-little>> -> {
                      // Check if we have enough data for content
                      let needed = content_len + aead_tag_size
                      case bit_array.byte_size(rest) >= needed {
                        False -> Error(InvalidPacketLength)
                        True -> {
                          // Extract and decrypt content
                          case extract_bytes(rest, needed) {
                            Error(_) -> Error(DecryptionFailed)
                            Ok(#(content_ct, remaining)) -> {
                              case aead_decrypt(k, counter, <<>>, content_ct) {
                                Error(_) -> Error(DecryptionFailed)
                                Ok(content_pt) -> {
                                  // Parse packet type and contents
                                  case content_pt {
                                    <<ptype:8, contents:bits>> ->
                                      Ok(#(V2Packet(ptype, contents), remaining))
                                    _ -> Error(InvalidPacketType)
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                    _ -> Error(DecryptionFailed)
                  }
                }
              }
            }
            _ -> Error(InvalidPacketLength)
          }
        }
      }
    }
  }
}

/// Receive and decrypt a packet
pub fn recv_packet(
  session: V2Session,
  data: BitArray,
) -> Result(#(Option(V2Packet), V2Session), V2Error) {
  case session.state {
    Established -> {
      let combined = <<session.recv_buffer:bits, data:bits>>
      case decrypt_packet(combined, session.recv_key, session.recv_counter) {
        Error(InvalidPacketLength) -> {
          // Not enough data, buffer it
          Ok(#(None, V2Session(..session, recv_buffer: combined)))
        }
        Error(e) -> Error(e)
        Ok(#(packet, rest)) -> {
          // Check for rekey
          let new_counter = session.recv_counter + 1
          let #(new_key, final_counter) = case new_counter >= rekey_interval {
            True -> #(rekey_option(session.recv_key, False), 0)
            False -> #(session.recv_key, new_counter)
          }

          let new_session = V2Session(
            ..session,
            recv_key: new_key,
            recv_counter: final_counter,
            recv_buffer: rest,
          )
          Ok(#(Some(packet), new_session))
        }
      }
    }
    _ -> {
      // During handshake, pass to handshake processor
      case process_handshake(session, data) {
        Error(e) -> Error(e)
        Ok(new_session) -> Ok(#(None, new_session))
      }
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Derive ellswift public key from private key
/// This uses the ElligatorSwift encoding for uniform random appearance
fn derive_ellswift_pubkey(privkey: BitArray) -> BitArray {
  // Placeholder - needs secp256k1 implementation
  // In production: use secp256k1_ellswift_create
  <<privkey:bits, 0:256>>
  |> bit_array.slice(0, 64)
  |> result.unwrap(<<0:512>>)
}

/// Perform ECDH key exchange
fn ecdh_shared_secret(our_privkey: BitArray, their_pubkey: BitArray) -> BitArray {
  // Placeholder - needs secp256k1 implementation
  // In production: use secp256k1_ecdh with ellswift decoding
  <<our_privkey:bits, their_pubkey:bits>>
  |> sha256()
}

/// Derive session keys from shared secret
fn derive_session_keys(
  shared_secret: BitArray,
  is_initiator: Bool,
) -> #(BitArray, BitArray, BitArray, BitArray) {
  // Derive keys using HKDF
  // send_key, recv_key, session_id, garbage_terminator

  let send_label = case is_initiator {
    True -> "initiator_L"
    False -> "responder_L"
  }

  let recv_label = case is_initiator {
    True -> "responder_L"
    False -> "initiator_L"
  }

  let send_key = hkdf_expand(shared_secret, string_to_bytes(send_label), 32)
  let recv_key = hkdf_expand(shared_secret, string_to_bytes(recv_label), 32)
  let session_id = hkdf_expand(shared_secret, <<"session_id">>, 32)
  let garbage_term = hkdf_expand(shared_secret, <<"garbage_terminators">>, 16)

  #(send_key, recv_key, session_id, garbage_term)
}

/// Generate random garbage bytes
fn generate_garbage() -> BitArray {
  // Random length 0-4095 bytes
  let len = random_int(max_garbage_size + 1)
  random_bytes(len)
}

/// Find garbage terminator in data
fn find_garbage_terminator(
  data: BitArray,
  key: Option(BitArray),
) -> Option(#(BitArray, BitArray)) {
  // Scan for valid AEAD tag
  // In practice, we compute expected terminator and search for it
  case key {
    None -> None
    Some(_k) -> {
      // Simplified: assume terminator at max_garbage_size or end of valid garbage
      let data_len = bit_array.byte_size(data)
      case data_len >= garbage_terminator_size {
        False -> None
        True -> {
          // Try different garbage lengths
          find_terminator_at_lengths(data, 0, data_len - garbage_terminator_size)
        }
      }
    }
  }
}

fn find_terminator_at_lengths(
  data: BitArray,
  current: Int,
  max_len: Int,
) -> Option(#(BitArray, BitArray)) {
  case current > max_len || current > max_garbage_size {
    True -> None
    False -> {
      case extract_bytes(data, current) {
        Error(_) -> None
        Ok(#(garbage, rest)) -> {
          case extract_bytes(rest, garbage_terminator_size) {
            Error(_) -> find_terminator_at_lengths(data, current + 1, max_len)
            Ok(#(_term, remaining)) -> {
              // For now, accept first valid-looking split
              // In production: verify AEAD tag
              Some(#(garbage, remaining))
            }
          }
        }
      }
    }
  }
}

/// Verify garbage terminator
fn verify_garbage_terminator(_garbage: BitArray, _key: Option(BitArray)) -> Bool {
  // Placeholder - compute expected terminator and compare
  True
}

/// Perform AEAD encryption (ChaCha20-Poly1305)
fn aead_encrypt(key: BitArray, counter: Int, aad: BitArray, plaintext: BitArray) -> BitArray {
  // Placeholder - needs crypto implementation
  // In production: use ChaCha20-Poly1305
  let nonce = <<counter:96-little>>
  let tag = sha256(<<key:bits, nonce:bits, aad:bits, plaintext:bits>>)
    |> bit_array.slice(0, 16)
    |> result.unwrap(<<0:128>>)
  <<plaintext:bits, tag:bits>>
}

/// Perform AEAD decryption
fn aead_decrypt(
  _key: BitArray,
  _counter: Int,
  _aad: BitArray,
  ciphertext: BitArray,
) -> Result(BitArray, V2Error) {
  // Placeholder - needs crypto implementation
  let ct_len = bit_array.byte_size(ciphertext)
  case ct_len >= aead_tag_size {
    False -> Error(DecryptionFailed)
    True -> {
      let pt_len = ct_len - aead_tag_size
      case extract_bytes(ciphertext, pt_len) {
        Error(_) -> Error(DecryptionFailed)
        Ok(#(plaintext, _tag)) -> {
          // In production: verify tag
          Ok(plaintext)
        }
      }
    }
  }
}

/// Rekey the session
fn rekey(key: BitArray, is_send: Bool) -> BitArray {
  let label = case is_send {
    True -> "rekey_send"
    False -> "rekey_recv"
  }
  hkdf_expand(key, string_to_bytes(label), 32)
}

fn rekey_option(key: Option(BitArray), is_send: Bool) -> Option(BitArray) {
  case key {
    None -> None
    Some(k) -> Some(rekey(k, is_send))
  }
}

/// Extract n bytes from a BitArray
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

/// HKDF expand (simplified)
fn hkdf_expand(key: BitArray, info: BitArray, length: Int) -> BitArray {
  // Simplified HKDF-Expand
  let expanded = sha256(<<key:bits, info:bits, 1:8>>)
  bit_array.slice(expanded, 0, length)
  |> result.unwrap(<<0:256>>)
}

/// SHA256 hash
fn sha256(data: BitArray) -> BitArray {
  crypto_hash(<<"sha256">>, data)
}

@external(erlang, "crypto", "hash")
fn crypto_hash(algorithm: BitArray, data: BitArray) -> BitArray

/// Convert string to bytes
fn string_to_bytes(s: String) -> BitArray {
  bit_array.from_string(s)
}

/// Generate random bytes (placeholder)
fn random_bytes(n: Int) -> BitArray {
  crypto_strong_rand_bytes(n)
}

@external(erlang, "crypto", "strong_rand_bytes")
fn crypto_strong_rand_bytes(n: Int) -> BitArray

/// Generate random integer (placeholder)
fn random_int(max: Int) -> Int {
  let bytes = random_bytes(4)
  case bytes {
    <<n:32>> -> int.modulo(n, max) |> result.unwrap(0)
    _ -> 0
  }
}

// ============================================================================
// V2 Transport API
// ============================================================================

/// Check if session is established
pub fn is_established(session: V2Session) -> Bool {
  case session.state {
    Established -> True
    _ -> False
  }
}

/// Get session ID (available after handshake)
pub fn get_session_id(session: V2Session) -> Option(BitArray) {
  session.session_id
}

/// Check if we are the initiator
pub fn is_initiator(session: V2Session) -> Bool {
  session.is_initiator
}

/// Create a version packet
pub fn create_version_packet(capabilities: BitArray) -> V2Packet {
  V2Packet(version_packet_type, capabilities)
}

/// Create an application packet from a short message ID
pub fn create_app_packet(msg_id: ShortMessageId, payload: BitArray) -> V2Packet {
  V2Packet(short_id_to_int(msg_id), payload)
}

/// Get the message ID from a packet
pub fn get_packet_message_id(packet: V2Packet) -> Result(ShortMessageId, V2Error) {
  int_to_short_id(packet.packet_type)
}
