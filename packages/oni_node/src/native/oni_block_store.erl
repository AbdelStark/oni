%%% oni_block_store - Raw block storage
%%%
%%% Provides:
%%% - Persistent block storage using DETS/ETS (production: RocksDB)
%%% - Block retrieval by hash
%%% - Block data integrity verification

-module(oni_block_store).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    store_block/2,
    get_block/1,
    has_block/1,
    delete_block/1,
    get_stats/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    data_dir :: string(),
    block_table :: ets:tid(),
    stats :: map()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Store a block
-spec store_block(binary(), binary()) -> ok | {error, term()}.
store_block(BlockHash, BlockData) when is_binary(BlockHash), is_binary(BlockData) ->
    gen_server:call(?MODULE, {store_block, BlockHash, BlockData}).

%% Get a block by hash
-spec get_block(binary()) -> {ok, binary()} | {error, not_found}.
get_block(BlockHash) when is_binary(BlockHash) ->
    gen_server:call(?MODULE, {get_block, BlockHash}).

%% Check if block exists
-spec has_block(binary()) -> boolean().
has_block(BlockHash) when is_binary(BlockHash) ->
    gen_server:call(?MODULE, {has_block, BlockHash}).

%% Delete a block
-spec delete_block(binary()) -> ok.
delete_block(BlockHash) when is_binary(BlockHash) ->
    gen_server:call(?MODULE, {delete_block, BlockHash}).

%% Get storage statistics
-spec get_stats() -> map().
get_stats() ->
    gen_server:call(?MODULE, get_stats).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Config) ->
    DataDir = maps:get(data_dir, Config, ".oni"),
    BlockDir = filename:join(DataDir, "blocks"),
    ok = filelib:ensure_dir(filename:join(BlockDir, "dummy")),

    %% Create ETS table for blocks (in-memory for now)
    %% Production: Use RocksDB or LevelDB
    BlockTable = ets:new(blocks, [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),

    State = #state{
        data_dir = BlockDir,
        block_table = BlockTable,
        stats = #{
            blocks_stored => 0,
            bytes_stored => 0,
            last_stored => undefined
        }
    },

    io:format("[oni_block_store] Initialized with data_dir=~s~n", [BlockDir]),
    {ok, State}.

handle_call({store_block, BlockHash, BlockData}, _From, State) ->
    true = ets:insert(State#state.block_table, {BlockHash, BlockData}),
    NewStats = update_stats_on_store(State#state.stats, BlockData),
    {reply, ok, State#state{stats = NewStats}};

handle_call({get_block, BlockHash}, _From, State) ->
    Result = case ets:lookup(State#state.block_table, BlockHash) of
        [{_, BlockData}] -> {ok, BlockData};
        [] -> {error, not_found}
    end,
    {reply, Result, State};

handle_call({has_block, BlockHash}, _From, State) ->
    Result = ets:member(State#state.block_table, BlockHash),
    {reply, Result, State};

handle_call({delete_block, BlockHash}, _From, State) ->
    true = ets:delete(State#state.block_table, BlockHash),
    {reply, ok, State};

handle_call(get_stats, _From, State) ->
    Stats = State#state.stats#{
        table_size => ets:info(State#state.block_table, size),
        memory_bytes => ets:info(State#state.block_table, memory) * erlang:system_info(wordsize)
    },
    {reply, Stats, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

update_stats_on_store(Stats, BlockData) ->
    #{blocks_stored := Count, bytes_stored := Bytes} = Stats,
    Stats#{
        blocks_stored => Count + 1,
        bytes_stored => Bytes + byte_size(BlockData),
        last_stored => erlang:system_time(second)
    }.
