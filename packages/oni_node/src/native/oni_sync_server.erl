%%% oni_sync_server - Block synchronization coordinator
%%%
%%% Coordinates Initial Block Download (IBD) and steady-state sync.

-module(oni_sync_server).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    get_status/0,
    is_synced/0,
    request_blocks/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    config :: map(),
    mode :: ibd | steady | synced,
    target_height :: non_neg_integer(),
    synced_height :: non_neg_integer(),
    pending_headers :: non_neg_integer(),
    pending_blocks :: non_neg_integer(),
    start_time :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Get sync status
-spec get_status() -> map().
get_status() ->
    gen_server:call(?MODULE, get_status).

%% Check if node is synced
-spec is_synced() -> boolean().
is_synced() ->
    gen_server:call(?MODULE, is_synced).

%% Request specific blocks from peers
-spec request_blocks(pid(), [binary()]) -> ok.
request_blocks(Peer, BlockHashes) ->
    gen_server:cast(?MODULE, {request_blocks, Peer, BlockHashes}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Config) ->
    State = #state{
        config = Config,
        mode = ibd,
        target_height = 0,
        synced_height = 0,
        pending_headers = 0,
        pending_blocks = 0,
        start_time = erlang:system_time(second)
    },

    %% Schedule sync progress check
    erlang:send_after(5000, self(), check_progress),

    io:format("[oni_sync_server] Initialized in IBD mode~n"),
    {ok, State}.

handle_call(get_status, _From, State) ->
    Status = #{
        mode => State#state.mode,
        target_height => State#state.target_height,
        synced_height => State#state.synced_height,
        pending_headers => State#state.pending_headers,
        pending_blocks => State#state.pending_blocks,
        progress => calculate_progress(State),
        uptime => erlang:system_time(second) - State#state.start_time
    },
    {reply, Status, State};

handle_call(is_synced, _From, State) ->
    {reply, State#state.mode =:= synced, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({request_blocks, Peer, BlockHashes}, State) ->
    %% Send getdata for blocks
    Items = [{2, Hash} || Hash <- BlockHashes],  % 2 = MSG_BLOCK
    oni_peer:send_message(Peer, {getdata, Items}),
    NewState = State#state{
        pending_blocks = State#state.pending_blocks + length(BlockHashes)
    },
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_progress, State) ->
    %% Check current chain height
    CurrentHeight = oni_chainstate:get_chain_height(),

    %% Update state
    NewState = case State#state.mode of
        ibd when CurrentHeight >= State#state.target_height andalso
                 State#state.target_height > 0 ->
            io:format("[oni_sync_server] IBD complete, switching to steady state~n"),
            State#state{
                mode = steady,
                synced_height = CurrentHeight
            };
        _ ->
            State#state{synced_height = CurrentHeight}
    end,

    %% Log progress periodically
    case CurrentHeight rem 1000 of
        0 when CurrentHeight > 0 ->
            io:format("[oni_sync_server] Synced to height ~p~n", [CurrentHeight]);
        _ ->
            ok
    end,

    %% Schedule next check
    erlang:send_after(10000, self(), check_progress),
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

calculate_progress(State) ->
    case State#state.target_height of
        0 -> 0.0;
        Target ->
            min(100.0, (State#state.synced_height / Target) * 100)
    end.
