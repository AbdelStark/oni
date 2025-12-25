-module(oni_p2p_test).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "test/oni_p2p_test.gleam").
-export([main/0, peer_id_test/0]).

-file("test/oni_p2p_test.gleam", 5).
-spec main() -> nil.
main() ->
    gleeunit:main().

-file("test/oni_p2p_test.gleam", 9).
-spec peer_id_test() -> nil.
peer_id_test() ->
    _pipe = oni_p2p:peer_id(<<"p"/utf8>>),
    gleeunit_ffi:should_equal(_pipe, {peer_id, <<"p"/utf8>>}).
