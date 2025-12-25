-module(oni_rpc_test).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "test/oni_rpc_test.gleam").
-export([main/0, hello_test/0]).

-file("test/oni_rpc_test.gleam", 5).
-spec main() -> nil.
main() ->
    gleeunit:main().

-file("test/oni_rpc_test.gleam", 9).
-spec hello_test() -> nil.
hello_test() ->
    _pipe = oni_rpc:hello(),
    gleeunit_ffi:should_equal(_pipe, <<"oni_rpc (scaffold)"/utf8>>).
