%%% oni_peer_manager - Peer lifecycle and connection management
%%%
%%% Responsibilities:
%%% - Maintain target number of outbound connections
%%% - Accept inbound connection notifications
%%% - Route messages to appropriate handlers
%%% - Track peer states and statistics

-module(oni_peer_manager).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    connect_to/2,
    disconnect/1,
    get_peers/0,
    get_peer_count/0,
    peer_ready/3,
    handle_inv/2,
    handle_headers/2,
    handle_block/2,
    handle_tx/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(peer, {
    pid :: pid(),
    ref :: reference(),
    version :: non_neg_integer() | undefined,
    services :: non_neg_integer(),
    ready :: boolean()
}).

-record(state, {
    config :: map(),
    peers :: map(),  % pid() -> #peer{}
    max_outbound :: non_neg_integer(),
    target_outbound :: non_neg_integer(),
    connecting :: sets:set()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Connect to a peer
-spec connect_to(inet:ip_address(), inet:port_number()) -> ok | {error, term()}.
connect_to(IpAddr, Port) ->
    gen_server:call(?MODULE, {connect_to, IpAddr, Port}).

%% Disconnect a peer
-spec disconnect(pid()) -> ok.
disconnect(Pid) ->
    gen_server:cast(?MODULE, {disconnect, Pid}).

%% Get all connected peers
-spec get_peers() -> [map()].
get_peers() ->
    gen_server:call(?MODULE, get_peers).

%% Get peer count
-spec get_peer_count() -> non_neg_integer().
get_peer_count() ->
    gen_server:call(?MODULE, get_peer_count).

%% Called by oni_peer when handshake completes
-spec peer_ready(pid(), non_neg_integer(), non_neg_integer()) -> ok.
peer_ready(Pid, Version, Services) ->
    gen_server:cast(?MODULE, {peer_ready, Pid, Version, Services}).

%% Handle inventory announcement from a peer
handle_inv(Pid, Payload) ->
    gen_server:cast(?MODULE, {inv, Pid, Payload}).

%% Handle headers from a peer
handle_headers(Pid, Payload) ->
    gen_server:cast(?MODULE, {headers, Pid, Payload}).

%% Handle block from a peer
handle_block(Pid, Payload) ->
    gen_server:cast(?MODULE, {block, Pid, Payload}).

%% Handle transaction from a peer
handle_tx(Pid, Payload) ->
    gen_server:cast(?MODULE, {tx, Pid, Payload}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Config) ->
    MaxOutbound = maps:get(max_connections, Config, 125) div 2,

    State = #state{
        config = Config,
        peers = #{},
        max_outbound = MaxOutbound,
        target_outbound = 8,
        connecting = sets:new()
    },

    %% Schedule initial connection attempts
    erlang:send_after(1000, self(), try_connect),

    io:format("[oni_peer_manager] Initialized, target ~p outbound peers~n",
              [State#state.target_outbound]),
    {ok, State}.

handle_call({connect_to, IpAddr, Port}, _From, State) ->
    case start_peer_connection(IpAddr, Port) of
        {ok, Pid} ->
            Ref = erlang:monitor(process, Pid),
            Peer = #peer{
                pid = Pid,
                ref = Ref,
                version = undefined,
                services = 0,
                ready = false
            },
            NewPeers = maps:put(Pid, Peer, State#state.peers),
            {reply, ok, State#state{peers = NewPeers}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(get_peers, _From, State) ->
    PeerList = maps:fold(fun(Pid, Peer, Acc) ->
        Info = try oni_peer:get_info(Pid) catch _:_ -> #{} end,
        [Info#{ready => Peer#peer.ready} | Acc]
    end, [], State#state.peers),
    {reply, PeerList, State};

handle_call(get_peer_count, _From, State) ->
    {reply, maps:size(State#state.peers), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({peer_ready, Pid, Version, Services}, State) ->
    case maps:get(Pid, State#state.peers, undefined) of
        undefined ->
            {noreply, State};
        Peer ->
            UpdatedPeer = Peer#peer{
                version = Version,
                services = Services,
                ready = true
            },
            NewPeers = maps:put(Pid, UpdatedPeer, State#state.peers),
            io:format("[oni_peer_manager] Peer ~p ready, version ~p, ~p total~n",
                      [Pid, Version, maps:size(NewPeers)]),
            %% Request initial headers
            request_initial_headers(Pid),
            {noreply, State#state{peers = NewPeers}}
    end;

handle_cast({disconnect, Pid}, State) ->
    case maps:get(Pid, State#state.peers, undefined) of
        undefined ->
            {noreply, State};
        Peer ->
            erlang:demonitor(Peer#peer.ref, [flush]),
            oni_peer:disconnect(Pid),
            NewPeers = maps:remove(Pid, State#state.peers),
            {noreply, State#state{peers = NewPeers}}
    end;

handle_cast({inv, Pid, Payload}, State) ->
    %% Parse inventory items
    case parse_inv(Payload) of
        {ok, Items} ->
            %% Request blocks we don't have
            BlockHashes = [Hash || {Type, Hash} <- Items,
                                   Type =:= 2 orelse Type =:= 16#40000002,
                                   not oni_block_store:has_block(Hash)],
            case BlockHashes of
                [] -> ok;
                _ ->
                    GetDataItems = [{2, H} || H <- BlockHashes],
                    oni_peer:send_message(Pid, {getdata, GetDataItems})
            end;
        {error, _} ->
            ok
    end,
    {noreply, State};

handle_cast({headers, _Pid, Payload}, State) ->
    %% Parse and store headers
    case parse_headers(Payload) of
        {ok, Headers} ->
            lists:foreach(fun({Hash, Header}) ->
                oni_chainstate:add_header(Hash, Header)
            end, Headers),
            io:format("[oni_peer_manager] Received ~p headers~n", [length(Headers)]);
        {error, _} ->
            ok
    end,
    {noreply, State};

handle_cast({block, _Pid, Payload}, State) ->
    %% Parse and store block
    case parse_block(Payload) of
        {ok, BlockHash, BlockData} ->
            oni_block_store:store_block(BlockHash, BlockData),
            io:format("[oni_peer_manager] Received block ~s~n",
                      [hex_encode(BlockHash)]);
        {error, _} ->
            ok
    end,
    {noreply, State};

handle_cast({tx, _Pid, Payload}, State) ->
    %% Forward to mempool
    oni_mempool_server:submit_tx(Payload),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    case maps:get(Pid, State#state.peers, undefined) of
        undefined ->
            {noreply, State};
        _Peer ->
            io:format("[oni_peer_manager] Peer ~p disconnected: ~p~n", [Pid, Reason]),
            NewPeers = maps:remove(Pid, State#state.peers),
            {noreply, State#state{peers = NewPeers}}
    end;

handle_info(try_connect, State) ->
    ReadyCount = count_ready_peers(State#state.peers),
    case ReadyCount < State#state.target_outbound of
        true ->
            %% Try to connect to more peers
            try_connect_to_seed(State#state.config);
        false ->
            ok
    end,
    %% Schedule next connection attempt
    erlang:send_after(30000, self(), try_connect),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

start_peer_connection(IpAddr, Port) ->
    oni_conn_sup:start_peer(IpAddr, Port).

count_ready_peers(Peers) ->
    maps:fold(fun(_, Peer, Acc) ->
        case Peer#peer.ready of
            true -> Acc + 1;
            false -> Acc
        end
    end, 0, Peers).

try_connect_to_seed(Config) ->
    Seeds = maps:get(dns_seeds, Config, []),
    case Seeds of
        [] ->
            ok;
        [Seed | _] ->
            %% Resolve DNS seed
            case inet:gethostbyname(Seed) of
                {ok, {hostent, _, _, _, _, Addrs}} ->
                    case Addrs of
                        [Addr | _] ->
                            Port = maps:get(p2p_port, Config, 8333),
                            io:format("[oni_peer_manager] Trying to connect to ~p:~p~n",
                                      [Addr, Port]),
                            start_peer_connection(Addr, Port);
                        [] ->
                            ok
                    end;
                {error, _} ->
                    ok
            end
    end.

request_initial_headers(Pid) ->
    %% Request headers from genesis
    GenesisHash = case oni_chainstate:get_header_by_height(0) of
        {ok, Hash} -> Hash;
        _ -> <<0:256>>
    end,
    StopHash = <<0:256>>,
    oni_peer:send_message(Pid, {getheaders, [GenesisHash], StopHash}).

parse_inv(<<Count:8, Rest/binary>>) ->
    parse_inv_items(Rest, Count, []);
parse_inv(_) ->
    {error, invalid_inv}.

parse_inv_items(_, 0, Acc) ->
    {ok, lists:reverse(Acc)};
parse_inv_items(<<Type:32/little, Hash:32/binary, Rest/binary>>, N, Acc) when N > 0 ->
    parse_inv_items(Rest, N - 1, [{Type, Hash} | Acc]);
parse_inv_items(_, _, _) ->
    {error, invalid_inv}.

parse_headers(<<Count:8, Rest/binary>>) ->
    parse_header_items(Rest, Count, []);
parse_headers(_) ->
    {error, invalid_headers}.

parse_header_items(_, 0, Acc) ->
    {ok, lists:reverse(Acc)};
parse_header_items(<<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary,
                     Timestamp:32/little, Bits:32/little, Nonce:32/little,
                     _TxCount:8, Rest/binary>>, N, Acc) when N > 0 ->
    HeaderData = <<Version:32/little, PrevBlock/binary, MerkleRoot/binary,
                   Timestamp:32/little, Bits:32/little, Nonce:32/little>>,
    Hash = crypto:hash(sha256, crypto:hash(sha256, HeaderData)),
    Header = #{
        version => Version,
        prev_block => PrevBlock,
        merkle_root => MerkleRoot,
        timestamp => Timestamp,
        bits => Bits,
        nonce => Nonce
    },
    parse_header_items(Rest, N - 1, [{Hash, Header} | Acc]);
parse_header_items(_, _, _) ->
    {error, invalid_header}.

parse_block(BlockData) ->
    try
        <<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary,
          Timestamp:32/little, Bits:32/little, Nonce:32/little, _Rest/binary>> = BlockData,
        HeaderData = <<Version:32/little, PrevBlock/binary, MerkleRoot/binary,
                       Timestamp:32/little, Bits:32/little, Nonce:32/little>>,
        Hash = crypto:hash(sha256, crypto:hash(sha256, HeaderData)),
        {ok, Hash, BlockData}
    catch
        _:_ -> {error, invalid_block}
    end.

hex_encode(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X:8>> <= Bin]).
