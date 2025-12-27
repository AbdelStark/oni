%%% oni_conn_sup - Dynamic supervisor for peer connections
%%%
%%% Manages individual peer connection processes (oni_peer).
%%% Uses simple_one_for_one strategy for dynamic child creation.

-module(oni_conn_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([start_peer/2, stop_peer/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Start a new peer connection
-spec start_peer(inet:ip_address(), inet:port_number()) -> {ok, pid()} | {error, term()}.
start_peer(IpAddr, Port) ->
    supervisor:start_child(?MODULE, [IpAddr, Port]).

%% Stop a peer connection
-spec stop_peer(pid()) -> ok.
stop_peer(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 60
    },

    ChildSpec = #{
        id => oni_peer,
        start => {oni_peer, start_link, []},
        restart => temporary,  % Don't restart failed peer connections
        shutdown => 5000,
        type => worker
    },

    {ok, {SupFlags, [ChildSpec]}}.
