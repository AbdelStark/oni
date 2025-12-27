%%% oni_p2p_sup - P2P networking subsystem supervisor
%%%
%%% Manages:
%%% - oni_peer_manager: Peer lifecycle and connection management
%%% - oni_addr_manager: Address book for peer discovery
%%% - oni_listener: TCP listener for inbound connections
%%% - oni_conn_sup: Dynamic supervisor for peer connections

-module(oni_p2p_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

init(Config) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },

    %% Address manager - knows about peer addresses
    AddrManager = #{
        id => oni_addr_manager,
        start => {oni_addr_manager, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    %% Dynamic supervisor for peer connections
    ConnSup = #{
        id => oni_conn_sup,
        start => {oni_conn_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    },

    %% Peer manager - coordinates connections
    PeerManager = #{
        id => oni_peer_manager,
        start => {oni_peer_manager, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    %% TCP listener for inbound connections
    Listener = #{
        id => oni_listener,
        start => {oni_listener, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    ChildSpecs = [AddrManager, ConnSup, PeerManager, Listener],
    {ok, {SupFlags, ChildSpecs}}.
