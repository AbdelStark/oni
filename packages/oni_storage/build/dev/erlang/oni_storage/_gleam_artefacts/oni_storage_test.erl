-module(oni_storage_test).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "test/oni_storage_test.gleam").
-export([main/0, not_found_test/0, storage_error_types_test/0]).

-file("test/oni_storage_test.gleam", 6).
-spec main() -> nil.
main() ->
    gleeunit:main().

-file("test/oni_storage_test.gleam", 10).
-spec not_found_test() -> nil.
not_found_test() ->
    Hash_bytes = <<16#00,
        16#00,
        16#00,
        16#00,
        16#00,
        16#19,
        16#d6,
        16#68,
        16#9c,
        16#08,
        16#5a,
        16#e1,
        16#65,
        16#83,
        16#1e,
        16#93,
        16#4f,
        16#f7,
        16#63,
        16#ae,
        16#46,
        16#a2,
        16#a6,
        16#c1,
        16#72,
        16#b3,
        16#f1,
        16#b6,
        16#0a,
        16#8c,
        16#e2,
        16#6f>>,
    H@1 = case oni_bitcoin:block_hash_from_bytes(Hash_bytes) of
        {ok, H} -> H;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_storage_test"/utf8>>,
                        function => <<"not_found_test"/utf8>>,
                        line => 18,
                        value => _assert_fail,
                        start => 422,
                        'end' => 486,
                        pattern_start => 433,
                        pattern_end => 438})
    end,
    _pipe = oni_storage:get_header(H@1),
    gleeunit_ffi:should_equal(_pipe, {error, not_found}).

-file("test/oni_storage_test.gleam", 23).
-spec storage_error_types_test() -> nil.
storage_error_types_test() ->
    Err = not_found,
    case Err of
        not_found ->
            gleeunit@should:be_true(true);

        _ ->
            gleeunit@should:fail()
    end.
