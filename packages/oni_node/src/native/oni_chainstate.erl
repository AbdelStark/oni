%%% oni_chainstate - Block index and UTXO management
%%%
%%% Provides:
%%% - Block header index with height navigation
%%% - Active chain (best chain) tracking
%%% - UTXO set management
%%% - Reorg handling

-module(oni_chainstate).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    %% Block index
    add_header/2,
    get_header/1,
    get_header_by_height/1,
    get_best_block/0,
    get_chain_height/0,

    %% UTXO operations
    get_utxo/1,
    add_utxos/1,
    spend_utxos/1,

    %% Chain operations
    connect_block/2,
    disconnect_block/1,

    %% Stats
    get_stats/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(header_entry, {
    hash :: binary(),
    header :: map(),
    height :: non_neg_integer(),
    total_work :: non_neg_integer(),
    status :: active | orphan | invalid
}).

-record(utxo, {
    outpoint :: {binary(), non_neg_integer()},  % {txid, vout}
    value :: non_neg_integer(),
    script_pubkey :: binary(),
    height :: non_neg_integer(),
    is_coinbase :: boolean()
}).

-record(state, {
    network :: atom(),
    headers :: ets:tid(),     % BlockHash -> header_entry
    utxos :: ets:tid(),       % {Txid, Vout} -> utxo
    height_index :: ets:tid(), % Height -> [BlockHash]
    best_block :: binary() | undefined,
    chain_height :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Add a block header
-spec add_header(binary(), map()) -> ok | {error, term()}.
add_header(BlockHash, Header) ->
    gen_server:call(?MODULE, {add_header, BlockHash, Header}).

%% Get a header by hash
-spec get_header(binary()) -> {ok, map()} | {error, not_found}.
get_header(BlockHash) ->
    gen_server:call(?MODULE, {get_header, BlockHash}).

%% Get header by height (returns first one if there are forks)
-spec get_header_by_height(non_neg_integer()) -> {ok, binary()} | {error, not_found}.
get_header_by_height(Height) ->
    gen_server:call(?MODULE, {get_header_by_height, Height}).

%% Get the best (tip) block hash
-spec get_best_block() -> {ok, binary()} | {error, no_blocks}.
get_best_block() ->
    gen_server:call(?MODULE, get_best_block).

%% Get current chain height
-spec get_chain_height() -> non_neg_integer().
get_chain_height() ->
    gen_server:call(?MODULE, get_chain_height).

%% Get a UTXO
-spec get_utxo({binary(), non_neg_integer()}) -> {ok, #utxo{}} | {error, not_found}.
get_utxo(Outpoint) ->
    gen_server:call(?MODULE, {get_utxo, Outpoint}).

%% Add UTXOs from a block's outputs
-spec add_utxos([{binary(), non_neg_integer(), non_neg_integer(), binary(), boolean()}]) -> ok.
add_utxos(Utxos) ->
    gen_server:call(?MODULE, {add_utxos, Utxos}).

%% Spend UTXOs (remove from set)
-spec spend_utxos([{binary(), non_neg_integer()}]) -> ok | {error, term()}.
spend_utxos(Outpoints) ->
    gen_server:call(?MODULE, {spend_utxos, Outpoints}).

%% Connect a block to the active chain
-spec connect_block(binary(), map()) -> ok | {error, term()}.
connect_block(BlockHash, Block) ->
    gen_server:call(?MODULE, {connect_block, BlockHash, Block}, 30000).

%% Disconnect the tip block (for reorgs)
-spec disconnect_block(binary()) -> ok | {error, term()}.
disconnect_block(BlockHash) ->
    gen_server:call(?MODULE, {disconnect_block, BlockHash}).

%% Get chainstate statistics
-spec get_stats() -> map().
get_stats() ->
    gen_server:call(?MODULE, get_stats).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Config) ->
    Network = maps:get(network, Config, mainnet),

    %% Create ETS tables
    Headers = ets:new(headers, [set, {keypos, 2}]),
    Utxos = ets:new(utxos, [set, {keypos, 2}]),
    HeightIndex = ets:new(height_index, [bag]),

    %% Initialize with genesis block
    GenesisHash = genesis_hash(Network),
    GenesisHeader = genesis_header(Network),

    GenesisEntry = #header_entry{
        hash = GenesisHash,
        header = GenesisHeader,
        height = 0,
        total_work = 1,  % Simplified
        status = active
    },
    ets:insert(Headers, GenesisEntry),
    ets:insert(HeightIndex, {0, GenesisHash}),

    State = #state{
        network = Network,
        headers = Headers,
        utxos = Utxos,
        height_index = HeightIndex,
        best_block = GenesisHash,
        chain_height = 0
    },

    io:format("[oni_chainstate] Initialized for ~p, genesis=~s~n",
              [Network, hex_encode(GenesisHash)]),
    {ok, State}.

handle_call({add_header, BlockHash, Header}, _From, State) ->
    %% Get parent height
    PrevHash = maps:get(prev_block, Header),
    Height = case ets:lookup(State#state.headers, PrevHash) of
        [#header_entry{height = PH}] -> PH + 1;
        [] -> 0  % Genesis or orphan
    end,

    Entry = #header_entry{
        hash = BlockHash,
        header = Header,
        height = Height,
        total_work = Height + 1,  % Simplified work calculation
        status = orphan
    },
    ets:insert(State#state.headers, Entry),
    ets:insert(State#state.height_index, {Height, BlockHash}),

    {reply, ok, State};

handle_call({get_header, BlockHash}, _From, State) ->
    Result = case ets:lookup(State#state.headers, BlockHash) of
        [#header_entry{header = H}] -> {ok, H};
        [] -> {error, not_found}
    end,
    {reply, Result, State};

handle_call({get_header_by_height, Height}, _From, State) ->
    Result = case ets:lookup(State#state.height_index, Height) of
        [{_, Hash} | _] -> {ok, Hash};
        [] -> {error, not_found}
    end,
    {reply, Result, State};

handle_call(get_best_block, _From, State) ->
    Result = case State#state.best_block of
        undefined -> {error, no_blocks};
        Hash -> {ok, Hash}
    end,
    {reply, Result, State};

handle_call(get_chain_height, _From, State) ->
    {reply, State#state.chain_height, State};

handle_call({get_utxo, Outpoint}, _From, State) ->
    Result = case ets:lookup(State#state.utxos, Outpoint) of
        [Utxo] -> {ok, Utxo};
        [] -> {error, not_found}
    end,
    {reply, Result, State};

handle_call({add_utxos, Utxos}, _From, State) ->
    lists:foreach(fun({Txid, Vout, Value, Script, IsCoinbase}) ->
        Height = State#state.chain_height,
        Utxo = #utxo{
            outpoint = {Txid, Vout},
            value = Value,
            script_pubkey = Script,
            height = Height,
            is_coinbase = IsCoinbase
        },
        ets:insert(State#state.utxos, Utxo)
    end, Utxos),
    {reply, ok, State};

handle_call({spend_utxos, Outpoints}, _From, State) ->
    lists:foreach(fun(Outpoint) ->
        ets:delete(State#state.utxos, Outpoint)
    end, Outpoints),
    {reply, ok, State};

handle_call({connect_block, BlockHash, _Block}, _From, State) ->
    %% Update the active chain
    case ets:lookup(State#state.headers, BlockHash) of
        [Entry] ->
            UpdatedEntry = Entry#header_entry{status = active},
            ets:insert(State#state.headers, UpdatedEntry),
            NewState = State#state{
                best_block = BlockHash,
                chain_height = Entry#header_entry.height
            },
            {reply, ok, NewState};
        [] ->
            {reply, {error, header_not_found}, State}
    end;

handle_call({disconnect_block, BlockHash}, _From, State) ->
    case ets:lookup(State#state.headers, BlockHash) of
        [Entry] ->
            UpdatedEntry = Entry#header_entry{status = orphan},
            ets:insert(State#state.headers, UpdatedEntry),
            %% Find the new best block (parent)
            PrevHash = maps:get(prev_block, Entry#header_entry.header, undefined),
            NewState = State#state{
                best_block = PrevHash,
                chain_height = Entry#header_entry.height - 1
            },
            {reply, ok, NewState};
        [] ->
            {reply, {error, header_not_found}, State}
    end;

handle_call(get_stats, _From, State) ->
    Stats = #{
        network => State#state.network,
        chain_height => State#state.chain_height,
        best_block => hex_encode(State#state.best_block),
        headers_count => ets:info(State#state.headers, size),
        utxo_count => ets:info(State#state.utxos, size)
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

genesis_hash(mainnet) ->
    hex_decode("000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f");
genesis_hash(testnet) ->
    hex_decode("000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943");
genesis_hash(regtest) ->
    hex_decode("0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206");
genesis_hash(_) ->
    genesis_hash(mainnet).

genesis_header(Network) ->
    %% Simplified genesis header
    #{
        version => 1,
        prev_block => <<0:256>>,
        merkle_root => genesis_merkle_root(Network),
        timestamp => genesis_timestamp(Network),
        bits => genesis_bits(Network),
        nonce => genesis_nonce(Network)
    }.

genesis_merkle_root(_) ->
    hex_decode("4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b").

genesis_timestamp(mainnet) -> 1231006505;
genesis_timestamp(testnet) -> 1296688602;
genesis_timestamp(regtest) -> 1296688602;
genesis_timestamp(_) -> 1231006505.

genesis_bits(mainnet) -> 16#1d00ffff;
genesis_bits(testnet) -> 16#1d00ffff;
genesis_bits(regtest) -> 16#207fffff;
genesis_bits(_) -> 16#1d00ffff.

genesis_nonce(mainnet) -> 2083236893;
genesis_nonce(testnet) -> 414098458;
genesis_nonce(regtest) -> 2;
genesis_nonce(_) -> 2083236893.

hex_encode(<<>>) -> "";
hex_encode(Bin) when is_binary(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X:8>> <= Bin]).

hex_decode(Hex) when is_list(Hex) ->
    << <<(list_to_integer([H, L], 16)):8>> || [H, L] <- pairs(Hex) >>.

pairs([]) -> [];
pairs([H, L | Rest]) -> [[H, L] | pairs(Rest)].
