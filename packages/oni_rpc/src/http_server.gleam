// http_server.gleam - TCP-based HTTP server for RPC
//
// This module provides a production-ready HTTP server for the RPC interface:
// - TCP listener using Erlang's gen_tcp
// - Connection handling with OTP actors
// - Graceful shutdown support
// - Connection pooling and limits
//
// Usage:
//   1. Create server with start(config, rpc_server)
//   2. Send StartAccepting message to begin
//   3. Send Stop message to shutdown

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import oni_rpc
import rpc_http.{
  type ConnectionState, type RpcHandlerConfig,
  connection_new, connection_receive, connection_sent, connection_try_parse,
  handle_rpc_request, serialize_response,
}

// ============================================================================
// Server Configuration
// ============================================================================

/// HTTP server configuration
pub type HttpServerConfig {
  HttpServerConfig(
    /// Port to listen on
    port: Int,
    /// Bind address (e.g., "127.0.0.1" or "0.0.0.0")
    bind_address: String,
    /// Maximum concurrent connections
    max_connections: Int,
    /// Connection timeout in milliseconds
    connection_timeout_ms: Int,
    /// Request timeout in milliseconds
    request_timeout_ms: Int,
    /// RPC handler configuration
    rpc_config: RpcHandlerConfig,
  )
}

/// Default server configuration
pub fn default_config() -> HttpServerConfig {
  HttpServerConfig(
    port: 8332,
    bind_address: "127.0.0.1",
    max_connections: 100,
    connection_timeout_ms: 30_000,
    request_timeout_ms: 60_000,
    rpc_config: rpc_http.default_handler_config(),
  )
}

// ============================================================================
// Server State and Messages
// ============================================================================

/// Server state
pub type ServerState {
  ServerState(
    config: HttpServerConfig,
    rpc_server: oni_rpc.RpcServer,
    listen_socket: Option(ListenSocket),
    connections: Dict(Int, ConnectionInfo),
    next_conn_id: Int,
    stats: ServerStats,
    is_running: Bool,
    /// Self subject for spawned processes to send messages back
    self_subject: Option(Subject(ServerMsg)),
  )
}

/// Connection info
pub type ConnectionInfo {
  ConnectionInfo(
    id: Int,
    socket: Socket,
    state: ConnectionState,
    created_at: Int,
  )
}

/// Server statistics
pub type ServerStats {
  ServerStats(
    total_connections: Int,
    active_connections: Int,
    total_requests: Int,
    total_errors: Int,
    bytes_received: Int,
    bytes_sent: Int,
  )
}

/// Opaque type for listen socket
pub type ListenSocket

/// Opaque type for client socket
pub type Socket

/// Server messages
pub type ServerMsg {
  /// Initialize with self subject
  Init(self_subject: Subject(ServerMsg))
  /// Start accepting connections
  StartAccepting
  /// Stop the server
  Stop
  /// New connection accepted
  ConnectionAccepted(socket: Socket)
  /// Data received on connection
  DataReceived(conn_id: Int, data: BitArray)
  /// Connection closed
  ConnectionClosed(conn_id: Int)
  /// Connection error
  ConnectionError(conn_id: Int, reason: String)
  /// Get server status
  GetStatus(reply_to: Subject(ServerStats))
}

// ============================================================================
// Server Actor
// ============================================================================

/// Start the HTTP server
pub fn start(
  config: HttpServerConfig,
  rpc_server: oni_rpc.RpcServer,
) -> Result(Subject(ServerMsg), actor.StartError) {
  let initial_state = ServerState(
    config: config,
    rpc_server: rpc_server,
    listen_socket: None,
    connections: dict.new(),
    next_conn_id: 1,
    stats: ServerStats(
      total_connections: 0,
      active_connections: 0,
      total_requests: 0,
      total_errors: 0,
      bytes_received: 0,
      bytes_sent: 0,
    ),
    is_running: False,
    self_subject: None,
  )

  case actor.start(initial_state, handle_message) {
    Ok(subject) -> {
      // Send Init message so the actor knows its own Subject
      process.send(subject, Init(subject))
      Ok(subject)
    }
    Error(e) -> Error(e)
  }
}

/// Handle server messages
fn handle_message(
  msg: ServerMsg,
  state: ServerState,
) -> actor.Next(ServerMsg, ServerState) {
  case msg {
    Init(self_subject) -> {
      actor.continue(ServerState(..state, self_subject: Some(self_subject)))
    }

    StartAccepting -> {
      case state.self_subject {
        None -> {
          io.println("[HTTP] Error: Server not initialized")
          actor.continue(state)
        }
        Some(self) -> {
          case start_listening(state.config) {
            Error(reason) -> {
              io.println("[HTTP] Failed to start listener: " <> reason)
              actor.continue(state)
            }
            Ok(listen_socket) -> {
              io.println("[HTTP] Server listening on " <>
                state.config.bind_address <> ":" <>
                int.to_string(state.config.port))

              // Start accept loop in background
              spawn_acceptor(listen_socket, self)

              actor.continue(ServerState(
                ..state,
                listen_socket: Some(listen_socket),
                is_running: True,
              ))
            }
          }
        }
      }
    }

    Stop -> {
      io.println("[HTTP] Server stopping...")
      case state.listen_socket {
        Some(socket) -> close_listen_socket(socket)
        None -> Nil
      }
      // Close all connections
      close_all_connections(state.connections)
      actor.Stop(process.Normal)
    }

    ConnectionAccepted(socket) -> {
      case state.self_subject {
        None -> {
          close_socket(socket)
          actor.continue(state)
        }
        Some(self) -> {
          case dict.size(state.connections) >= state.config.max_connections {
            True -> {
              // Reject connection - too many
              close_socket(socket)
              actor.continue(state)
            }
            False -> {
              let conn_id = state.next_conn_id
              let conn_info = ConnectionInfo(
                id: conn_id,
                socket: socket,
                state: connection_new(),
                created_at: erlang_now_ms(),
              )

              // Start receiving data from this connection
              spawn_receiver(conn_id, socket, self)

              // Continue accepting
              case state.listen_socket {
                Some(ls) -> spawn_acceptor(ls, self)
                None -> Nil
              }

              let new_stats = ServerStats(
                ..state.stats,
                total_connections: state.stats.total_connections + 1,
                active_connections: state.stats.active_connections + 1,
              )

              actor.continue(ServerState(
                ..state,
                connections: dict.insert(state.connections, conn_id, conn_info),
                next_conn_id: conn_id + 1,
                stats: new_stats,
              ))
            }
          }
        }
      }
    }

    DataReceived(conn_id, data) -> {
      case state.self_subject {
        None -> actor.continue(state)
        Some(self) -> {
          case dict.get(state.connections, conn_id) {
            Error(_) -> actor.continue(state)
            Ok(conn) -> {
              // Add data to connection buffer
              let updated_conn_state = connection_receive(conn.state, data)

              // Try to parse a complete request
              let #(final_conn_state, maybe_request) =
                connection_try_parse(updated_conn_state)

              let #(new_rpc_server, response_opt) = case maybe_request {
                None -> #(state.rpc_server, None)
                Some(Error(_err)) -> {
                  let resp = rpc_http.error_response(rpc_http.HttpBadRequest("Parse error"))
                  #(state.rpc_server, Some(resp))
                }
                Some(Ok(request)) -> {
                  let #(new_server, resp) =
                    handle_rpc_request(request, state.config.rpc_config, state.rpc_server)
                  #(new_server, Some(resp))
                }
              }

              // Send response if we have one
              let bytes_sent = case response_opt {
                None -> 0
                Some(resp) -> {
                  let response_bytes = serialize_response(resp)
                  let _ = socket_send(conn.socket, response_bytes)
                  bit_array.byte_size(response_bytes)
                }
              }

              // Update connection state
              let updated_conn = ConnectionInfo(
                ..conn,
                state: connection_sent(final_conn_state, bytes_sent),
              )

              // Update stats
              let new_stats = ServerStats(
                ..state.stats,
                total_requests: state.stats.total_requests + case response_opt {
                  Some(_) -> 1
                  None -> 0
                },
                bytes_received: state.stats.bytes_received + bit_array.byte_size(data),
                bytes_sent: state.stats.bytes_sent + bytes_sent,
              )

              // Continue receiving on this connection
              spawn_receiver(conn_id, conn.socket, self)

              actor.continue(ServerState(
                ..state,
                rpc_server: new_rpc_server,
                connections: dict.insert(state.connections, conn_id, updated_conn),
                stats: new_stats,
              ))
            }
          }
        }
      }
    }

    ConnectionClosed(conn_id) -> {
      case dict.get(state.connections, conn_id) {
        Error(_) -> actor.continue(state)
        Ok(conn) -> {
          close_socket(conn.socket)
          let new_stats = ServerStats(
            ..state.stats,
            active_connections: int.max(0, state.stats.active_connections - 1),
          )
          actor.continue(ServerState(
            ..state,
            connections: dict.delete(state.connections, conn_id),
            stats: new_stats,
          ))
        }
      }
    }

    ConnectionError(conn_id, _reason) -> {
      case dict.get(state.connections, conn_id) {
        Error(_) -> actor.continue(state)
        Ok(conn) -> {
          close_socket(conn.socket)
          let new_stats = ServerStats(
            ..state.stats,
            active_connections: int.max(0, state.stats.active_connections - 1),
            total_errors: state.stats.total_errors + 1,
          )
          actor.continue(ServerState(
            ..state,
            connections: dict.delete(state.connections, conn_id),
            stats: new_stats,
          ))
        }
      }
    }

    GetStatus(reply_to) -> {
      process.send(reply_to, state.stats)
      actor.continue(state)
    }
  }
}

/// Close all connections
fn close_all_connections(connections: Dict(Int, ConnectionInfo)) -> Nil {
  dict.fold(connections, Nil, fn(_acc, _id, conn) {
    close_socket(conn.socket)
  })
}

// ============================================================================
// Public API
// ============================================================================

/// Start the server listening for connections
pub fn begin_accepting(server: Subject(ServerMsg)) -> Nil {
  process.send(server, StartAccepting)
}

/// Stop the server
pub fn stop(server: Subject(ServerMsg)) -> Nil {
  process.send(server, Stop)
}

/// Get server statistics
pub fn get_stats(server: Subject(ServerMsg), timeout: Int) -> ServerStats {
  process.call(server, GetStatus, timeout)
}

// ============================================================================
// Erlang FFI for TCP Operations
// ============================================================================

/// Start listening on a port
fn start_listening(config: HttpServerConfig) -> Result(ListenSocket, String) {
  let port = config.port
  let options = tcp_listen_options(config.bind_address)

  case gen_tcp_listen(port, options) {
    Ok(socket) -> Ok(socket)
    Error(reason) -> Error(format_error(reason))
  }
}

/// Spawn a process to accept connections
fn spawn_acceptor(listen_socket: ListenSocket, parent: Subject(ServerMsg)) -> Nil {
  // Spawn a linked process to accept
  let _ = process.start(fn() {
    case gen_tcp_accept(listen_socket) {
      Ok(socket) -> {
        process.send(parent, ConnectionAccepted(socket))
      }
      Error(_) -> Nil
    }
  }, True)
  Nil
}

/// Spawn a process to receive data from a connection
fn spawn_receiver(conn_id: Int, socket: Socket, parent: Subject(ServerMsg)) -> Nil {
  let _ = process.start(fn() {
    case gen_tcp_recv(socket, 0) {
      Ok(data) -> {
        process.send(parent, DataReceived(conn_id, data))
      }
      Error(closed) if closed == "closed" -> {
        process.send(parent, ConnectionClosed(conn_id))
      }
      Error(reason) -> {
        process.send(parent, ConnectionError(conn_id, reason))
      }
    }
  }, True)
  Nil
}

/// Close a client socket
fn close_socket(socket: Socket) -> Nil {
  gen_tcp_close(socket)
}

/// Close the listen socket
fn close_listen_socket(socket: ListenSocket) -> Nil {
  gen_tcp_close_listen(socket)
}

/// Send data on a socket
fn socket_send(socket: Socket, data: BitArray) -> Result(Nil, String) {
  case gen_tcp_send(socket, data) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(format_error(reason))
  }
}

/// Format Erlang error term
fn format_error(reason: Dynamic) -> String {
  erlang_format_error(reason)
}

// External Erlang functions
type Dynamic

@external(erlang, "gen_tcp", "listen")
fn gen_tcp_listen_raw(port: Int, options: List(Dynamic)) -> Dynamic

fn gen_tcp_listen(port: Int, options: List(Dynamic)) -> Result(ListenSocket, Dynamic) {
  let result = gen_tcp_listen_raw(port, options)
  decode_listen_result(result)
}

@external(erlang, "gen_tcp", "accept")
fn gen_tcp_accept_raw(socket: ListenSocket) -> Dynamic

fn gen_tcp_accept(socket: ListenSocket) -> Result(Socket, Dynamic) {
  let result = gen_tcp_accept_raw(socket)
  decode_accept_result(result)
}

@external(erlang, "gen_tcp", "recv")
fn gen_tcp_recv_raw(socket: Socket, length: Int) -> Dynamic

fn gen_tcp_recv(socket: Socket, length: Int) -> Result(BitArray, String) {
  let result = gen_tcp_recv_raw(socket, length)
  decode_recv_result(result)
}

@external(erlang, "gen_tcp", "send")
fn gen_tcp_send_raw(socket: Socket, data: BitArray) -> Dynamic

fn gen_tcp_send(socket: Socket, data: BitArray) -> Result(Nil, Dynamic) {
  let result = gen_tcp_send_raw(socket, data)
  decode_send_result(result)
}

@external(erlang, "gen_tcp", "close")
fn gen_tcp_close(socket: Socket) -> Nil

@external(erlang, "gen_tcp", "close")
fn gen_tcp_close_listen(socket: ListenSocket) -> Nil

// Helpers for Erlang interop
@external(erlang, "http_server_ffi", "tcp_listen_options")
fn tcp_listen_options(bind_address: String) -> List(Dynamic)

@external(erlang, "http_server_ffi", "decode_listen_result")
fn decode_listen_result(result: Dynamic) -> Result(ListenSocket, Dynamic)

@external(erlang, "http_server_ffi", "decode_accept_result")
fn decode_accept_result(result: Dynamic) -> Result(Socket, Dynamic)

@external(erlang, "http_server_ffi", "decode_recv_result")
fn decode_recv_result(result: Dynamic) -> Result(BitArray, String)

@external(erlang, "http_server_ffi", "decode_send_result")
fn decode_send_result(result: Dynamic) -> Result(Nil, Dynamic)

@external(erlang, "http_server_ffi", "format_error")
fn erlang_format_error(reason: Dynamic) -> String

@external(erlang, "http_server_ffi", "now_ms")
fn erlang_now_ms() -> Int
