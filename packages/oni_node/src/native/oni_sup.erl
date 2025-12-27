%%% oni_sup - Main supervisor for the oni Bitcoin node
%%%
%%% Supervision tree structure:
%%%
%%% oni_sup (one_for_one)
%%%   ├── oni_storage_sup (rest_for_one)
%%%   │     ├── oni_chainstate - Block index and UTXO management
%%%   │     └── oni_block_store - Raw block storage
%%%   ├── oni_p2p_sup (one_for_one)
%%%   │     ├── oni_peer_manager - Peer lifecycle management
%%%   │     ├── oni_addr_manager - Address book
%%%   │     └── oni_conn_sup (simple_one_for_one) - Per-peer connections
%%%   ├── oni_sync - Block download coordinator
%%%   ├── oni_mempool - Transaction pool
%%%   └── oni_rpc_server - JSON-RPC interface

-module(oni_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

%% ============================================================================
%% Supervisor callbacks
%% ============================================================================

init(Config) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },

    %% Storage subsystem
    StorageSup = #{
        id => oni_storage_sup,
        start => {oni_storage_sup, start_link, [Config]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    },

    %% P2P networking subsystem
    P2PSup = #{
        id => oni_p2p_sup,
        start => {oni_p2p_sup, start_link, [Config]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    },

    %% Sync coordinator (IBD and steady-state sync)
    Sync = #{
        id => oni_sync,
        start => {oni_sync, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    %% Mempool
    Mempool = #{
        id => oni_mempool,
        start => {oni_mempool_server, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    %% RPC server
    RPC = #{
        id => oni_rpc_server,
        start => {oni_rpc_server, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    %% Health monitor
    Health = #{
        id => oni_health,
        start => {oni_health_server, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    ChildSpecs = [StorageSup, P2PSup, Sync, Mempool, RPC, Health],
    {ok, {SupFlags, ChildSpecs}}.
