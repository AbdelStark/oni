%% http_server_ffi.erl - Erlang FFI helpers for HTTP server
%%
%% This module provides helper functions for interoperating with
%% Erlang's gen_tcp from Gleam code.

-module(http_server_ffi).
-export([
    tcp_listen_options/1,
    decode_listen_result/1,
    decode_accept_result/1,
    decode_recv_result/1,
    decode_send_result/1,
    format_error/1,
    now_ms/0
]).

%% Build TCP listen options from bind address
-spec tcp_listen_options(binary()) -> list().
tcp_listen_options(BindAddress) ->
    BaseOptions = [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 128}
    ],
    case parse_ip_address(BindAddress) of
        {ok, Ip} -> [{ip, Ip} | BaseOptions];
        error -> BaseOptions
    end.

%% Parse IP address from string/binary
-spec parse_ip_address(binary()) -> {ok, inet:ip_address()} | error.
parse_ip_address(Address) when is_binary(Address) ->
    parse_ip_address(binary_to_list(Address));
parse_ip_address(Address) when is_list(Address) ->
    case inet:parse_address(Address) of
        {ok, Ip} -> {ok, Ip};
        {error, _} -> error
    end.

%% Decode gen_tcp:listen result to Gleam Result
-spec decode_listen_result(term()) -> {ok, port()} | {error, term()}.
decode_listen_result({ok, Socket}) ->
    {ok, Socket};
decode_listen_result({error, Reason}) ->
    {error, Reason}.

%% Decode gen_tcp:accept result to Gleam Result
-spec decode_accept_result(term()) -> {ok, port()} | {error, term()}.
decode_accept_result({ok, Socket}) ->
    {ok, Socket};
decode_accept_result({error, Reason}) ->
    {error, Reason}.

%% Decode gen_tcp:recv result to Gleam Result
-spec decode_recv_result(term()) -> {ok, binary()} | {error, binary()}.
decode_recv_result({ok, Data}) ->
    {ok, Data};
decode_recv_result({error, closed}) ->
    {error, <<"closed">>};
decode_recv_result({error, timeout}) ->
    {error, <<"timeout">>};
decode_recv_result({error, Reason}) ->
    {error, format_error(Reason)}.

%% Decode gen_tcp:send result to Gleam Result
-spec decode_send_result(term()) -> {ok, nil} | {error, term()}.
decode_send_result(ok) ->
    {ok, nil};
decode_send_result({error, Reason}) ->
    {error, Reason}.

%% Format an Erlang error term to a string
-spec format_error(term()) -> binary().
format_error(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
format_error(Reason) when is_binary(Reason) ->
    Reason;
format_error(Reason) when is_list(Reason) ->
    list_to_binary(Reason);
format_error(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).

%% Get current time in milliseconds
-spec now_ms() -> integer().
now_ms() ->
    erlang:system_time(millisecond).
