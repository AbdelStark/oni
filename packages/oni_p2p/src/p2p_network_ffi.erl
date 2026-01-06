%% p2p_network_ffi.erl - Erlang FFI helpers for P2P networking
%%
%% This module provides TCP networking functions for the P2P layer.

-module(p2p_network_ffi).
-export([
    tcp_listen/2,
    tcp_connect/3,
    tcp_send/2,
    tcp_close/1,
    tcp_close_listen/1,
    socket_peer_addr/1,
    spawn_acceptor/2,
    spawn_connector/3,
    spawn_receiver/2,
    erlang_now_ms/0,
    erlang_now_secs/0,
    generate_nonce/0,
    dns_lookup/2
]).

%% Listen on a port
-spec tcp_listen(integer(), binary()) -> {ok, port()} | {error, binary()}.
tcp_listen(Port, BindAddress) ->
    Options = [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 128}
    ] ++ parse_bind_address(BindAddress),

    case gen_tcp:listen(Port, Options) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_error(Reason)}
    end.

%% Connect to a peer
-spec tcp_connect(tuple(), integer(), integer()) -> {ok, port()} | {error, binary()}.
tcp_connect(IpAddr, Port, Timeout) ->
    Address = ip_to_erlang(IpAddr),
    Options = [
        binary,
        {packet, raw},
        {active, false},
        {nodelay, true}
    ],

    case gen_tcp:connect(Address, Port, Options, Timeout) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_error(Reason)}
    end.

%% Send data on a socket
-spec tcp_send(port(), binary()) -> {ok, nil} | {error, binary()}.
tcp_send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_error(Reason)}
    end.

%% Close a socket
-spec tcp_close(port()) -> nil.
tcp_close(Socket) ->
    gen_tcp:close(Socket),
    nil.

%% Close a listen socket
-spec tcp_close_listen(port()) -> nil.
tcp_close_listen(Socket) ->
    gen_tcp:close(Socket),
    nil.

%% Get peer address from socket
-spec socket_peer_addr(port()) -> tuple().
socket_peer_addr(Socket) ->
    case inet:peername(Socket) of
        {ok, {Address, Port}} ->
            IpAddr = erlang_ip_to_gleam(Address),
            Services = {service_flags, 0},
            {net_addr, Services, IpAddr, Port};
        {error, _} ->
            %% Return localhost as fallback
            Services = {service_flags, 0},
            IpAddr = {i_pv4, 127, 0, 0, 1},
            {net_addr, Services, IpAddr, 0}
    end.

%% Spawn an acceptor process
-spec spawn_acceptor(port(), term()) -> nil.
spawn_acceptor(ListenSocket, Parent) ->
    spawn_link(fun() ->
        case gen_tcp:accept(ListenSocket) of
            {ok, Socket} ->
                %% Send InboundConnection message to parent
                gleam@erlang@process:send(Parent, {inbound_connection, Socket});
            {error, _Reason} ->
                ok
        end
    end),
    nil.

%% Spawn a connector process
-spec spawn_connector(tuple(), integer(), term()) -> nil.
spawn_connector(NetAddr, Timeout, Parent) ->
    {net_addr, _Services, IpAddr, Port} = NetAddr,
    spawn_link(fun() ->
        case tcp_connect(IpAddr, Port, Timeout) of
            {ok, Socket} ->
                gleam@erlang@process:send(Parent, {outbound_connected, NetAddr, Socket});
            {error, Reason} ->
                gleam@erlang@process:send(Parent, {connection_failed, NetAddr, Reason})
        end
    end),
    nil.

%% Spawn a receiver process for a peer
-spec spawn_receiver(port(), term()) -> nil.
spawn_receiver(Socket, Parent) ->
    spawn_link(fun() -> receiver_loop(Socket, Parent) end),
    nil.

receiver_loop(Socket, Parent) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            gleam@erlang@process:send(Parent, {received_data, Data}),
            receiver_loop(Socket, Parent);
        {error, closed} ->
            gleam@erlang@process:send(Parent, socket_closed);
        {error, Reason} ->
            gleam@erlang@process:send(Parent, {socket_error, format_error(Reason)})
    end.

%% Get current time in milliseconds
-spec erlang_now_ms() -> integer().
erlang_now_ms() ->
    erlang:system_time(millisecond).

%% Get current time in seconds
-spec erlang_now_secs() -> integer().
erlang_now_secs() ->
    erlang:system_time(second).

%% Generate a random nonce
-spec generate_nonce() -> integer().
generate_nonce() ->
    rand:uniform(16#FFFFFFFFFFFFFFFF).

%% Helper functions

parse_bind_address(Address) when is_binary(Address) ->
    parse_bind_address(binary_to_list(Address));
parse_bind_address(Address) when is_list(Address) ->
    case inet:parse_address(Address) of
        {ok, Ip} -> [{ip, Ip}];
        {error, _} -> []
    end.

ip_to_erlang({i_pv4, A, B, C, D}) ->
    {A, B, C, D};
ip_to_erlang({i_pv6, Bytes}) when is_binary(Bytes) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>> = Bytes,
    {A, B, C, D, E, F, G, H}.

erlang_ip_to_gleam({A, B, C, D}) when is_integer(A), is_integer(B), is_integer(C), is_integer(D) ->
    {i_pv4, A, B, C, D};
erlang_ip_to_gleam({A, B, C, D, E, F, G, H}) ->
    Bytes = <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>,
    {i_pv6, Bytes}.

format_error(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
format_error(Reason) when is_binary(Reason) ->
    Reason;
format_error(Reason) when is_list(Reason) ->
    list_to_binary(Reason);
format_error(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).

%% DNS lookup for seed discovery
%% Returns a list of {ok, [{ip, port, seed}]} or {error, reason}
-spec dns_lookup(binary(), integer()) -> {ok, list()} | {error, binary()}.
dns_lookup(Hostname, Port) when is_binary(Hostname) ->
    dns_lookup(binary_to_list(Hostname), Port);
dns_lookup(Hostname, Port) when is_list(Hostname) ->
    case inet:gethostbyname(Hostname) of
        {ok, {hostent, _Name, _Aliases, _AddrType, _Length, Addresses}} ->
            Results = lists:map(fun(Addr) ->
                IpStr = inet:ntoa(Addr),
                {dns_address, list_to_binary(IpStr), Port, list_to_binary(Hostname)}
            end, Addresses),
            {dns_ok, Results};
        {error, nxdomain} ->
            {dns_error, <<"Domain not found">>};
        {error, timeout} ->
            dns_timeout;
        {error, Reason} ->
            {dns_error, format_error(Reason)}
    end.
