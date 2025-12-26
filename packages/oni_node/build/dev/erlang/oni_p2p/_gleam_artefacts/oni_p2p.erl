-module(oni_p2p).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/oni_p2p.gleam").
-export([peer_id/1]).
-export_type([peer_id/0]).

-type peer_id() :: {peer_id, binary()}.

-file("src/oni_p2p.gleam", 13).
-spec peer_id(binary()) -> peer_id().
peer_id(Name) ->
    {peer_id, Name}.
