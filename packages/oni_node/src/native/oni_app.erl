%%% oni_app - OTP Application behaviour implementation
%%%
%%% This is the main entry point for the oni Bitcoin node.
%%% It starts the supervision tree which manages:
%%% - Storage subsystem (chainstate, block store)
%%% - P2P network manager (peer connections, message handling)
%%% - RPC server (JSON-RPC interface)
%%% - Mempool (transaction pool)
%%% - Sync coordinator (IBD and steady-state sync)

-module(oni_app).
-behaviour(application).

-export([start/2, stop/1]).

%% ============================================================================
%% Application callbacks
%% ============================================================================

start(_StartType, _StartArgs) ->
    io:format("~n"),
    io:format("╔═══════════════════════════════════════════════════════════════╗~n"),
    io:format("║                                                               ║~n"),
    io:format("║    ██████╗ ███╗   ██╗██╗                                      ║~n"),
    io:format("║   ██╔═══██╗████╗  ██║██║                                      ║~n"),
    io:format("║   ██║   ██║██╔██╗ ██║██║                                      ║~n"),
    io:format("║   ██║   ██║██║╚██╗██║██║                                      ║~n"),
    io:format("║   ╚██████╔╝██║ ╚████║██║                                      ║~n"),
    io:format("║    ╚═════╝ ╚═╝  ╚═══╝╚═╝                                      ║~n"),
    io:format("║                                                               ║~n"),
    io:format("║   A Bitcoin Full Node Implementation                         ║~n"),
    io:format("║   Version: 0.1.0                                              ║~n"),
    io:format("║                                                               ║~n"),
    io:format("╚═══════════════════════════════════════════════════════════════╝~n"),
    io:format("~n"),

    %% Get configuration from environment or defaults
    Config = get_config(),
    io:format("[oni] Starting with config: ~p~n", [Config]),

    %% Start the main supervisor
    case oni_sup:start_link(Config) of
        {ok, Pid} ->
            io:format("[oni] Node started successfully~n"),
            io:format("[oni] P2P port: ~p~n", [maps:get(p2p_port, Config)]),
            io:format("[oni] RPC port: ~p~n", [maps:get(rpc_port, Config)]),
            {ok, Pid};
        {error, Reason} ->
            io:format("[oni] Failed to start: ~p~n", [Reason]),
            {error, Reason}
    end.

stop(_State) ->
    io:format("[oni] Node stopping...~n"),
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

get_config() ->
    %% Read configuration from environment or use defaults
    Network = application:get_env(oni_node, network, mainnet),
    DataDir = application:get_env(oni_node, data_dir, "~/.oni"),
    P2PPort = application:get_env(oni_node, p2p_port, default_p2p_port(Network)),
    RPCPort = application:get_env(oni_node, rpc_port, default_rpc_port(Network)),
    MaxConnections = application:get_env(oni_node, max_connections, 125),
    RPCUser = application:get_env(oni_node, rpc_user, undefined),
    RPCPassword = application:get_env(oni_node, rpc_password, undefined),

    #{
        network => Network,
        data_dir => expand_path(DataDir),
        p2p_port => P2PPort,
        rpc_port => RPCPort,
        max_connections => MaxConnections,
        rpc_user => RPCUser,
        rpc_password => RPCPassword,
        dns_seeds => dns_seeds(Network)
    }.

default_p2p_port(mainnet) -> 8333;
default_p2p_port(testnet) -> 18333;
default_p2p_port(regtest) -> 18444;
default_p2p_port(signet) -> 38333;
default_p2p_port(_) -> 8333.

default_rpc_port(mainnet) -> 8332;
default_rpc_port(testnet) -> 18332;
default_rpc_port(regtest) -> 18443;
default_rpc_port(signet) -> 38332;
default_rpc_port(_) -> 8332.

expand_path(Path) when is_list(Path) ->
    case string:prefix(Path, "~/") of
        nomatch -> Path;
        Rest ->
            Home = os:getenv("HOME", "/tmp"),
            filename:join(Home, Rest)
    end;
expand_path(Path) when is_binary(Path) ->
    list_to_binary(expand_path(binary_to_list(Path))).

%% DNS seeds for peer discovery
dns_seeds(mainnet) ->
    [
        "seed.bitcoin.sipa.be",
        "dnsseed.bluematt.me",
        "dnsseed.bitcoin.dashjr-list-of-hierarchical-prefix.org",
        "seed.bitcoinstats.com",
        "seed.bitcoin.jonasschnelli.ch",
        "seed.btc.petertodd.org",
        "seed.bitcoin.sprovoost.nl",
        "dnsseed.emzy.de",
        "seed.bitcoin.wiz.biz"
    ];
dns_seeds(testnet) ->
    [
        "testnet-seed.bitcoin.jonasschnelli.ch",
        "seed.tbtc.petertodd.org",
        "testnet-seed.bluematt.me"
    ];
dns_seeds(signet) ->
    [
        "seed.signet.bitcoin.sprovoost.nl"
    ];
dns_seeds(_) ->
    [].
