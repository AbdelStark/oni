%%% oni_health_server - Health monitoring and metrics
%%%
%%% Provides:
%%% - Liveness and readiness checks
%%% - Component health status
%%% - Basic metrics aggregation

-module(oni_health_server).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    get_health/0,
    is_healthy/0,
    is_ready/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    start_time :: non_neg_integer(),
    check_interval :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Get full health status
-spec get_health() -> map().
get_health() ->
    gen_server:call(?MODULE, get_health).

%% Check if node is alive (for liveness probe)
-spec is_healthy() -> boolean().
is_healthy() ->
    gen_server:call(?MODULE, is_healthy).

%% Check if node is ready to serve requests (for readiness probe)
-spec is_ready() -> boolean().
is_ready() ->
    gen_server:call(?MODULE, is_ready).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(_Config) ->
    State = #state{
        start_time = erlang:system_time(second),
        check_interval = 30000
    },

    %% Schedule periodic health checks
    erlang:send_after(State#state.check_interval, self(), check_health),

    io:format("[oni_health_server] Initialized~n"),
    {ok, State}.

handle_call(get_health, _From, State) ->
    Health = collect_health(State),
    {reply, Health, State};

handle_call(is_healthy, _From, State) ->
    %% Node is healthy if it can respond
    {reply, true, State};

handle_call(is_ready, _From, State) ->
    %% Node is ready if sync is complete (or close enough)
    Ready = case catch oni_sync_server:is_synced() of
        true -> true;
        _ -> true  % Consider ready even during IBD for now
    end,
    {reply, Ready, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_health, State) ->
    %% Perform periodic health check
    _Health = collect_health(State),
    %% Could log warnings here if components are unhealthy

    %% Schedule next check
    erlang:send_after(State#state.check_interval, self(), check_health),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

collect_health(State) ->
    Uptime = erlang:system_time(second) - State#state.start_time,

    %% Collect component statuses
    Components = [
        {chainstate, check_component(oni_chainstate)},
        {block_store, check_component(oni_block_store)},
        {peer_manager, check_component(oni_peer_manager)},
        {mempool, check_component(oni_mempool_server)},
        {rpc, check_component(oni_rpc_server)},
        {sync, check_component(oni_sync_server)}
    ],

    %% Overall status
    AllHealthy = lists:all(fun({_, Status}) -> Status =:= healthy end, Components),

    #{
        status => case AllHealthy of true -> healthy; false -> degraded end,
        uptime => Uptime,
        components => maps:from_list(Components),
        memory => erlang:memory(total),
        process_count => erlang:system_info(process_count),
        version => <<"0.1.0">>
    }.

check_component(Name) ->
    case whereis(Name) of
        undefined -> unhealthy;
        Pid when is_pid(Pid) ->
            case erlang:is_process_alive(Pid) of
                true -> healthy;
                false -> unhealthy
            end
    end.
