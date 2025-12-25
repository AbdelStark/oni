-module(oni_rpc).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/oni_rpc.gleam").
-export([hello/0]).
-export_type([rpc_error/0]).

-type rpc_error() :: unauthorized |
    invalid_request |
    method_not_found |
    {internal, binary()}.

-file("src/oni_rpc.gleam", 15).
-spec hello() -> binary().
hello() ->
    <<"oni_rpc (scaffold)"/utf8>>.
