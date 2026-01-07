// p2p_network.gleam - TCP network layer for P2P connections
//
// This module provides the TCP networking layer for Bitcoin P2P:
// - TCP listener for inbound connections
// - Outbound connection management
// - Message framing (read/write messages)
// - Peer actor management
//
// Usage:
//   1. Create listener with start_listener(config)
//   2. Connect to peers with connect_peer(addr)
//   3. Send/receive messages through peer subjects

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import oni_bitcoin
import oni_p2p.{
  type Message, type NetAddr, type P2PError, type ServiceFlags,
  type VersionPayload, MsgPing, MsgPong, MsgVerack, MsgVersion,
}

// ============================================================================
// Network Configuration
// ============================================================================

/// P2P network configuration
pub type P2PConfig {
  P2PConfig(
    /// Bitcoin network (mainnet, testnet, etc.)
    network: oni_bitcoin.Network,
    /// Listen port (0 = don't listen)
    listen_port: Int,
    /// Bind address
    bind_address: String,
    /// Maximum inbound connections
    max_inbound: Int,
    /// Maximum outbound connections
    max_outbound: Int,
    /// Connection timeout in milliseconds
    connect_timeout_ms: Int,
    /// Our services
    services: ServiceFlags,
    /// Our best block height
    best_height: Int,
  )
}

/// Default P2P configuration
pub fn default_config(network: oni_bitcoin.Network) -> P2PConfig {
  P2PConfig(
    network: network,
    listen_port: 8333,
    bind_address: "0.0.0.0",
    max_inbound: 117,
    max_outbound: 11,
    connect_timeout_ms: 5000,
    services: oni_p2p.default_services(),
    best_height: 0,
  )
}

// ============================================================================
// Peer Connection State
// ============================================================================

/// Peer connection state
pub type PeerState {
  /// Initial connection, no handshake yet
  PeerConnecting
  /// Version sent, waiting for version
  PeerAwaitingVersion
  /// Version received, waiting for verack
  PeerAwaitingVerack
  /// Handshake complete, ready for messages
  PeerReady
  /// Disconnecting
  PeerDisconnecting
  /// Disconnected
  PeerClosed
}

/// Peer info
pub type PeerInfo {
  PeerInfo(
    id: Int,
    addr: NetAddr,
    state: PeerState,
    inbound: Bool,
    version: Option(VersionPayload),
    last_recv: Int,
    last_send: Int,
    bytes_recv: Int,
    bytes_sent: Int,
    ping_nonce: Option(Int),
    ping_time: Option(Int),
  )
}

/// Opaque socket type
pub type Socket

/// Opaque listen socket type
pub type ListenSocket

// ============================================================================
// Peer Actor Messages
// ============================================================================

/// Messages to a peer actor
pub type PeerMsg {
  /// Initialize the peer (send version for outbound)
  PeerInit(self_subject: Subject(PeerMsg))
  /// Send a message to the peer
  SendMessage(message: Message)
  /// Message received from network
  ReceivedData(data: BitArray)
  /// Connection closed
  SocketClosed
  /// Socket error
  SocketError(reason: String)
  /// Get peer info
  GetInfo(reply_to: Subject(PeerInfo))
  /// Disconnect the peer
  Disconnect
}

/// Messages from peer actor to parent
pub type PeerEvent {
  /// Message received from peer
  MessageReceived(peer_id: Int, message: Message)
  /// Peer handshake completed
  PeerHandshakeComplete(peer_id: Int, version: VersionPayload)
  /// Peer disconnected
  PeerDisconnectedEvent(peer_id: Int, reason: String)
  /// Peer error
  PeerError(peer_id: Int, error: P2PError)
}

// ============================================================================
// Peer Actor State
// ============================================================================

/// Internal peer actor state
type PeerActorState {
  PeerActorState(
    info: PeerInfo,
    socket: Socket,
    config: P2PConfig,
    parent: Subject(PeerEvent),
    self_subject: Option(Subject(PeerMsg)),
    recv_buffer: BitArray,
  )
}

// ============================================================================
// Listener State and Messages
// ============================================================================

/// Listener actor state
pub type ListenerState {
  ListenerState(
    config: P2PConfig,
    listen_socket: Option(ListenSocket),
    peers: Dict(Int, Subject(PeerMsg)),
    next_peer_id: Int,
    event_handler: Subject(PeerEvent),
    self_subject: Option(Subject(ListenerMsg)),
    is_running: Bool,
  )
}

/// Messages to the listener actor
pub type ListenerMsg {
  /// Initialize with self subject
  ListenerInit(self_subject: Subject(ListenerMsg))
  /// Start listening
  StartListening
  /// Stop listening
  StopListening
  /// New inbound connection
  InboundConnection(socket: Socket)
  /// Connect to peer
  ConnectTo(addr: NetAddr)
  /// Connection established (outbound)
  OutboundConnected(addr: NetAddr, socket: Socket)
  /// Connection failed
  ConnectionFailed(addr: NetAddr, reason: String)
  /// Peer event
  PeerEventReceived(event: PeerEvent)
  /// Get peer count
  GetPeerCount(reply_to: Subject(Int))
  /// Broadcast message to all peers
  BroadcastMessage(message: Message)
  /// Send message to specific peer
  SendToPeer(peer_id: Int, message: Message)
  /// Get list of connected peer IDs
  GetPeerIds(reply_to: Subject(List(Int)))
}

// ============================================================================
// Listener Actor
// ============================================================================

/// Start the P2P listener
pub fn start_listener(
  config: P2PConfig,
  event_handler: Subject(PeerEvent),
) -> Result(Subject(ListenerMsg), actor.StartError) {
  let initial_state =
    ListenerState(
      config: config,
      listen_socket: None,
      peers: dict.new(),
      next_peer_id: 1,
      event_handler: event_handler,
      self_subject: None,
      is_running: False,
    )

  case actor.start(initial_state, handle_listener_message) {
    Ok(subject) -> {
      process.send(subject, ListenerInit(subject))
      Ok(subject)
    }
    Error(e) -> Error(e)
  }
}

/// Handle listener messages
fn handle_listener_message(
  msg: ListenerMsg,
  state: ListenerState,
) -> actor.Next(ListenerMsg, ListenerState) {
  case msg {
    ListenerInit(self_subject) -> {
      actor.continue(ListenerState(..state, self_subject: Some(self_subject)))
    }

    StartListening -> {
      case state.self_subject {
        None -> actor.continue(state)
        Some(self) -> {
          case state.config.listen_port > 0 {
            False -> {
              io.println("[P2P] Not listening (port 0)")
              actor.continue(ListenerState(..state, is_running: True))
            }
            True -> {
              case
                tcp_listen(state.config.listen_port, state.config.bind_address)
              {
                Error(reason) -> {
                  io.println("[P2P] Failed to listen: " <> reason)
                  actor.continue(state)
                }
                Ok(listen_socket) -> {
                  io.println(
                    "[P2P] Listening on "
                    <> state.config.bind_address
                    <> ":"
                    <> int.to_string(state.config.listen_port),
                  )

                  // Start accept loop
                  spawn_acceptor(listen_socket, self)

                  actor.continue(
                    ListenerState(
                      ..state,
                      listen_socket: Some(listen_socket),
                      is_running: True,
                    ),
                  )
                }
              }
            }
          }
        }
      }
    }

    StopListening -> {
      io.println("[P2P] Stopping listener...")
      case state.listen_socket {
        Some(socket) -> tcp_close_listen(socket)
        None -> Nil
      }
      // Disconnect all peers
      dict.fold(state.peers, Nil, fn(_acc, _id, peer_subject) {
        process.send(peer_subject, Disconnect)
      })
      actor.Stop(process.Normal)
    }

    InboundConnection(socket) -> {
      case state.self_subject {
        None -> {
          tcp_close(socket)
          actor.continue(state)
        }
        Some(self) -> {
          // Check if we have room for more inbound
          let inbound_count = count_inbound_peers(state.peers)
          case inbound_count >= state.config.max_inbound {
            True -> {
              tcp_close(socket)
              // Continue accepting
              case state.listen_socket {
                Some(ls) -> spawn_acceptor(ls, self)
                None -> Nil
              }
              actor.continue(state)
            }
            False -> {
              let peer_id = state.next_peer_id
              let peer_addr = socket_peer_addr(socket)

              io.println(
                "[P2P] Inbound connection from "
                <> oni_p2p.ip_to_string(peer_addr.ip)
                <> ":"
                <> int.to_string(peer_addr.port),
              )

              // Start peer actor
              case
                start_peer_actor(
                  peer_id,
                  socket,
                  peer_addr,
                  True,
                  state.config,
                  state.event_handler,
                )
              {
                Error(_) -> {
                  tcp_close(socket)
                  actor.continue(state)
                }
                Ok(peer_subject) -> {
                  // Continue accepting
                  case state.listen_socket {
                    Some(ls) -> spawn_acceptor(ls, self)
                    None -> Nil
                  }

                  actor.continue(
                    ListenerState(
                      ..state,
                      peers: dict.insert(state.peers, peer_id, peer_subject),
                      next_peer_id: peer_id + 1,
                    ),
                  )
                }
              }
            }
          }
        }
      }
    }

    ConnectTo(addr) -> {
      case state.self_subject {
        None -> actor.continue(state)
        Some(self) -> {
          // Check if we have room for more outbound
          let outbound_count = count_outbound_peers(state.peers)
          case outbound_count >= state.config.max_outbound {
            True -> {
              process.send(
                state.event_handler,
                PeerError(
                  0,
                  oni_p2p.ConnectionFailed("Too many outbound connections"),
                ),
              )
              actor.continue(state)
            }
            False -> {
              io.println(
                "[P2P] Connecting to "
                <> oni_p2p.ip_to_string(addr.ip)
                <> ":"
                <> int.to_string(addr.port),
              )

              // Spawn connection attempt
              spawn_connector(addr, state.config.connect_timeout_ms, self)
              actor.continue(state)
            }
          }
        }
      }
    }

    OutboundConnected(addr, socket) -> {
      let peer_id = state.next_peer_id

      io.println(
        "[P2P] Connected to "
        <> oni_p2p.ip_to_string(addr.ip)
        <> ":"
        <> int.to_string(addr.port),
      )

      case
        start_peer_actor(
          peer_id,
          socket,
          addr,
          False,
          state.config,
          state.event_handler,
        )
      {
        Error(_) -> {
          tcp_close(socket)
          actor.continue(state)
        }
        Ok(peer_subject) -> {
          actor.continue(
            ListenerState(
              ..state,
              peers: dict.insert(state.peers, peer_id, peer_subject),
              next_peer_id: peer_id + 1,
            ),
          )
        }
      }
    }

    ConnectionFailed(addr, reason) -> {
      io.println(
        "[P2P] Connection to "
        <> oni_p2p.ip_to_string(addr.ip)
        <> " failed: "
        <> reason,
      )
      process.send(
        state.event_handler,
        PeerError(0, oni_p2p.ConnectionFailed(reason)),
      )
      actor.continue(state)
    }

    PeerEventReceived(event) -> {
      // Forward event and update state
      process.send(state.event_handler, event)

      case event {
        PeerDisconnectedEvent(peer_id, _reason) -> {
          actor.continue(
            ListenerState(..state, peers: dict.delete(state.peers, peer_id)),
          )
        }
        _ -> actor.continue(state)
      }
    }

    GetPeerCount(reply_to) -> {
      process.send(reply_to, dict.size(state.peers))
      actor.continue(state)
    }

    BroadcastMessage(message) -> {
      let peer_count = dict.size(state.peers)
      io.println(
        "[P2P] Broadcasting message to "
        <> int.to_string(peer_count)
        <> " connected peers",
      )
      dict.fold(state.peers, Nil, fn(_acc, peer_id, peer_subject) {
        io.println("[P2P] Sending to peer " <> int.to_string(peer_id))
        process.send(peer_subject, SendMessage(message))
      })
      actor.continue(state)
    }

    SendToPeer(peer_id, message) -> {
      case dict.get(state.peers, peer_id) {
        Ok(peer_subject) -> {
          process.send(peer_subject, SendMessage(message))
        }
        Error(_) -> {
          // Peer not found, ignore silently
          Nil
        }
      }
      actor.continue(state)
    }

    GetPeerIds(reply_to) -> {
      process.send(reply_to, dict.keys(state.peers))
      actor.continue(state)
    }
  }
}

// Helper to count inbound peers (placeholder - would need to track this)
fn count_inbound_peers(_peers: Dict(Int, Subject(PeerMsg))) -> Int {
  0
  // Would iterate and count inbound
}

fn count_outbound_peers(_peers: Dict(Int, Subject(PeerMsg))) -> Int {
  0
  // Would iterate and count outbound
}

// ============================================================================
// Peer Actor
// ============================================================================

/// Start a peer actor for a connected socket
fn start_peer_actor(
  peer_id: Int,
  socket: Socket,
  addr: NetAddr,
  inbound: Bool,
  config: P2PConfig,
  parent: Subject(PeerEvent),
) -> Result(Subject(PeerMsg), actor.StartError) {
  let info =
    PeerInfo(
      id: peer_id,
      addr: addr,
      state: PeerConnecting,
      inbound: inbound,
      version: None,
      last_recv: erlang_now_ms(),
      last_send: 0,
      bytes_recv: 0,
      bytes_sent: 0,
      ping_nonce: None,
      ping_time: None,
    )

  let initial_state =
    PeerActorState(
      info: info,
      socket: socket,
      config: config,
      parent: parent,
      self_subject: None,
      recv_buffer: <<>>,
    )

  case actor.start(initial_state, handle_peer_message) {
    Ok(subject) -> {
      // Transfer socket ownership to the peer actor process
      case transfer_socket_ownership(socket, subject) {
        Ok(_) -> {
          // Initialize and start handshake
          process.send(subject, peer_init_msg(subject))
          Ok(subject)
        }
        Error(err) -> {
          io.println("[P2P] Failed to transfer socket ownership: " <> err)
          // Actor started but can't use socket, return error
          Error(actor.InitTimeout)
        }
      }
    }
    Error(e) -> Error(e)
  }
}

/// Create the init message
fn peer_init_msg(subject: Subject(PeerMsg)) -> PeerMsg {
  PeerInit(subject)
}

/// Handle peer messages
fn handle_peer_message(
  msg: PeerMsg,
  state: PeerActorState,
) -> actor.Next(PeerMsg, PeerActorState) {
  case msg {
    PeerInit(self_subject) -> {
      // Save the self subject
      let new_state = PeerActorState(..state, self_subject: Some(self_subject))

      // For outbound connections, we send version first
      case state.info.inbound {
        False -> {
          io.println(
            "[P2P] Peer "
            <> int.to_string(state.info.id)
            <> " sending version (outbound)",
          )
          let version =
            oni_p2p.version_message(
              state.config.services,
              erlang_now_secs(),
              state.info.addr,
              generate_nonce(),
              state.config.best_height,
            )
          case encode_and_send(state.socket, version, state.config.network) {
            Ok(bytes_sent) ->
              io.println(
                "[P2P] Peer "
                <> int.to_string(state.info.id)
                <> " sent version ("
                <> int.to_string(bytes_sent)
                <> " bytes)",
              )
            Error(err) ->
              io.println(
                "[P2P] Peer "
                <> int.to_string(state.info.id)
                <> " version send failed: "
                <> err,
              )
          }
          Nil
        }
        True -> {
          io.println(
            "[P2P] Peer "
            <> int.to_string(state.info.id)
            <> " waiting for version (inbound)",
          )
          Nil
        }
      }

      // Start receiving data from socket
      spawn_receiver(state.socket, self_subject)

      actor.continue(new_state)
    }

    SendMessage(message) -> {
      case encode_and_send(state.socket, message, state.config.network) {
        Error(_reason) -> {
          process.send(
            state.parent,
            PeerDisconnectedEvent(state.info.id, "Send failed"),
          )
          actor.Stop(process.Normal)
        }
        Ok(bytes_sent) -> {
          let new_info =
            PeerInfo(
              ..state.info,
              last_send: erlang_now_ms(),
              bytes_sent: state.info.bytes_sent + bytes_sent,
            )
          actor.continue(PeerActorState(..state, info: new_info))
        }
      }
    }

    ReceivedData(data) -> {
      let new_buffer = bit_array.append(state.recv_buffer, data)
      let new_info =
        PeerInfo(
          ..state.info,
          last_recv: erlang_now_ms(),
          bytes_recv: state.info.bytes_recv + bit_array.byte_size(data),
        )

      // Try to parse messages from buffer
      case try_parse_messages(new_buffer, state.config.network) {
        Error(reason) -> {
          io.println(
            "[P2P] Peer "
            <> int.to_string(state.info.id)
            <> " parse error: "
            <> reason,
          )
          process.send(
            state.parent,
            PeerError(state.info.id, oni_p2p.InvalidMessage(reason)),
          )
          actor.Stop(process.Normal)
        }
        Ok(#(messages, remaining)) -> {
          // Process each message
          let final_state =
            process_messages(
              messages,
              PeerActorState(..state, info: new_info, recv_buffer: remaining),
            )
          actor.continue(final_state)
        }
      }
    }

    SocketClosed -> {
      process.send(
        state.parent,
        PeerDisconnectedEvent(state.info.id, "Connection closed"),
      )
      actor.Stop(process.Normal)
    }

    SocketError(reason) -> {
      process.send(state.parent, PeerDisconnectedEvent(state.info.id, reason))
      actor.Stop(process.Normal)
    }

    GetInfo(reply_to) -> {
      process.send(reply_to, state.info)
      actor.continue(state)
    }

    Disconnect -> {
      tcp_close(state.socket)
      process.send(
        state.parent,
        PeerDisconnectedEvent(state.info.id, "Disconnected by request"),
      )
      actor.Stop(process.Normal)
    }
  }
}

/// Process received messages
fn process_messages(
  messages: List(Message),
  state: PeerActorState,
) -> PeerActorState {
  case messages {
    [] -> state
    [message, ..rest] -> {
      let new_state = process_single_message(message, state)
      process_messages(rest, new_state)
    }
  }
}

/// Process a single message
fn process_single_message(
  message: Message,
  state: PeerActorState,
) -> PeerActorState {
  case message {
    MsgVersion(version) -> {
      io.println(
        "[P2P] Peer "
        <> int.to_string(state.info.id)
        <> " version received: height="
        <> int.to_string(version.start_height)
        <> ", agent="
        <> version.user_agent,
      )
      // Send verack
      let _ = encode_and_send(state.socket, MsgVerack, state.config.network)
      io.println("[P2P] Sent verack to peer " <> int.to_string(state.info.id))

      // If we haven't sent our version yet (inbound), send it now
      case state.info.state {
        PeerConnecting -> {
          let our_version =
            oni_p2p.version_message(
              state.config.services,
              erlang_now_secs(),
              state.info.addr,
              generate_nonce(),
              state.config.best_height,
            )
          let _ =
            encode_and_send(state.socket, our_version, state.config.network)
          io.println(
            "[P2P] Sent our version to peer " <> int.to_string(state.info.id),
          )
          Nil
        }
        _ -> Nil
      }

      let new_info =
        PeerInfo(
          ..state.info,
          state: PeerAwaitingVerack,
          version: Some(version),
        )
      PeerActorState(..state, info: new_info)
    }

    MsgVerack -> {
      io.println(
        "[P2P] Peer "
        <> int.to_string(state.info.id)
        <> " verack received, handshake complete",
      )
      let new_info = PeerInfo(..state.info, state: PeerReady)
      case state.info.version {
        Some(version) -> {
          io.println(
            "[P2P] Sending PeerHandshakeComplete for peer "
            <> int.to_string(state.info.id)
            <> " at height "
            <> int.to_string(version.start_height),
          )
          process.send(
            state.parent,
            PeerHandshakeComplete(state.info.id, version),
          )
        }
        None -> {
          io.println(
            "[P2P] WARNING: No version stored for peer "
            <> int.to_string(state.info.id),
          )
        }
      }
      PeerActorState(..state, info: new_info)
    }

    MsgPing(nonce) -> {
      // Respond with pong
      let _ =
        encode_and_send(state.socket, MsgPong(nonce), state.config.network)
      state
    }

    MsgPong(_nonce) -> {
      // Calculate latency if we have a pending ping
      state
    }

    _ -> {
      // Forward other messages to parent
      process.send(state.parent, MessageReceived(state.info.id, message))
      state
    }
  }
}

// ============================================================================
// Message Encoding/Decoding
// ============================================================================

/// Encode and send a message
fn encode_and_send(
  socket: Socket,
  message: Message,
  network: oni_bitcoin.Network,
) -> Result(Int, String) {
  let encoded = oni_p2p.encode_message(message, network)
  case tcp_send(socket, encoded) {
    Ok(_) -> Ok(bit_array.byte_size(encoded))
    Error(reason) -> Error(reason)
  }
}

/// Try to parse messages from buffer
fn try_parse_messages(
  buffer: BitArray,
  network: oni_bitcoin.Network,
) -> Result(#(List(Message), BitArray), String) {
  try_parse_messages_acc(buffer, network, [])
}

fn try_parse_messages_acc(
  buffer: BitArray,
  network: oni_bitcoin.Network,
  acc: List(Message),
) -> Result(#(List(Message), BitArray), String) {
  // Need at least header (24 bytes)
  case bit_array.byte_size(buffer) < 24 {
    True -> Ok(#(list_reverse(acc), buffer))
    False -> {
      case oni_p2p.decode_message(buffer, network) {
        Error(e) -> {
          case e {
            // Both "Incomplete message" and "Insufficient payload" mean
            // we need more data - buffer and wait
            oni_p2p.InvalidMessage("Incomplete message")
            | oni_p2p.InvalidMessage("Insufficient payload") ->
              Ok(#(list_reverse(acc), buffer))
            _ -> Error(format_p2p_error(e))
          }
        }
        Ok(#(message, remaining)) -> {
          try_parse_messages_acc(remaining, network, [message, ..acc])
        }
      }
    }
  }
}

fn format_p2p_error(e: P2PError) -> String {
  case e {
    oni_p2p.InvalidMessage(msg) -> msg
    oni_p2p.InvalidChecksum -> "Invalid checksum"
    oni_p2p.MessageTooLarge -> "Message too large"
    oni_p2p.UnknownCommand(cmd) -> "Unknown command: " <> cmd
    _ -> "P2P error"
  }
}

// Reverse list helper
fn list_reverse(list: List(a)) -> List(a) {
  list_reverse_acc(list, [])
}

fn list_reverse_acc(list: List(a), acc: List(a)) -> List(a) {
  case list {
    [] -> acc
    [x, ..rest] -> list_reverse_acc(rest, [x, ..acc])
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start listening for connections
pub fn begin_listening(listener: Subject(ListenerMsg)) -> Nil {
  process.send(listener, StartListening)
}

/// Stop the listener
pub fn stop_listener(listener: Subject(ListenerMsg)) -> Nil {
  process.send(listener, StopListening)
}

/// Connect to a peer
pub fn connect(listener: Subject(ListenerMsg), addr: NetAddr) -> Nil {
  process.send(listener, ConnectTo(addr))
}

/// Get peer count
pub fn get_peer_count(listener: Subject(ListenerMsg), timeout: Int) -> Int {
  process.call(listener, GetPeerCount, timeout)
}

/// Broadcast message to all peers
pub fn broadcast(listener: Subject(ListenerMsg), message: Message) -> Nil {
  process.send(listener, BroadcastMessage(message))
}

/// Send message to a specific peer
pub fn send_to_peer(
  listener: Subject(ListenerMsg),
  peer_id: Int,
  message: Message,
) -> Nil {
  process.send(listener, SendToPeer(peer_id, message))
}

/// Get list of connected peer IDs
pub fn get_peer_ids(listener: Subject(ListenerMsg), timeout: Int) -> List(Int) {
  process.call(listener, GetPeerIds, timeout)
}

// ============================================================================
// TCP FFI
// ============================================================================

@external(erlang, "p2p_network_ffi", "tcp_listen")
fn tcp_listen(port: Int, bind_address: String) -> Result(ListenSocket, String)

@external(erlang, "p2p_network_ffi", "tcp_connect")
pub fn tcp_connect(
  ip: oni_p2p.IpAddr,
  port: Int,
  timeout: Int,
) -> Result(Socket, String)

@external(erlang, "p2p_network_ffi", "tcp_send")
fn tcp_send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "p2p_network_ffi", "tcp_close")
fn tcp_close(socket: Socket) -> Nil

@external(erlang, "p2p_network_ffi", "tcp_close_listen")
fn tcp_close_listen(socket: ListenSocket) -> Nil

@external(erlang, "p2p_network_ffi", "socket_peer_addr")
fn socket_peer_addr(socket: Socket) -> NetAddr

@external(erlang, "p2p_network_ffi", "spawn_acceptor")
fn spawn_acceptor(
  listen_socket: ListenSocket,
  parent: Subject(ListenerMsg),
) -> Nil

@external(erlang, "p2p_network_ffi", "spawn_connector")
fn spawn_connector(
  addr: NetAddr,
  timeout: Int,
  parent: Subject(ListenerMsg),
) -> Nil

@external(erlang, "p2p_network_ffi", "spawn_receiver")
pub fn spawn_receiver(socket: Socket, parent: Subject(PeerMsg)) -> Nil

@external(erlang, "p2p_network_ffi", "transfer_socket_ownership")
fn transfer_socket_ownership(
  socket: Socket,
  owner: Subject(PeerMsg),
) -> Result(Nil, String)

@external(erlang, "p2p_network_ffi", "erlang_now_ms")
fn erlang_now_ms() -> Int

@external(erlang, "p2p_network_ffi", "erlang_now_secs")
fn erlang_now_secs() -> Int

@external(erlang, "p2p_network_ffi", "generate_nonce")
fn generate_nonce() -> Int
