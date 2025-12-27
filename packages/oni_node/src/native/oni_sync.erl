%%% oni_sync - Initial Block Download and chain synchronization
%%%
%%% Responsibilities:
%%% - Coordinate header-first synchronization
%%% - Manage block download from peers
%%% - Validate and connect blocks to the chain
%%% - Handle reorgs and stale blocks
%%% - Track sync progress and provide status

-module(oni_sync).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    get_sync_status/0,
    is_synced/0,
    request_sync/0,
    pause_sync/0,
    resume_sync/0,
    add_headers/2,
    add_block/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Sync states
-define(STATE_IDLE, idle).
-define(STATE_HEADERS, downloading_headers).
-define(STATE_BLOCKS, downloading_blocks).
-define(STATE_SYNCED, synced).

%% Configuration constants
-define(HEADERS_BATCH_SIZE, 2000).
-define(BLOCKS_IN_FLIGHT_MAX, 16).
-define(BLOCK_DOWNLOAD_TIMEOUT, 60000).  % 60 seconds
-define(HEADER_SYNC_INTERVAL, 30000).    % 30 seconds
-define(PROGRESS_LOG_INTERVAL, 10000).   % 10 seconds

-record(block_request, {
    hash :: binary(),
    peer_pid :: pid(),
    requested_at :: integer(),
    height :: non_neg_integer()
}).

-record(state, {
    config :: map(),
    sync_state :: atom(),
    paused :: boolean(),

    %% Headers tracking
    header_tip :: binary() | undefined,      % Best known header hash
    header_height :: non_neg_integer(),      % Best known header height

    %% Block download tracking
    blocks_in_flight :: map(),               % Hash -> #block_request{}
    blocks_queue :: queue:queue(),           % Hashes to download
    validated_height :: non_neg_integer(),   % Highest validated block

    %% Progress tracking
    start_time :: integer(),
    blocks_downloaded :: non_neg_integer(),
    bytes_downloaded :: non_neg_integer(),

    %% Checkpoints
    checkpoints :: map()                     % Height -> Hash
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Get current sync status
-spec get_sync_status() -> map().
get_sync_status() ->
    gen_server:call(?MODULE, get_sync_status).

%% Check if we're synced to tip
-spec is_synced() -> boolean().
is_synced() ->
    gen_server:call(?MODULE, is_synced).

%% Trigger a sync request
-spec request_sync() -> ok.
request_sync() ->
    gen_server:cast(?MODULE, request_sync).

%% Pause synchronization
-spec pause_sync() -> ok.
pause_sync() ->
    gen_server:cast(?MODULE, pause_sync).

%% Resume synchronization
-spec resume_sync() -> ok.
resume_sync() ->
    gen_server:cast(?MODULE, resume_sync).

%% Add received headers from peer
-spec add_headers(pid(), list()) -> ok.
add_headers(PeerPid, Headers) ->
    gen_server:cast(?MODULE, {add_headers, PeerPid, Headers}).

%% Add received block from peer
-spec add_block(pid(), binary()) -> ok.
add_block(PeerPid, BlockData) ->
    gen_server:cast(?MODULE, {add_block, PeerPid, BlockData}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Config) ->
    %% Load checkpoints for the network
    Network = maps:get(network, Config, mainnet),
    Checkpoints = load_checkpoints(Network),

    State = #state{
        config = Config,
        sync_state = ?STATE_IDLE,
        paused = false,
        header_tip = undefined,
        header_height = 0,
        blocks_in_flight = #{},
        blocks_queue = queue:new(),
        validated_height = 0,
        start_time = erlang:system_time(second),
        blocks_downloaded = 0,
        bytes_downloaded = 0,
        checkpoints = Checkpoints
    },

    %% Schedule initial sync after startup
    erlang:send_after(5000, self(), start_initial_sync),

    %% Schedule progress logging
    erlang:send_after(?PROGRESS_LOG_INTERVAL, self(), log_progress),

    io:format("[oni_sync] Initialized with ~p checkpoints~n",
              [maps:size(Checkpoints)]),

    {ok, State}.

handle_call(get_sync_status, _From, State) ->
    Status = #{
        state => State#state.sync_state,
        paused => State#state.paused,
        header_height => State#state.header_height,
        validated_height => State#state.validated_height,
        blocks_in_flight => maps:size(State#state.blocks_in_flight),
        blocks_queued => queue:len(State#state.blocks_queue),
        blocks_downloaded => State#state.blocks_downloaded,
        bytes_downloaded => State#state.bytes_downloaded,
        uptime_seconds => erlang:system_time(second) - State#state.start_time
    },
    {reply, Status, State};

handle_call(is_synced, _From, State) ->
    IsSynced = State#state.sync_state =:= ?STATE_SYNCED,
    {reply, IsSynced, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(request_sync, State) ->
    case State#state.paused of
        true ->
            {noreply, State};
        false ->
            NewState = start_header_sync(State),
            {noreply, NewState}
    end;

handle_cast(pause_sync, State) ->
    io:format("[oni_sync] Sync paused~n"),
    {noreply, State#state{paused = true}};

handle_cast(resume_sync, State) ->
    io:format("[oni_sync] Sync resumed~n"),
    NewState = State#state{paused = false},
    self() ! continue_sync,
    {noreply, NewState};

handle_cast({add_headers, PeerPid, Headers}, State) ->
    NewState = process_headers(PeerPid, Headers, State),
    {noreply, NewState};

handle_cast({add_block, PeerPid, BlockData}, State) ->
    NewState = process_block(PeerPid, BlockData, State),
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(start_initial_sync, State) ->
    io:format("[oni_sync] Starting initial synchronization~n"),

    %% Load current chain tip from storage
    {CurrentHeight, CurrentTip} = get_current_chain_tip(),

    NewState = State#state{
        validated_height = CurrentHeight,
        header_height = CurrentHeight,
        header_tip = CurrentTip
    },

    %% Start header sync
    self() ! continue_sync,
    {noreply, NewState#state{sync_state = ?STATE_HEADERS}};

handle_info(continue_sync, State) ->
    case State#state.paused of
        true ->
            {noreply, State};
        false ->
            NewState = continue_synchronization(State),
            {noreply, NewState}
    end;

handle_info(log_progress, State) ->
    log_sync_progress(State),
    erlang:send_after(?PROGRESS_LOG_INTERVAL, self(), log_progress),
    {noreply, State};

handle_info({block_timeout, Hash}, State) ->
    %% Handle block download timeout
    case maps:get(Hash, State#state.blocks_in_flight, undefined) of
        undefined ->
            {noreply, State};
        Request ->
            io:format("[oni_sync] Block timeout: ~s from ~p~n",
                      [hex_encode(Hash), Request#block_request.peer_pid]),
            %% Remove from in-flight and re-queue
            NewInFlight = maps:remove(Hash, State#state.blocks_in_flight),
            NewQueue = queue:in(Hash, State#state.blocks_queue),
            NewState = State#state{
                blocks_in_flight = NewInFlight,
                blocks_queue = NewQueue
            },
            self() ! continue_sync,
            {noreply, NewState}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ============================================================================
%% Internal Functions - Synchronization Logic
%% ============================================================================

continue_synchronization(#state{sync_state = ?STATE_IDLE} = State) ->
    %% Start header download
    start_header_sync(State);

continue_synchronization(#state{sync_state = ?STATE_HEADERS} = State) ->
    %% Continue header download or transition to block download
    case State#state.header_height > State#state.validated_height + 100 of
        true ->
            %% Have enough headers, start downloading blocks
            start_block_download(State#state{sync_state = ?STATE_BLOCKS});
        false ->
            %% Continue getting headers
            request_more_headers(State)
    end;

continue_synchronization(#state{sync_state = ?STATE_BLOCKS} = State) ->
    %% Continue block download
    NewState = download_more_blocks(State),

    %% Check if we've caught up
    case NewState#state.validated_height >= NewState#state.header_height of
        true ->
            io:format("[oni_sync] Initial sync complete at height ~p~n",
                      [NewState#state.validated_height]),
            NewState#state{sync_state = ?STATE_SYNCED};
        false ->
            NewState
    end;

continue_synchronization(#state{sync_state = ?STATE_SYNCED} = State) ->
    %% Already synced, check for new blocks periodically
    erlang:send_after(?HEADER_SYNC_INTERVAL, self(), continue_sync),
    request_more_headers(State).

start_header_sync(State) ->
    io:format("[oni_sync] Starting header synchronization~n"),
    request_more_headers(State#state{sync_state = ?STATE_HEADERS}).

request_more_headers(State) ->
    %% Get a connected peer
    case get_sync_peer() of
        undefined ->
            %% No peers available, retry later
            erlang:send_after(5000, self(), continue_sync),
            State;
        PeerPid ->
            %% Request headers from our tip
            Locator = build_block_locator(State#state.header_tip,
                                          State#state.header_height),
            oni_peer:send_message(PeerPid, {getheaders, Locator, <<0:256>>}),
            State
    end.

start_block_download(State) ->
    io:format("[oni_sync] Starting block download from height ~p to ~p~n",
              [State#state.validated_height, State#state.header_height]),

    %% Queue blocks from validated_height to header_height
    BlocksToQueue = get_blocks_to_download(
        State#state.validated_height + 1,
        min(State#state.header_height,
            State#state.validated_height + 500)  % Limit initial batch
    ),

    NewQueue = lists:foldl(fun(Hash, Q) ->
        queue:in(Hash, Q)
    end, State#state.blocks_queue, BlocksToQueue),

    download_more_blocks(State#state{blocks_queue = NewQueue}).

download_more_blocks(State) ->
    InFlightCount = maps:size(State#state.blocks_in_flight),

    case InFlightCount >= ?BLOCKS_IN_FLIGHT_MAX of
        true ->
            %% At capacity, wait for blocks to arrive
            State;
        false ->
            %% Request more blocks
            SlotsAvailable = ?BLOCKS_IN_FLIGHT_MAX - InFlightCount,
            request_blocks(State, SlotsAvailable)
    end.

request_blocks(State, 0) ->
    State;
request_blocks(State, N) ->
    case queue:out(State#state.blocks_queue) of
        {empty, _} ->
            %% No more blocks in queue
            State;
        {{value, Hash}, NewQueue} ->
            case get_sync_peer() of
                undefined ->
                    %% No peers, put block back
                    State;
                PeerPid ->
                    %% Request block from peer
                    oni_peer:send_message(PeerPid, {getdata, [{2, Hash}]}),

                    %% Track the request
                    Request = #block_request{
                        hash = Hash,
                        peer_pid = PeerPid,
                        requested_at = erlang:system_time(millisecond),
                        height = 0  % Would be looked up
                    },

                    %% Set timeout
                    erlang:send_after(?BLOCK_DOWNLOAD_TIMEOUT, self(),
                                      {block_timeout, Hash}),

                    NewInFlight = maps:put(Hash, Request, State#state.blocks_in_flight),
                    NewState = State#state{
                        blocks_in_flight = NewInFlight,
                        blocks_queue = NewQueue
                    },
                    request_blocks(NewState, N - 1)
            end
    end.

%% ============================================================================
%% Internal Functions - Header Processing
%% ============================================================================

process_headers(_PeerPid, [], State) ->
    %% Empty headers means we're caught up
    io:format("[oni_sync] Headers sync complete~n"),
    self() ! continue_sync,
    State;

process_headers(_PeerPid, Headers, State) ->
    %% Validate and store headers
    {ValidCount, NewTip, NewHeight} = validate_and_store_headers(
        Headers,
        State#state.header_tip,
        State#state.header_height,
        State#state.checkpoints
    ),

    io:format("[oni_sync] Processed ~p headers, height now ~p~n",
              [ValidCount, NewHeight]),

    NewState = State#state{
        header_tip = NewTip,
        header_height = NewHeight
    },

    %% Continue sync
    self() ! continue_sync,
    NewState.

validate_and_store_headers(Headers, PrevTip, PrevHeight, Checkpoints) ->
    validate_headers_loop(Headers, PrevTip, PrevHeight, 0, Checkpoints).

validate_headers_loop([], Tip, Height, Count, _Checkpoints) ->
    {Count, Tip, Height};
validate_headers_loop([{Hash, Header} | Rest], PrevTip, PrevHeight, Count, Checkpoints) ->
    %% Basic validation
    case validate_header(Header, PrevTip, PrevHeight + 1, Checkpoints) of
        ok ->
            %% Store header
            oni_chainstate:add_header(Hash, Header),
            validate_headers_loop(Rest, Hash, PrevHeight + 1, Count + 1, Checkpoints);
        {error, Reason} ->
            io:format("[oni_sync] Invalid header at height ~p: ~p~n",
                      [PrevHeight + 1, Reason]),
            {Count, PrevTip, PrevHeight}
    end.

validate_header(Header, ExpectedPrevHash, Height, Checkpoints) ->
    %% Check previous block hash
    PrevHash = maps:get(prev_block, Header),
    case ExpectedPrevHash of
        undefined ->
            ok;  % Genesis
        PrevHash ->
            ok;
        _ ->
            {error, prev_hash_mismatch}
    end,

    %% Check checkpoint if exists
    case maps:get(Height, Checkpoints, undefined) of
        undefined ->
            ok;
        ExpectedHash ->
            %% Would compute header hash and compare
            %% For now, skip checkpoint validation
            _ = ExpectedHash,
            ok
    end.

%% ============================================================================
%% Internal Functions - Block Processing
%% ============================================================================

process_block(PeerPid, BlockData, State) ->
    %% Parse block header to get hash
    case parse_block_hash(BlockData) of
        {ok, BlockHash} ->
            case maps:get(BlockHash, State#state.blocks_in_flight, undefined) of
                undefined ->
                    %% Unsolicited block
                    handle_unsolicited_block(BlockHash, BlockData, State);
                _Request ->
                    %% Expected block
                    handle_expected_block(PeerPid, BlockHash, BlockData, State)
            end;
        {error, _} ->
            io:format("[oni_sync] Failed to parse block from ~p~n", [PeerPid]),
            State
    end.

handle_expected_block(_PeerPid, BlockHash, BlockData, State) ->
    %% Remove from in-flight
    NewInFlight = maps:remove(BlockHash, State#state.blocks_in_flight),

    %% Validate and store block
    case validate_and_store_block(BlockHash, BlockData, State) of
        {ok, BlockHeight} ->
            NewState = State#state{
                blocks_in_flight = NewInFlight,
                validated_height = max(State#state.validated_height, BlockHeight),
                blocks_downloaded = State#state.blocks_downloaded + 1,
                bytes_downloaded = State#state.bytes_downloaded + byte_size(BlockData)
            },
            self() ! continue_sync,
            NewState;
        {error, Reason} ->
            io:format("[oni_sync] Block validation failed: ~p~n", [Reason]),
            State#state{blocks_in_flight = NewInFlight}
    end.

handle_unsolicited_block(BlockHash, BlockData, State) ->
    %% Check if it extends our chain
    case validate_and_store_block(BlockHash, BlockData, State) of
        {ok, BlockHeight} ->
            io:format("[oni_sync] Accepted unsolicited block at height ~p~n", [BlockHeight]),
            State#state{
                validated_height = max(State#state.validated_height, BlockHeight),
                header_height = max(State#state.header_height, BlockHeight)
            };
        {error, _} ->
            %% Ignore invalid unsolicited blocks
            State
    end.

validate_and_store_block(BlockHash, BlockData, State) ->
    %% Parse block
    case parse_block(BlockData) of
        {ok, Block} ->
            %% Validate block
            case validate_block(Block, State) of
                ok ->
                    %% Store block
                    oni_block_store:store_block(BlockHash, BlockData),

                    %% Connect to chain
                    Height = get_block_height(BlockHash),
                    {ok, Height};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

validate_block(Block, _State) ->
    %% Basic block validation
    %% - Check proof of work
    %% - Check merkle root
    %% - Check transactions
    %% - Check block weight

    %% Simplified validation for now
    Header = maps:get(header, Block, #{}),
    _Txs = maps:get(transactions, Block, []),

    %% Check PoW
    case verify_proof_of_work(Header) of
        true -> ok;
        false -> {error, invalid_pow}
    end.

verify_proof_of_work(Header) ->
    %% Simplified PoW check
    Bits = maps:get(bits, Header, 0),
    _Nonce = maps:get(nonce, Header, 0),

    %% Would compute hash and compare to target derived from bits
    %% For now, accept all
    Bits > 0.

%% ============================================================================
%% Internal Functions - Utilities
%% ============================================================================

get_current_chain_tip() ->
    %% Get current chain tip from storage
    case oni_chainstate:get_best_block() of
        {ok, Hash, Height} ->
            {Height, Hash};
        _ ->
            {0, genesis_hash()}
    end.

genesis_hash() ->
    %% Mainnet genesis block hash (reversed)
    hex_decode("000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f").

get_sync_peer() ->
    %% Get a peer suitable for syncing
    case oni_peer_manager:get_peers() of
        [] ->
            undefined;
        Peers ->
            %% Pick a random ready peer
            ReadyPeers = [P || P <- Peers, maps:get(ready, P, false) =:= true],
            case ReadyPeers of
                [] -> undefined;
                _ ->
                    Peer = lists:nth(rand:uniform(length(ReadyPeers)), ReadyPeers),
                    maps:get(pid, Peer, undefined)
            end
    end.

build_block_locator(undefined, _Height) ->
    [genesis_hash()];
build_block_locator(Tip, Height) ->
    %% Build locator with exponential backoff
    build_locator_hashes([Tip], Height - 1, 1, 10).

build_locator_hashes(Acc, Height, Step, _MaxHashes) when Height =< 0 ->
    lists:reverse([genesis_hash() | Acc]);
build_locator_hashes(Acc, _Height, _Step, MaxHashes) when length(Acc) >= MaxHashes ->
    lists:reverse([genesis_hash() | Acc]);
build_locator_hashes(Acc, Height, Step, MaxHashes) ->
    case oni_chainstate:get_header_by_height(Height) of
        {ok, Hash} ->
            NewStep = case length(Acc) >= 10 of
                true -> Step * 2;
                false -> Step
            end,
            build_locator_hashes([Hash | Acc], Height - NewStep, NewStep, MaxHashes);
        _ ->
            lists:reverse([genesis_hash() | Acc])
    end.

get_blocks_to_download(FromHeight, ToHeight) when FromHeight > ToHeight ->
    [];
get_blocks_to_download(FromHeight, ToHeight) ->
    lists:filtermap(fun(Height) ->
        case oni_chainstate:get_header_by_height(Height) of
            {ok, Hash} ->
                case oni_block_store:has_block(Hash) of
                    true -> false;
                    false -> {true, Hash}
                end;
            _ ->
                false
        end
    end, lists:seq(FromHeight, ToHeight)).

get_block_height(BlockHash) ->
    case oni_chainstate:get_header_height(BlockHash) of
        {ok, Height} -> Height;
        _ -> 0
    end.

parse_block_hash(<<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary,
                   Timestamp:32/little, Bits:32/little, Nonce:32/little, _Rest/binary>>) ->
    HeaderData = <<Version:32/little, PrevBlock/binary, MerkleRoot/binary,
                   Timestamp:32/little, Bits:32/little, Nonce:32/little>>,
    Hash = crypto:hash(sha256, crypto:hash(sha256, HeaderData)),
    {ok, Hash};
parse_block_hash(_) ->
    {error, invalid_block}.

parse_block(BlockData) ->
    %% Parse full block
    case parse_block_hash(BlockData) of
        {ok, Hash} ->
            <<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary,
              Timestamp:32/little, Bits:32/little, Nonce:32/little, Rest/binary>> = BlockData,

            Header = #{
                version => Version,
                prev_block => PrevBlock,
                merkle_root => MerkleRoot,
                timestamp => Timestamp,
                bits => Bits,
                nonce => Nonce
            },

            %% Parse transactions
            {ok, #{
                hash => Hash,
                header => Header,
                transactions => [],  % Would parse rest
                raw => Rest
            }};
        Error ->
            Error
    end.

log_sync_progress(State) ->
    case State#state.sync_state of
        ?STATE_IDLE ->
            ok;
        ?STATE_SYNCED ->
            ok;
        _ ->
            Uptime = erlang:system_time(second) - State#state.start_time,
            BlocksPerSec = case Uptime of
                0 -> 0;
                _ -> State#state.blocks_downloaded / Uptime
            end,
            MBDownloaded = State#state.bytes_downloaded / 1048576,

            io:format("[oni_sync] Progress: ~p/~p blocks, ~.2f blk/s, ~.2f MB~n",
                      [State#state.validated_height, State#state.header_height,
                       BlocksPerSec, MBDownloaded])
    end.

load_checkpoints(mainnet) ->
    #{
        11111 => hex_decode("0000000069e244f73d78e8fd29ba2fd2ed618bd6fa2ee92559f542fdb26e7c1d"),
        33333 => hex_decode("000000002dd5588a74784eaa7ab0507a18ad16a236e7b1ce69f00d7ddfb5d0a6"),
        74000 => hex_decode("0000000000573993a3c9e41ce34471c079dcf5f52a0e824a81e7f953b8661a20"),
        105000 => hex_decode("00000000000291ce28027faea320c8d2b054b2e0fe44a773f3eefb151d6bdc97"),
        134444 => hex_decode("00000000000005b12ffd4cd315cd34ffd4a594f430ac814c91184a0d42d2b0fe"),
        168000 => hex_decode("000000000000099e61ea72015e79632f216fe6cb33d7899acb35b75c8303b763"),
        193000 => hex_decode("000000000000059f452a5f7340de6682a977387c17010ff6e6c3bd83ca8b1317"),
        210000 => hex_decode("000000000000048b95347e83192f69cf0366076336c639f9b7228e9ba171342e"),
        295000 => hex_decode("00000000000000004d9b4ef50f0f9d686fd69db2e03af35a100370c64632a983"),
        478559 => hex_decode("0000000000000000011865af4122fe3b144e2cbeea86142e8ff2fb4107352d43"),
        556767 => hex_decode("0000000000000000000f1c54590ee18d15ec70e68ae4c3e6bd3b8e7ea9a91abc"),
        700000 => hex_decode("0000000000000000000590fc0f3eba193a278534220b2b37e9849e1a770ca959"),
        800000 => hex_decode("00000000000000000002a7c4c1e48d76c5a37902165a270156b7a8d72728a054")
    };
load_checkpoints(testnet) ->
    #{
        546 => hex_decode("000000002a936ca763904c3c35fce2f3556c559c0214345d31b1bcebf76acb70"),
        100000 => hex_decode("00000000009e2958c15ff9290d571bf9459e93b19765c6801ddeccadbb160a1e"),
        200000 => hex_decode("0000000000287bffd321963ef05feab753ber86da1f8c4ca84e12c28e696fdb0")
    };
load_checkpoints(regtest) ->
    #{};
load_checkpoints(_) ->
    #{}.

hex_encode(Bin) ->
    << <<(integer_to_binary(N, 16))/binary>> || <<N:4>> <= Bin >>.

hex_decode(Hex) when is_list(Hex) ->
    hex_decode(list_to_binary(Hex));
hex_decode(Hex) when is_binary(Hex) ->
    << <<(binary_to_integer(<<H>>, 16)):4>> || <<H:8>> <= Hex >>.
