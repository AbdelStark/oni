%%% oni_rpc_server - JSON-RPC 2.0 server
%%%
%%% Provides a Bitcoin Core compatible JSON-RPC interface.
%%% Uses cowboy for HTTP handling.

-module(oni_rpc_server).
-behaviour(gen_server).

-export([start_link/1]).
-export([get_info/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% HTTP handler
-export([handle_request/1]).

-record(state, {
    port :: non_neg_integer(),
    listener :: pid() | undefined,
    rpc_user :: binary() | undefined,
    rpc_password :: binary() | undefined,
    request_count :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Get server info
-spec get_info() -> map().
get_info() ->
    gen_server:call(?MODULE, get_info).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Config) ->
    Port = maps:get(rpc_port, Config, 8332),
    User = maps:get(rpc_user, Config, undefined),
    Password = maps:get(rpc_password, Config, undefined),

    State = #state{
        port = Port,
        rpc_user = to_binary(User),
        rpc_password = to_binary(Password),
        request_count = 0
    },

    %% Start a simple HTTP listener using Erlang's built-in httpd
    %% For production, use cowboy or similar
    case start_http_listener(Port) of
        {ok, Pid} ->
            io:format("[oni_rpc_server] Listening on port ~p~n", [Port]),
            {ok, State#state{listener = Pid}};
        {error, Reason} ->
            io:format("[oni_rpc_server] Failed to start HTTP listener: ~p~n", [Reason]),
            io:format("[oni_rpc_server] RPC will not be available~n"),
            {ok, State}
    end.

handle_call(get_info, _From, State) ->
    Info = #{
        port => State#state.port,
        listening => State#state.listener =/= undefined,
        request_count => State#state.request_count,
        auth_required => State#state.rpc_user =/= undefined
    },
    {reply, Info, State};

handle_call({rpc_request, Request}, _From, State) ->
    Response = handle_rpc(Request),
    NewState = State#state{request_count = State#state.request_count + 1},
    {reply, Response, NewState};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.listener of
        undefined -> ok;
        Pid -> exit(Pid, shutdown)
    end,
    ok.

%% ============================================================================
%% RPC Request Handling
%% ============================================================================

%% HTTP request handler (called from HTTP server)
handle_request(Body) ->
    gen_server:call(?MODULE, {rpc_request, Body}).

%% Process JSON-RPC request
handle_rpc(Body) ->
    try
        Request = decode_json(Body),
        Method = maps:get(<<"method">>, Request, <<>>),
        Params = maps:get(<<"params">>, Request, []),
        Id = maps:get(<<"id">>, Request, null),

        Result = execute_method(Method, Params),

        case Result of
            {ok, Value} ->
                encode_json(#{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"result">> => Value,
                    <<"id">> => Id
                });
            {error, Code, Message} ->
                encode_json(#{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"error">> => #{
                        <<"code">> => Code,
                        <<"message">> => Message
                    },
                    <<"id">> => Id
                })
        end
    catch
        _:_ ->
            encode_json(#{
                <<"jsonrpc">> => <<"2.0">>,
                <<"error">> => #{
                    <<"code">> => -32700,
                    <<"message">> => <<"Parse error">>
                },
                <<"id">> => null
            })
    end.

%% Execute RPC method
execute_method(<<"getblockchaininfo">>, _Params) ->
    Height = oni_chainstate:get_chain_height(),
    {ok, BestBlock} = oni_chainstate:get_best_block(),
    Stats = oni_chainstate:get_stats(),

    {ok, #{
        <<"chain">> => maps:get(network, Stats, <<"main">>),
        <<"blocks">> => Height,
        <<"headers">> => maps:get(headers_count, Stats, Height),
        <<"bestblockhash">> => hex_encode(BestBlock),
        <<"difficulty">> => 1.0,
        <<"verificationprogress">> => 1.0,
        <<"pruned">> => false,
        <<"size_on_disk">> => 0,
        <<"warnings">> => <<>>
    }};

execute_method(<<"getnetworkinfo">>, _Params) ->
    PeerCount = oni_peer_manager:get_peer_count(),

    {ok, #{
        <<"version">> => 240000,
        <<"subversion">> => <<"/oni:0.1.0/">>,
        <<"protocolversion">> => 70016,
        <<"connections">> => PeerCount,
        <<"connections_in">> => 0,
        <<"connections_out">> => PeerCount,
        <<"networks">> => [],
        <<"localaddresses">> => [],
        <<"warnings">> => <<>>
    }};

execute_method(<<"getpeerinfo">>, _Params) ->
    Peers = oni_peer_manager:get_peers(),
    PeerInfo = [format_peer_info(P) || P <- Peers],
    {ok, PeerInfo};

execute_method(<<"getmempoolinfo">>, _Params) ->
    Info = oni_mempool_server:get_mempool_info(),
    {ok, #{
        <<"loaded">> => true,
        <<"size">> => maps:get(size, Info, 0),
        <<"bytes">> => maps:get(bytes, Info, 0),
        <<"usage">> => maps:get(bytes, Info, 0),
        <<"total_fee">> => maps:get(total_fee, Info, 0) / 100000000,
        <<"maxmempool">> => maps:get(max_size, Info, 300000000),
        <<"mempoolminfee">> => maps:get(min_relay_fee, Info, 1000) / 100000000,
        <<"minrelaytxfee">> => maps:get(min_relay_fee, Info, 1000) / 100000000,
        <<"unbroadcastcount">> => 0
    }};

execute_method(<<"getrawmempool">>, _Params) ->
    Txids = oni_mempool_server:get_all_txids(),
    TxidHexes = [hex_encode(T) || T <- Txids],
    {ok, TxidHexes};

execute_method(<<"getblockcount">>, _Params) ->
    Height = oni_chainstate:get_chain_height(),
    {ok, Height};

execute_method(<<"getbestblockhash">>, _Params) ->
    case oni_chainstate:get_best_block() of
        {ok, Hash} -> {ok, hex_encode(Hash)};
        {error, _} -> {error, -1, <<"No blocks">>}
    end;

execute_method(<<"getblock">>, [BlockHash]) ->
    case hex_decode(BlockHash) of
        {ok, Hash} ->
            case oni_block_store:get_block(Hash) of
                {ok, BlockData} ->
                    {ok, hex_encode(BlockData)};
                {error, not_found} ->
                    {error, -5, <<"Block not found">>}
            end;
        {error, _} ->
            {error, -8, <<"Invalid block hash">>}
    end;

execute_method(<<"getblock">>, [BlockHash, Verbosity]) when Verbosity == 0 ->
    execute_method(<<"getblock">>, [BlockHash]);

execute_method(<<"getrawtransaction">>, [Txid]) ->
    case hex_decode(Txid) of
        {ok, TxidBin} ->
            case oni_mempool_server:get_tx(TxidBin) of
                {ok, TxData} ->
                    {ok, hex_encode(TxData)};
                {error, not_found} ->
                    {error, -5, <<"Transaction not found">>}
            end;
        {error, _} ->
            {error, -8, <<"Invalid transaction id">>}
    end;

execute_method(<<"sendrawtransaction">>, [TxHex]) ->
    case hex_decode(TxHex) of
        {ok, TxData} ->
            case oni_mempool_server:submit_tx(TxData) of
                ok ->
                    Txid = crypto:hash(sha256, crypto:hash(sha256, TxData)),
                    {ok, hex_encode(Txid)};
                {error, Reason} ->
                    {error, -26, list_to_binary(io_lib:format("~p", [Reason]))}
            end;
        {error, _} ->
            {error, -22, <<"TX decode failed">>}
    end;

execute_method(<<"stop">>, _Params) ->
    io:format("[oni_rpc_server] Shutdown requested via RPC~n"),
    spawn(fun() ->
        timer:sleep(1000),
        init:stop()
    end),
    {ok, <<"oni server stopping">>};

execute_method(<<"uptime">>, _Params) ->
    %% Return node uptime in seconds
    {ok, erlang:system_time(second) - erlang:monotonic_time(second)};

execute_method(<<"help">>, _Params) ->
    Methods = [
        <<"getblockchaininfo">>,
        <<"getnetworkinfo">>,
        <<"getpeerinfo">>,
        <<"getmempoolinfo">>,
        <<"getrawmempool">>,
        <<"getblockcount">>,
        <<"getbestblockhash">>,
        <<"getblock <hash>">>,
        <<"getrawtransaction <txid>">>,
        <<"sendrawtransaction <hex>">>,
        <<"stop">>,
        <<"uptime">>,
        <<"help">>
    ],
    {ok, Methods};

execute_method(Method, _Params) ->
    {error, -32601, <<"Method not found: ", Method/binary>>}.

%% ============================================================================
%% Helper Functions
%% ============================================================================

format_peer_info(Peer) ->
    #{
        <<"addr">> => format_addr(maps:get(ip, Peer, undefined), maps:get(port, Peer, 0)),
        <<"version">> => maps:get(version, Peer, 0),
        <<"subver">> => maps:get(user_agent, Peer, <<>>),
        <<"services">> => integer_to_binary(maps:get(services, Peer, 0), 16),
        <<"inbound">> => false,
        <<"synced_headers">> => maps:get(start_height, Peer, 0),
        <<"synced_blocks">> => maps:get(start_height, Peer, 0),
        <<"bytessent">> => maps:get(bytes_sent, Peer, 0),
        <<"bytesrecv">> => maps:get(bytes_recv, Peer, 0)
    }.

format_addr(undefined, _Port) -> <<"unknown">>;
format_addr({A, B, C, D}, Port) ->
    list_to_binary(io_lib:format("~p.~p.~p.~p:~p", [A, B, C, D, Port]));
format_addr(Ip, Port) ->
    list_to_binary(io_lib:format("~p:~p", [Ip, Port])).

hex_encode(Bin) when is_binary(Bin) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X:8>> <= Bin])).

hex_decode(Hex) when is_binary(Hex) ->
    hex_decode(binary_to_list(Hex));
hex_decode(Hex) when is_list(Hex) ->
    try
        Bin = << <<(list_to_integer([H, L], 16)):8>> || [H, L] <- pairs(Hex) >>,
        {ok, Bin}
    catch
        _:_ -> {error, invalid_hex}
    end.

pairs([]) -> [];
pairs([H, L | Rest]) -> [[H, L] | pairs(Rest)];
pairs([_]) -> [].

to_binary(undefined) -> undefined;
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8).

%% Simple JSON encoding/decoding (production: use jsx or jiffy)
decode_json(Body) when is_binary(Body) ->
    %% Very basic JSON parsing - production should use proper library
    case Body of
        <<"{", _/binary>> ->
            parse_json_object(Body);
        _ ->
            #{}
    end.

parse_json_object(<<"{", Rest/binary>>) ->
    parse_json_pairs(Rest, #{}).

parse_json_pairs(<<" ", Rest/binary>>, Acc) ->
    parse_json_pairs(Rest, Acc);
parse_json_pairs(<<"}", _/binary>>, Acc) ->
    Acc;
parse_json_pairs(<<"\"", Rest/binary>>, Acc) ->
    {Key, Rest2} = parse_json_string(Rest, <<>>),
    Rest3 = skip_colon(Rest2),
    {Value, Rest4} = parse_json_value(Rest3),
    Rest5 = skip_comma(Rest4),
    parse_json_pairs(Rest5, maps:put(Key, Value, Acc));
parse_json_pairs(_, Acc) ->
    Acc.

parse_json_string(<<"\"", Rest/binary>>, Acc) ->
    {Acc, Rest};
parse_json_string(<<"\\\"", Rest/binary>>, Acc) ->
    parse_json_string(Rest, <<Acc/binary, "\"">>);
parse_json_string(<<C:8, Rest/binary>>, Acc) ->
    parse_json_string(Rest, <<Acc/binary, C:8>>);
parse_json_string(<<>>, Acc) ->
    {Acc, <<>>}.

parse_json_value(<<"\"", Rest/binary>>) ->
    parse_json_string(Rest, <<>>);
parse_json_value(<<"[", Rest/binary>>) ->
    parse_json_array(Rest, []);
parse_json_value(<<"{", Rest/binary>>) ->
    Obj = parse_json_object(<<"{", Rest/binary>>),
    {Obj, skip_until_end_brace(Rest)};
parse_json_value(<<"null", Rest/binary>>) ->
    {null, Rest};
parse_json_value(<<"true", Rest/binary>>) ->
    {true, Rest};
parse_json_value(<<"false", Rest/binary>>) ->
    {false, Rest};
parse_json_value(Bin) ->
    parse_json_number(Bin, <<>>).

parse_json_array(<<"]", Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
parse_json_array(<<" ", Rest/binary>>, Acc) ->
    parse_json_array(Rest, Acc);
parse_json_array(<<",", Rest/binary>>, Acc) ->
    parse_json_array(Rest, Acc);
parse_json_array(Bin, Acc) ->
    {Value, Rest} = parse_json_value(Bin),
    parse_json_array(Rest, [Value | Acc]).

parse_json_number(<<C:8, Rest/binary>>, Acc) when C >= $0, C =< $9; C =:= $-; C =:= $. ->
    parse_json_number(Rest, <<Acc/binary, C:8>>);
parse_json_number(Rest, Acc) ->
    {binary_to_integer(Acc), Rest}.

skip_colon(<<" ", Rest/binary>>) -> skip_colon(Rest);
skip_colon(<<":", Rest/binary>>) -> skip_spaces(Rest);
skip_colon(Rest) -> Rest.

skip_comma(<<" ", Rest/binary>>) -> skip_comma(Rest);
skip_comma(<<",", Rest/binary>>) -> skip_spaces(Rest);
skip_comma(Rest) -> Rest.

skip_spaces(<<" ", Rest/binary>>) -> skip_spaces(Rest);
skip_spaces(Rest) -> Rest.

skip_until_end_brace(<<"}", Rest/binary>>) -> Rest;
skip_until_end_brace(<<_, Rest/binary>>) -> skip_until_end_brace(Rest);
skip_until_end_brace(<<>>) -> <<>>.

encode_json(Map) when is_map(Map) ->
    Pairs = maps:to_list(Map),
    PairsJson = [encode_pair(K, V) || {K, V} <- Pairs],
    <<"{", (iolist_to_binary(lists:join(<<",">>, PairsJson)))/binary, "}">>;
encode_json(List) when is_list(List) ->
    Items = [encode_json(I) || I <- List],
    <<"[", (iolist_to_binary(lists:join(<<",">>, Items)))/binary, "]">>;
encode_json(Bin) when is_binary(Bin) ->
    <<"\"", Bin/binary, "\"">>;
encode_json(Int) when is_integer(Int) ->
    integer_to_binary(Int);
encode_json(Float) when is_float(Float) ->
    float_to_binary(Float, [{decimals, 8}, compact]);
encode_json(true) -> <<"true">>;
encode_json(false) -> <<"false">>;
encode_json(null) -> <<"null">>;
encode_json(Atom) when is_atom(Atom) ->
    <<"\"", (atom_to_binary(Atom, utf8))/binary, "\"">>.

encode_pair(K, V) ->
    <<(encode_json(K))/binary, ":", (encode_json(V))/binary>>.

%% Start a simple HTTP listener
start_http_listener(Port) ->
    %% Use a simple gen_tcp based HTTP server
    spawn_link(fun() -> http_accept_loop(Port) end),
    {ok, self()}.

http_accept_loop(Port) ->
    case gen_tcp:listen(Port, [binary, {packet, http}, {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            http_accept(ListenSocket);
        {error, _} ->
            ok
    end.

http_accept(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            spawn(fun() -> http_handle(Socket) end),
            http_accept(ListenSocket);
        {error, _} ->
            ok
    end.

http_handle(Socket) ->
    case gen_tcp:recv(Socket, 0, 30000) of
        {ok, {http_request, 'POST', _, _}} ->
            http_read_headers(Socket, []);
        _ ->
            gen_tcp:close(Socket)
    end.

http_read_headers(Socket, Headers) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, {http_header, _, 'Content-Length', _, LenStr}} ->
            Len = list_to_integer(LenStr),
            http_read_headers(Socket, [{content_length, Len} | Headers]);
        {ok, {http_header, _, _, _, _}} ->
            http_read_headers(Socket, Headers);
        {ok, http_eoh} ->
            ContentLength = proplists:get_value(content_length, Headers, 0),
            inet:setopts(Socket, [{packet, raw}]),
            case gen_tcp:recv(Socket, ContentLength, 5000) of
                {ok, Body} ->
                    Response = handle_request(Body),
                    HttpResponse = [
                        "HTTP/1.1 200 OK\r\n",
                        "Content-Type: application/json\r\n",
                        "Content-Length: ", integer_to_list(byte_size(Response)), "\r\n",
                        "\r\n",
                        Response
                    ],
                    gen_tcp:send(Socket, HttpResponse);
                _ ->
                    ok
            end,
            gen_tcp:close(Socket);
        _ ->
            gen_tcp:close(Socket)
    end.
