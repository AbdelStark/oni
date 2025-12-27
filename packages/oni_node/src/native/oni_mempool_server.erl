%%% oni_mempool_server - Transaction pool management
%%%
%%% Manages unconfirmed transactions awaiting inclusion in blocks.

-module(oni_mempool_server).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    submit_tx/1,
    get_tx/1,
    remove_tx/1,
    get_all_txids/0,
    get_mempool_info/0,
    clear/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(mempool_entry, {
    txid :: binary(),
    tx_data :: binary(),
    fee :: non_neg_integer(),
    size :: non_neg_integer(),
    time :: non_neg_integer()
}).

-record(state, {
    txs :: ets:tid(),
    max_size :: non_neg_integer(),
    min_relay_fee :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Submit a transaction to the mempool
-spec submit_tx(binary()) -> ok | {error, term()}.
submit_tx(TxData) ->
    gen_server:call(?MODULE, {submit_tx, TxData}).

%% Get a transaction by txid
-spec get_tx(binary()) -> {ok, binary()} | {error, not_found}.
get_tx(Txid) ->
    gen_server:call(?MODULE, {get_tx, Txid}).

%% Remove a transaction (e.g., after confirmation)
-spec remove_tx(binary()) -> ok.
remove_tx(Txid) ->
    gen_server:cast(?MODULE, {remove_tx, Txid}).

%% Get all transaction IDs in the mempool
-spec get_all_txids() -> [binary()].
get_all_txids() ->
    gen_server:call(?MODULE, get_all_txids).

%% Get mempool statistics
-spec get_mempool_info() -> map().
get_mempool_info() ->
    gen_server:call(?MODULE, get_mempool_info).

%% Clear the mempool
-spec clear() -> ok.
clear() ->
    gen_server:call(?MODULE, clear).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Config) ->
    MaxSize = maps:get(mempool_max_size, Config, 300 * 1024 * 1024),  % 300 MB
    MinRelayFee = maps:get(mempool_min_relay_fee, Config, 1000),  % 1 sat/vB

    Txs = ets:new(mempool_txs, [set, {keypos, 2}]),

    State = #state{
        txs = Txs,
        max_size = MaxSize,
        min_relay_fee = MinRelayFee
    },

    io:format("[oni_mempool_server] Initialized (max_size=~pMB, min_fee=~p sat/vB)~n",
              [MaxSize div (1024 * 1024), MinRelayFee]),
    {ok, State}.

handle_call({submit_tx, TxData}, _From, State) ->
    %% Calculate txid (double SHA256 of tx data)
    Txid = crypto:hash(sha256, crypto:hash(sha256, TxData)),

    %% Check if already in mempool
    case ets:lookup(State#state.txs, Txid) of
        [_] ->
            {reply, {error, already_in_mempool}, State};
        [] ->
            %% Create entry (simplified - no fee calculation)
            Entry = #mempool_entry{
                txid = Txid,
                tx_data = TxData,
                fee = 0,
                size = byte_size(TxData),
                time = erlang:system_time(second)
            },
            ets:insert(State#state.txs, Entry),
            {reply, ok, State}
    end;

handle_call({get_tx, Txid}, _From, State) ->
    Result = case ets:lookup(State#state.txs, Txid) of
        [Entry] -> {ok, Entry#mempool_entry.tx_data};
        [] -> {error, not_found}
    end,
    {reply, Result, State};

handle_call(get_all_txids, _From, State) ->
    Txids = [E#mempool_entry.txid || E <- ets:tab2list(State#state.txs)],
    {reply, Txids, State};

handle_call(get_mempool_info, _From, State) ->
    Entries = ets:tab2list(State#state.txs),
    TotalSize = lists:sum([E#mempool_entry.size || E <- Entries]),
    TotalFees = lists:sum([E#mempool_entry.fee || E <- Entries]),

    Info = #{
        size => length(Entries),
        bytes => TotalSize,
        total_fee => TotalFees,
        max_size => State#state.max_size,
        min_relay_fee => State#state.min_relay_fee
    },
    {reply, Info, State};

handle_call(clear, _From, State) ->
    ets:delete_all_objects(State#state.txs),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({remove_tx, Txid}, State) ->
    ets:delete(State#state.txs, Txid),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
