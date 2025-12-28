// v2_transport_test.gleam - Tests for BIP324 v2 transport protocol

import gleam/bit_array
import gleam/option.{None, Some}
import oni_p2p/v2_transport.{
  AwaitingEllswift, AwaitingGarbageTerminator, Established,
  ShortBlock, ShortPing, ShortPong, ShortTx,
  V2Packet,
}

// ============================================================================
// Session Creation Tests
// ============================================================================

pub fn new_initiator_creates_session_test() {
  let privkey = <<1:256>>
  let session = v2_transport.new_initiator(privkey)

  let assert True = session.is_initiator == True
  let assert True = session.state == AwaitingEllswift
  let assert True = session.send_counter == 0
  let assert True = session.recv_counter == 0
}

pub fn new_responder_creates_session_test() {
  let privkey = <<2:256>>
  let session = v2_transport.new_responder(privkey)

  let assert True = session.is_initiator == False
  let assert True = session.state == AwaitingEllswift
}

pub fn initiator_generates_handshake_data_test() {
  let privkey = <<1:256>>
  let session = v2_transport.new_initiator(privkey)

  let handshake = v2_transport.get_handshake_data(session)

  // Should be at least 64 bytes (ellswift pubkey)
  let assert True = bit_array.byte_size(handshake) >= 64
}

// ============================================================================
// Short Message ID Tests
// ============================================================================

pub fn short_id_to_int_test() {
  let assert True = v2_transport.short_id_to_int(ShortPing) == 18
  let assert True = v2_transport.short_id_to_int(ShortPong) == 19
  let assert True = v2_transport.short_id_to_int(ShortTx) == 21
  let assert True = v2_transport.short_id_to_int(ShortBlock) == 2
}

pub fn int_to_short_id_test() {
  let assert True = v2_transport.int_to_short_id(18) == Ok(ShortPing)
  let assert True = v2_transport.int_to_short_id(19) == Ok(ShortPong)
  let assert True = v2_transport.int_to_short_id(21) == Ok(ShortTx)
  let assert True = v2_transport.int_to_short_id(2) == Ok(ShortBlock)
}

pub fn int_to_short_id_invalid_test() {
  let result = v2_transport.int_to_short_id(255)
  let assert True = result == Error(v2_transport.InvalidPacketType)
}

pub fn short_id_roundtrip_test() {
  // All short IDs should roundtrip
  let ids = [
    ShortPing, ShortPong, ShortTx, ShortBlock,
  ]

  let assert True = check_roundtrip(ids)
}

fn check_roundtrip(ids: List(v2_transport.ShortMessageId)) -> Bool {
  case ids {
    [] -> True
    [id, ..rest] -> {
      let n = v2_transport.short_id_to_int(id)
      case v2_transport.int_to_short_id(n) {
        Ok(recovered) if recovered == id -> check_roundtrip(rest)
        _ -> False
      }
    }
  }
}

// ============================================================================
// Packet Tests
// ============================================================================

pub fn create_version_packet_test() {
  let capabilities = <<1, 0, 0, 0>>
  let packet = v2_transport.create_version_packet(capabilities)

  let assert True = packet.packet_type == 0
  let assert True = packet.contents == capabilities
}

pub fn create_app_packet_test() {
  let payload = <<"ping data":utf8>>
  let packet = v2_transport.create_app_packet(ShortPing, payload)

  let assert True = packet.packet_type == 18
  let assert True = packet.contents == payload
}

pub fn get_packet_message_id_test() {
  let packet = V2Packet(18, <<"test":utf8>>)

  let result = v2_transport.get_packet_message_id(packet)

  let assert True = result == Ok(ShortPing)
}

// ============================================================================
// Session State Tests
// ============================================================================

pub fn session_not_established_initially_test() {
  let privkey = <<1:256>>
  let session = v2_transport.new_initiator(privkey)

  let assert True = v2_transport.is_established(session) == False
}

pub fn session_id_none_before_handshake_test() {
  let privkey = <<1:256>>
  let session = v2_transport.new_initiator(privkey)

  let assert True = v2_transport.get_session_id(session) == None
}

pub fn is_initiator_correct_test() {
  let privkey = <<1:256>>

  let initiator = v2_transport.new_initiator(privkey)
  let responder = v2_transport.new_responder(privkey)

  let assert True = v2_transport.is_initiator(initiator) == True
  let assert True = v2_transport.is_initiator(responder) == False
}

// ============================================================================
// Constants Tests
// ============================================================================

pub fn constants_are_correct_test() {
  // Verify BIP324 constants
  let assert True = v2_transport.ellswift_pubkey_size == 64
  let assert True = v2_transport.max_garbage_size == 4095
  let assert True = v2_transport.garbage_terminator_size == 16
  let assert True = v2_transport.rekey_interval == 224
  let assert True = v2_transport.max_contents_size == 16_777_215
  let assert True = v2_transport.aead_tag_size == 16
  let assert True = v2_transport.version_packet_type == 0
}

// ============================================================================
// Handshake Processing Tests
// ============================================================================

pub fn process_insufficient_data_buffers_test() {
  let privkey = <<1:256>>
  let session = v2_transport.new_initiator(privkey)

  // Send only 32 bytes (need 64 for ellswift)
  let data = <<0:256>>

  let result = v2_transport.process_handshake(session, data)

  case result {
    Ok(new_session) -> {
      // Should still be awaiting ellswift, data buffered
      let assert True = new_session.state == AwaitingEllswift
      let assert True = bit_array.byte_size(new_session.recv_buffer) == 32
    }
    Error(_) -> panic as "Should buffer insufficient data"
  }
}

pub fn process_full_ellswift_advances_state_test() {
  let privkey = <<1:256>>
  let session = v2_transport.new_initiator(privkey)

  // Send 64 bytes (full ellswift pubkey)
  let their_pubkey = <<0:512>>

  let result = v2_transport.process_handshake(session, their_pubkey)

  case result {
    Ok(new_session) -> {
      // Should advance to awaiting garbage terminator
      let assert True = new_session.state == AwaitingGarbageTerminator
      let assert True = new_session.their_pubkey != None
    }
    Error(_) -> panic as "Should advance state on full ellswift"
  }
}

// ============================================================================
// Encryption/Decryption Framework Tests
// ============================================================================

pub fn encrypt_packet_requires_established_test() {
  let privkey = <<1:256>>
  let session = v2_transport.new_initiator(privkey)
  let packet = V2Packet(0, <<"test":utf8>>)

  let result = v2_transport.encrypt_packet(session, packet)

  // Should fail because session not established
  let assert True = result == Error(v2_transport.ConnectionClosed)
}

// ============================================================================
// Receive Tests
// ============================================================================

pub fn recv_during_handshake_processes_handshake_test() {
  let privkey = <<1:256>>
  let session = v2_transport.new_initiator(privkey)

  let data = <<0:256>>  // 32 bytes, not enough

  let result = v2_transport.recv_packet(session, data)

  case result {
    Ok(#(packet, new_session)) -> {
      // No packet yet
      let assert True = packet == None
      // Session should buffer data
      let assert True = bit_array.byte_size(new_session.recv_buffer) == 32
    }
    Error(_) -> panic as "Should buffer data during handshake"
  }
}

// ============================================================================
// End-to-End Simulation Tests
// ============================================================================

pub fn initiator_responder_can_exchange_pubkeys_test() {
  let init_privkey = <<1:256>>
  let resp_privkey = <<2:256>>

  let initiator = v2_transport.new_initiator(init_privkey)
  let responder = v2_transport.new_responder(resp_privkey)

  // Get handshake data
  let init_handshake = v2_transport.get_handshake_data(initiator)
  let resp_handshake = v2_transport.get_handshake_data(responder)

  // Exchange ellswift pubkeys (first 64 bytes only for simplicity)
  let init_pubkey = case bit_array.slice(init_handshake, 0, 64) {
    Ok(p) -> p
    Error(_) -> <<0:512>>
  }
  let resp_pubkey = case bit_array.slice(resp_handshake, 0, 64) {
    Ok(p) -> p
    Error(_) -> <<0:512>>
  }

  // Process each other's pubkey
  let init_result = v2_transport.process_handshake(initiator, resp_pubkey)
  let resp_result = v2_transport.process_handshake(responder, init_pubkey)

  // Both should advance
  case init_result, resp_result {
    Ok(new_init), Ok(new_resp) -> {
      let assert True = new_init.their_pubkey != None
      let assert True = new_resp.their_pubkey != None
    }
    _, _ -> panic as "Both should process pubkey exchange"
  }
}
