%%% oni_storage_sup - Storage subsystem supervisor
%%%
%%% Manages:
%%% - oni_chainstate: Block index, UTXO set, and active chain tracking
%%% - oni_block_store: Raw block storage and retrieval

-module(oni_storage_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

init(Config) ->
    %% Use rest_for_one strategy: if chainstate dies, block_store continues
    %% but if block_store dies, restart chainstate too
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 60
    },

    %% Block store - raw block data persistence
    BlockStore = #{
        id => oni_block_store,
        start => {oni_block_store, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    %% Chainstate - block index and UTXO management
    Chainstate = #{
        id => oni_chainstate,
        start => {oni_chainstate, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    ChildSpecs = [BlockStore, Chainstate],
    {ok, {SupFlags, ChildSpecs}}.
