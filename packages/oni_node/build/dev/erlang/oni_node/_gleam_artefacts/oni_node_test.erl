-module(oni_node_test).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "test/oni_node_test.gleam").
-export([main/0, smoke_test/0]).

-file("test/oni_node_test.gleam", 4).
-spec main() -> nil.
main() ->
    gleeunit:main().

-file("test/oni_node_test.gleam", 8).
-spec smoke_test() -> nil.
smoke_test() ->
    _pipe = 1,
    gleeunit_ffi:should_equal(_pipe, 1).
