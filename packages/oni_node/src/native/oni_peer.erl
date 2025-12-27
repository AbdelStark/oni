%%% oni_peer - Individual peer connection handler
%%%
%%% Manages a single TCP connection to a Bitcoin peer:
%%% - TCP socket handling
%%% - Message framing (header + payload)
%%% - Version handshake
%%% - Ping/pong keepalive
%%% - Message dispatch to appropriate handlers

-module(oni_peer).
-behaviour(gen_statem).

-export([start_link/2]).
-export([send_message/2, disconnect/1, get_info/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3]).
-export([connecting/3, handshaking/3, ready/3]).

-define(CONNECT_TIMEOUT, 30000).
-define(HANDSHAKE_TIMEOUT, 60000).
-define(PING_INTERVAL, 120000).
-define(MESSAGE_HEADER_SIZE, 24).

%% Network magic bytes
-define(MAINNET_MAGIC, <<16#F9, 16#BE, 16#B4, 16#D9>>).
-define(TESTNET_MAGIC, <<16#0B, 16#11, 16#09, 16#07>>).
-define(REGTEST_MAGIC, <<16#FA, 16#BF, 16#B5, 16#DA>>).

-record(data, {
    socket :: gen_tcp:socket() | undefined,
    ip :: inet:ip_address(),
    port :: inet:port_number(),
    network :: atom(),
    magic :: binary(),
    buffer :: binary(),
    version :: non_neg_integer() | undefined,
    user_agent :: binary() | undefined,
    services :: non_neg_integer(),
    start_height :: non_neg_integer() | undefined,
    ping_nonce :: non_neg_integer() | undefined,
    last_recv :: non_neg_integer(),
    last_send :: non_neg_integer(),
    bytes_recv :: non_neg_integer(),
    bytes_sent :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(IpAddr, Port) ->
    gen_statem:start_link(?MODULE, {IpAddr, Port}, []).

%% Send a message to the peer
-spec send_message(pid(), tuple()) -> ok | {error, term()}.
send_message(Pid, Message) ->
    gen_statem:call(Pid, {send, Message}).

%% Request disconnect
-spec disconnect(pid()) -> ok.
disconnect(Pid) ->
    gen_statem:cast(Pid, disconnect).

%% Get peer information
-spec get_info(pid()) -> map().
get_info(Pid) ->
    gen_statem:call(Pid, get_info).

%% ============================================================================
%% gen_statem callbacks
%% ============================================================================

callback_mode() -> state_functions.

init({IpAddr, Port}) ->
    %% Determine network from port (simplified)
    {Network, Magic} = case Port of
        8333 -> {mainnet, ?MAINNET_MAGIC};
        18333 -> {testnet, ?TESTNET_MAGIC};
        18444 -> {regtest, ?REGTEST_MAGIC};
        _ -> {mainnet, ?MAINNET_MAGIC}
    end,

    Data = #data{
        ip = IpAddr,
        port = Port,
        network = Network,
        magic = Magic,
        buffer = <<>>,
        services = 1,  % NODE_NETWORK
        last_recv = erlang:system_time(second),
        last_send = erlang:system_time(second),
        bytes_recv = 0,
        bytes_sent = 0
    },

    %% Start connecting
    {ok, connecting, Data, [{state_timeout, 0, connect}]}.

%% ============================================================================
%% State: connecting
%% ============================================================================

connecting(state_timeout, connect, Data) ->
    IpTuple = ip_to_tuple(Data#data.ip),
    io:format("[oni_peer] Connecting to ~p:~p~n", [IpTuple, Data#data.port]),

    case gen_tcp:connect(IpTuple, Data#data.port, [
        binary,
        {packet, raw},
        {active, once},
        {nodelay, true},
        {send_timeout, 30000}
    ], ?CONNECT_TIMEOUT) of
        {ok, Socket} ->
            io:format("[oni_peer] Connected to ~p:~p~n", [IpTuple, Data#data.port]),
            NewData = Data#data{socket = Socket},
            %% Send version message
            VersionMsg = make_version_message(Data),
            ok = send_raw(Socket, Data#data.magic, VersionMsg),
            {next_state, handshaking, NewData, [{state_timeout, ?HANDSHAKE_TIMEOUT, timeout}]};
        {error, Reason} ->
            io:format("[oni_peer] Connection failed to ~p:~p: ~p~n",
                      [IpTuple, Data#data.port, Reason]),
            {stop, {connection_failed, Reason}}
    end;

connecting({call, From}, _, Data) ->
    {keep_state, Data, [{reply, From, {error, not_connected}}]}.

%% ============================================================================
%% State: handshaking
%% ============================================================================

handshaking(state_timeout, timeout, _Data) ->
    {stop, handshake_timeout};

handshaking(info, {tcp, Socket, Bytes}, Data = #data{socket = Socket}) ->
    inet:setopts(Socket, [{active, once}]),
    NewBuffer = <<(Data#data.buffer)/binary, Bytes/binary>>,
    NewData = Data#data{
        buffer = NewBuffer,
        bytes_recv = Data#data.bytes_recv + byte_size(Bytes),
        last_recv = erlang:system_time(second)
    },
    handle_buffer(handshaking, NewData);

handshaking(info, {tcp_closed, _}, _Data) ->
    {stop, connection_closed};

handshaking(info, {tcp_error, _, Reason}, _Data) ->
    {stop, {tcp_error, Reason}};

handshaking({call, From}, get_info, Data) ->
    {keep_state, Data, [{reply, From, peer_info(Data)}]};

handshaking({call, From}, _, Data) ->
    {keep_state, Data, [{reply, From, {error, handshaking}}]}.

%% ============================================================================
%% State: ready
%% ============================================================================

ready(info, {tcp, Socket, Bytes}, Data = #data{socket = Socket}) ->
    inet:setopts(Socket, [{active, once}]),
    NewBuffer = <<(Data#data.buffer)/binary, Bytes/binary>>,
    NewData = Data#data{
        buffer = NewBuffer,
        bytes_recv = Data#data.bytes_recv + byte_size(Bytes),
        last_recv = erlang:system_time(second)
    },
    handle_buffer(ready, NewData);

ready(info, {tcp_closed, _}, _Data) ->
    {stop, connection_closed};

ready(info, {tcp_error, _, Reason}, _Data) ->
    {stop, {tcp_error, Reason}};

ready(info, send_ping, Data) ->
    Nonce = rand:uniform(16#FFFFFFFFFFFFFFFF),
    PingMsg = {ping, Nonce},
    ok = send_raw(Data#data.socket, Data#data.magic, encode_message(PingMsg)),
    NewData = Data#data{ping_nonce = Nonce},
    {keep_state, NewData, [{state_timeout, ?PING_INTERVAL, send_ping}]};

ready(state_timeout, send_ping, Data) ->
    {keep_state, Data, [{next_event, info, send_ping}]};

ready({call, From}, {send, Message}, Data) ->
    Encoded = encode_message(Message),
    case send_raw(Data#data.socket, Data#data.magic, Encoded) of
        ok ->
            NewData = Data#data{
                bytes_sent = Data#data.bytes_sent + byte_size(Encoded),
                last_send = erlang:system_time(second)
            },
            {keep_state, NewData, [{reply, From, ok}]};
        Error ->
            {keep_state, Data, [{reply, From, Error}]}
    end;

ready({call, From}, get_info, Data) ->
    {keep_state, Data, [{reply, From, peer_info(Data)}]};

ready(cast, disconnect, _Data) ->
    {stop, disconnect_requested}.

%% ============================================================================
%% Terminate
%% ============================================================================

terminate(Reason, _State, Data) ->
    io:format("[oni_peer] Terminating ~p:~p - ~p~n",
              [Data#data.ip, Data#data.port, Reason]),
    case Data#data.socket of
        undefined -> ok;
        Socket -> gen_tcp:close(Socket)
    end,
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

handle_buffer(State, Data) ->
    case parse_message(Data#data.buffer, Data#data.magic) of
        {ok, Command, Payload, Rest} ->
            NewData = Data#data{buffer = Rest},
            handle_message(State, Command, Payload, NewData);
        {incomplete, _} ->
            {keep_state, Data};
        {error, Reason} ->
            io:format("[oni_peer] Parse error: ~p~n", [Reason]),
            {stop, {parse_error, Reason}}
    end.

handle_message(handshaking, <<"version", _/binary>>, Payload, Data) ->
    case parse_version(Payload) of
        {ok, Version, UserAgent, Services, StartHeight} ->
            io:format("[oni_peer] Received version: ~p from ~s~n", [Version, UserAgent]),
            NewData = Data#data{
                version = Version,
                user_agent = UserAgent,
                services = Services,
                start_height = StartHeight
            },
            %% Send verack
            ok = send_raw(Data#data.socket, Data#data.magic, encode_message(verack)),
            handle_buffer(handshaking, NewData);
        {error, Reason} ->
            {stop, {version_parse_error, Reason}}
    end;

handle_message(handshaking, <<"verack", _/binary>>, _Payload, Data) ->
    io:format("[oni_peer] Handshake complete with ~p:~p~n", [Data#data.ip, Data#data.port]),
    %% Notify peer manager
    oni_peer_manager:peer_ready(self(), Data#data.version, Data#data.services),
    %% Start ping timer
    {next_state, ready, Data, [{state_timeout, ?PING_INTERVAL, send_ping}]};

handle_message(handshaking, Command, _Payload, Data) ->
    io:format("[oni_peer] Unexpected message during handshake: ~s~n", [Command]),
    handle_buffer(handshaking, Data);

handle_message(ready, <<"ping", _/binary>>, Payload, Data) ->
    case Payload of
        <<Nonce:64/little>> ->
            ok = send_raw(Data#data.socket, Data#data.magic, encode_message({pong, Nonce}));
        _ ->
            ok
    end,
    handle_buffer(ready, Data);

handle_message(ready, <<"pong", _/binary>>, Payload, Data) ->
    case Payload of
        <<Nonce:64/little>> when Nonce =:= Data#data.ping_nonce ->
            ok;
        _ ->
            ok
    end,
    handle_buffer(ready, Data#data{ping_nonce = undefined});

handle_message(ready, <<"inv", _/binary>>, Payload, Data) ->
    %% Forward to peer manager for processing
    oni_peer_manager:handle_inv(self(), Payload),
    handle_buffer(ready, Data);

handle_message(ready, <<"headers", _/binary>>, Payload, Data) ->
    oni_peer_manager:handle_headers(self(), Payload),
    handle_buffer(ready, Data);

handle_message(ready, <<"block", _/binary>>, Payload, Data) ->
    oni_peer_manager:handle_block(self(), Payload),
    handle_buffer(ready, Data);

handle_message(ready, <<"tx", _/binary>>, Payload, Data) ->
    oni_peer_manager:handle_tx(self(), Payload),
    handle_buffer(ready, Data);

handle_message(ready, <<"addr", _/binary>>, Payload, Data) ->
    oni_addr_manager:handle_addr(Payload),
    handle_buffer(ready, Data);

handle_message(ready, <<"sendheaders", _/binary>>, _Payload, Data) ->
    %% Peer wants us to send headers instead of inv for new blocks
    handle_buffer(ready, Data);

handle_message(ready, <<"sendcmpct", _/binary>>, _Payload, Data) ->
    %% BIP152 compact blocks negotiation
    handle_buffer(ready, Data);

handle_message(ready, <<"feefilter", _/binary>>, _Payload, Data) ->
    %% Minimum fee rate filter
    handle_buffer(ready, Data);

handle_message(ready, Command, _Payload, Data) ->
    %% Unknown or unhandled message
    io:format("[oni_peer] Unhandled message: ~s~n", [trim_null(Command)]),
    handle_buffer(ready, Data).

%% Parse a complete message from buffer
parse_message(Buffer, Magic) when byte_size(Buffer) < ?MESSAGE_HEADER_SIZE ->
    {incomplete, Buffer};
parse_message(Buffer, Magic) ->
    case Buffer of
        <<Magic:4/binary, Command:12/binary, Length:32/little,
          Checksum:4/binary, Rest/binary>> ->
            case byte_size(Rest) >= Length of
                true ->
                    <<Payload:Length/binary, Remaining/binary>> = Rest,
                    %% Verify checksum
                    <<ExpectedCS:4/binary, _/binary>> = crypto:hash(sha256,
                        crypto:hash(sha256, Payload)),
                    case ExpectedCS =:= Checksum of
                        true ->
                            {ok, Command, Payload, Remaining};
                        false ->
                            {error, bad_checksum}
                    end;
                false ->
                    {incomplete, Buffer}
            end;
        <<_:4/binary, _/binary>> ->
            {error, bad_magic};
        _ ->
            {incomplete, Buffer}
    end.

%% Version message
make_version_message(Data) ->
    Timestamp = erlang:system_time(second),
    Nonce = rand:uniform(16#FFFFFFFFFFFFFFFF),
    UserAgent = <<"/oni:0.1.0/">>,
    UALen = byte_size(UserAgent),

    %% Simplified - missing addr_recv and addr_from details
    Payload = <<
        70016:32/little,           % protocol version
        1:64/little,               % services (NODE_NETWORK)
        Timestamp:64/little,       % timestamp
        0:64/little,               % addr_recv services
        0:128,                     % addr_recv IP (16 bytes)
        (Data#data.port):16/big,   % addr_recv port
        1:64/little,               % addr_from services
        0:128,                     % addr_from IP
        0:16/big,                  % addr_from port
        Nonce:64/little,           % nonce
        UALen:8,                   % user agent length
        UserAgent/binary,          % user agent
        0:32/little,               % start height
        1:8                        % relay
    >>,

    encode_message({version, Payload}).

parse_version(Payload) ->
    try
        <<Version:32/little, Services:64/little, _Timestamp:64/little,
          _AddrRecv:26/binary, _AddrFrom:26/binary, _Nonce:64/little,
          Rest/binary>> = Payload,
        {UALen, Rest2} = parse_varint(Rest),
        <<UserAgent:UALen/binary, Rest3/binary>> = Rest2,
        <<StartHeight:32/little, _/binary>> = Rest3,
        {ok, Version, UserAgent, Services, StartHeight}
    catch
        _:_ -> {error, parse_failed}
    end.

parse_varint(<<N:8, Rest/binary>>) when N < 16#FD ->
    {N, Rest};
parse_varint(<<16#FD, N:16/little, Rest/binary>>) ->
    {N, Rest};
parse_varint(<<16#FE, N:32/little, Rest/binary>>) ->
    {N, Rest};
parse_varint(<<16#FF, N:64/little, Rest/binary>>) ->
    {N, Rest}.

encode_message(verack) ->
    encode_raw_message(<<"verack">>, <<>>);
encode_message({ping, Nonce}) ->
    encode_raw_message(<<"ping">>, <<Nonce:64/little>>);
encode_message({pong, Nonce}) ->
    encode_raw_message(<<"pong">>, <<Nonce:64/little>>);
encode_message({version, Payload}) ->
    encode_raw_message(<<"version">>, Payload);
encode_message({getheaders, Locators, StopHash}) ->
    Count = length(Locators),
    LocatorBin = << <<H/binary>> || H <- Locators >>,
    Payload = <<70016:32/little, Count:8, LocatorBin/binary, StopHash/binary>>,
    encode_raw_message(<<"getheaders">>, Payload);
encode_message({getdata, Items}) ->
    Count = length(Items),
    ItemsBin = << <<Type:32/little, Hash/binary>> || {Type, Hash} <- Items >>,
    Payload = <<Count:8, ItemsBin/binary>>,
    encode_raw_message(<<"getdata">>, Payload);
encode_message(_) ->
    <<>>.

encode_raw_message(Command, Payload) ->
    %% Pad command to 12 bytes
    CmdPadded = <<Command/binary, 0:(8 * (12 - byte_size(Command)))>>,
    Length = byte_size(Payload),
    <<Checksum:4/binary, _/binary>> = crypto:hash(sha256, crypto:hash(sha256, Payload)),
    <<CmdPadded/binary, Length:32/little, Checksum/binary, Payload/binary>>.

send_raw(Socket, Magic, MessageData) ->
    Data = <<Magic/binary, MessageData/binary>>,
    gen_tcp:send(Socket, Data).

ip_to_tuple({A, B, C, D}) ->
    {A, B, C, D};
ip_to_tuple(Ip) when is_list(Ip) ->
    {ok, Tuple} = inet:parse_address(Ip),
    Tuple;
ip_to_tuple(Ip) when is_binary(Ip) ->
    ip_to_tuple(binary_to_list(Ip)).

trim_null(Bin) ->
    [B || B <- binary_to_list(Bin), B =/= 0].

peer_info(Data) ->
    #{
        ip => Data#data.ip,
        port => Data#data.port,
        network => Data#data.network,
        version => Data#data.version,
        user_agent => Data#data.user_agent,
        services => Data#data.services,
        start_height => Data#data.start_height,
        bytes_sent => Data#data.bytes_sent,
        bytes_recv => Data#data.bytes_recv,
        last_send => Data#data.last_send,
        last_recv => Data#data.last_recv
    }.
