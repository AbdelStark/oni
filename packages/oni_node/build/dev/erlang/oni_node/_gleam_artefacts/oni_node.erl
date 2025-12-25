-module(oni_node).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/oni_node.gleam").
-export([default_config/0, user_agent/0, main/0]).
-export_type([node_config/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type node_config() :: {node_config,
        oni_bitcoin:network(),
        binary(),
        integer(),
        integer(),
        integer()}.

-file("src/oni_node.gleam", 27).
?DOC(" Default node configuration for mainnet\n").
-spec default_config() -> node_config().
default_config() ->
    {node_config, mainnet, <<"~/.oni"/utf8>>, 8332, 8333, 125}.

-file("src/oni_node.gleam", 102).
-spec do_int_to_string(integer(), binary()) -> binary().
do_int_to_string(N, Acc) ->
    case N of
        0 ->
            Acc;

        _ ->
            Digit = N rem 10,
            Char = case Digit of
                0 ->
                    <<"0"/utf8>>;

                1 ->
                    <<"1"/utf8>>;

                2 ->
                    <<"2"/utf8>>;

                3 ->
                    <<"3"/utf8>>;

                4 ->
                    <<"4"/utf8>>;

                5 ->
                    <<"5"/utf8>>;

                6 ->
                    <<"6"/utf8>>;

                7 ->
                    <<"7"/utf8>>;

                8 ->
                    <<"8"/utf8>>;

                _ ->
                    <<"9"/utf8>>
            end,
            do_int_to_string(N div 10, <<Char/binary, Acc/binary>>)
    end.

-file("src/oni_node.gleam", 95).
?DOC(" Convert integer to string\n").
-spec int_to_string(integer()) -> binary().
int_to_string(N) ->
    case N of
        0 ->
            <<"0"/utf8>>;

        _ ->
            do_int_to_string(N, <<""/utf8>>)
    end.

-file("src/oni_node.gleam", 41).
?DOC(" Node user agent string\n").
-spec user_agent() -> binary().
user_agent() ->
    <<<<"/oni:"/utf8, "0.1.0"/utf8>>/binary, "/"/utf8>>.

-file("src/oni_node.gleam", 46).
?DOC(" Main entry point\n").
-spec main() -> nil.
main() ->
    gleam@io:println(
        <<"╔═══════════════════════════════════════════════════════════════╗"/utf8>>
    ),
    gleam@io:println(
        <<"║                                                               ║"/utf8>>
    ),
    gleam@io:println(
        <<"║    ██████╗ ███╗   ██╗██╗                                      ║"/utf8>>
    ),
    gleam@io:println(
        <<"║   ██╔═══██╗████╗  ██║██║                                      ║"/utf8>>
    ),
    gleam@io:println(
        <<"║   ██║   ██║██╔██╗ ██║██║                                      ║"/utf8>>
    ),
    gleam@io:println(
        <<"║   ██║   ██║██║╚██╗██║██║                                      ║"/utf8>>
    ),
    gleam@io:println(
        <<"║   ╚██████╔╝██║ ╚████║██║                                      ║"/utf8>>
    ),
    gleam@io:println(
        <<"║    ╚═════╝ ╚═╝  ╚═══╝╚═╝                                      ║"/utf8>>
    ),
    gleam@io:println(
        <<"║                                                               ║"/utf8>>
    ),
    gleam@io:println(
        <<"║   A Bitcoin Full Node Implementation in Gleam                 ║"/utf8>>
    ),
    gleam@io:println(
        <<<<"║   Version: "/utf8, "0.1.0"/utf8>>/binary,
            "                                              ║"/utf8>>
    ),
    gleam@io:println(
        <<"║                                                               ║"/utf8>>
    ),
    gleam@io:println(
        <<"╚═══════════════════════════════════════════════════════════════╝"/utf8>>
    ),
    gleam@io:println(<<""/utf8>>),
    Config = default_config(),
    Params = oni_bitcoin:mainnet_params(),
    gleam@io:println(<<"Network: Mainnet"/utf8>>),
    gleam@io:println(
        <<"Genesis: "/utf8,
            (oni_bitcoin:block_hash_to_hex(erlang:element(7, Params)))/binary>>
    ),
    gleam@io:println(
        <<"P2P Port: "/utf8, (int_to_string(erlang:element(5, Config)))/binary>>
    ),
    gleam@io:println(
        <<"RPC Port: "/utf8, (int_to_string(erlang:element(4, Config)))/binary>>
    ),
    gleam@io:println(<<"User Agent: "/utf8, (user_agent())/binary>>),
    gleam@io:println(<<""/utf8>>),
    gleam@io:println(<<"Subsystems:"/utf8>>),
    gleam@io:println(
        <<"  ✓ oni_bitcoin  - Bitcoin primitives and codecs"/utf8>>
    ),
    gleam@io:println(
        <<"  ✓ oni_consensus - Validation and script engine"/utf8>>
    ),
    gleam@io:println(<<"  ✓ oni_storage   - Block store and chainstate"/utf8>>),
    gleam@io:println(<<"  ✓ oni_p2p       - P2P networking layer"/utf8>>),
    gleam@io:println(<<"  ✓ oni_rpc       - JSON-RPC interface"/utf8>>),
    gleam@io:println(<<""/utf8>>),
    gleam@io:println(<<"Consensus Parameters:"/utf8>>),
    gleam@io:println(
        <<<<"  Max Block Weight:     "/utf8, (int_to_string(4000000))/binary>>/binary,
            " WU"/utf8>>
    ),
    gleam@io:println(
        <<<<"  Max Script Size:      "/utf8, (int_to_string(10000))/binary>>/binary,
            " bytes"/utf8>>
    ),
    gleam@io:println(
        <<"  Max Ops Per Script:   "/utf8, (int_to_string(201))/binary>>
    ),
    gleam@io:println(
        <<<<"  Coinbase Maturity:    "/utf8, (int_to_string(100))/binary>>/binary,
            " blocks"/utf8>>
    ),
    gleam@io:println(<<""/utf8>>),
    gleam@io:println(<<"oni node initialized successfully!"/utf8>>),
    gleam@io:println(
        <<"(This is a development scaffold - full node functionality coming soon)"/utf8>>
    ).
