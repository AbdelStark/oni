-module(oni_consensus_test).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "test/oni_consensus_test.gleam").
-export([main/0, opcode_from_byte_push_test/0, opcode_from_byte_push_data_test/0, opcode_is_disabled_test/0, default_script_flags_test/0, sighash_type_from_byte_all_test/0, sighash_type_from_byte_none_test/0, sighash_type_from_byte_single_test/0, sighash_type_from_byte_anyonecanpay_test/0, constants_test/0, encode_script_num_zero_test/0, encode_script_num_one_test/0, encode_script_num_negative_one_test/0, encode_script_num_127_test/0, encode_script_num_128_test/0, decode_script_num_empty_test/0, decode_script_num_one_test/0, decode_script_num_negative_one_test/0, parse_empty_script_test/0, parse_op_dup_test/0, parse_push_data_test/0, parse_op_true_test/0, execute_empty_script_test/0, execute_op_true_test/0, execute_op_dup_test/0, execute_op_equal_true_test/0, execute_op_equal_false_test/0, execute_op_add_test/0, execute_hash160_test/0]).

-file("test/oni_consensus_test.gleam", 5).
-spec main() -> nil.
main() ->
    gleeunit:main().

-file("test/oni_consensus_test.gleam", 13).
-spec opcode_from_byte_push_test() -> nil.
opcode_from_byte_push_test() ->
    Op = oni_consensus:opcode_from_byte(16#76),
    _pipe = Op,
    gleeunit_ffi:should_equal(_pipe, op_dup).

-file("test/oni_consensus_test.gleam", 18).
-spec opcode_from_byte_push_data_test() -> nil.
opcode_from_byte_push_data_test() ->
    Op = oni_consensus:opcode_from_byte(16#05),
    _pipe = Op,
    gleeunit_ffi:should_equal(_pipe, {op_push_bytes, 5}).

-file("test/oni_consensus_test.gleam", 23).
-spec opcode_is_disabled_test() -> nil.
opcode_is_disabled_test() ->
    _pipe = oni_consensus:opcode_is_disabled(op_cat),
    gleeunit@should:be_true(_pipe),
    _pipe@1 = oni_consensus:opcode_is_disabled(op_dup),
    gleeunit@should:be_false(_pipe@1).

-file("test/oni_consensus_test.gleam", 35).
-spec default_script_flags_test() -> nil.
default_script_flags_test() ->
    Flags = oni_consensus:default_script_flags(),
    _pipe = erlang:element(2, Flags),
    gleeunit@should:be_true(_pipe),
    _pipe@1 = erlang:element(3, Flags),
    gleeunit@should:be_true(_pipe@1),
    _pipe@2 = erlang:element(14, Flags),
    gleeunit@should:be_true(_pipe@2).

-file("test/oni_consensus_test.gleam", 46).
-spec sighash_type_from_byte_all_test() -> nil.
sighash_type_from_byte_all_test() ->
    Sh = oni_consensus:sighash_type_from_byte(16#01),
    _pipe = Sh,
    gleeunit_ffi:should_equal(_pipe, sighash_all).

-file("test/oni_consensus_test.gleam", 51).
-spec sighash_type_from_byte_none_test() -> nil.
sighash_type_from_byte_none_test() ->
    Sh = oni_consensus:sighash_type_from_byte(16#02),
    _pipe = Sh,
    gleeunit_ffi:should_equal(_pipe, sighash_none).

-file("test/oni_consensus_test.gleam", 56).
-spec sighash_type_from_byte_single_test() -> nil.
sighash_type_from_byte_single_test() ->
    Sh = oni_consensus:sighash_type_from_byte(16#03),
    _pipe = Sh,
    gleeunit_ffi:should_equal(_pipe, sighash_single).

-file("test/oni_consensus_test.gleam", 61).
-spec sighash_type_from_byte_anyonecanpay_test() -> nil.
sighash_type_from_byte_anyonecanpay_test() ->
    Sh = oni_consensus:sighash_type_from_byte(16#81),
    _pipe = Sh,
    gleeunit_ffi:should_equal(_pipe, {sighash_anyone_can_pay, sighash_all}).

-file("test/oni_consensus_test.gleam", 70).
-spec constants_test() -> nil.
constants_test() ->
    _pipe = 520,
    gleeunit_ffi:should_equal(_pipe, 520),
    _pipe@1 = 10000,
    gleeunit_ffi:should_equal(_pipe@1, 10000),
    _pipe@2 = 201,
    gleeunit_ffi:should_equal(_pipe@2, 201),
    _pipe@3 = 1000,
    gleeunit_ffi:should_equal(_pipe@3, 1000),
    _pipe@4 = 4000000,
    gleeunit_ffi:should_equal(_pipe@4, 4000000),
    _pipe@5 = 100,
    gleeunit_ffi:should_equal(_pipe@5, 100).

-file("test/oni_consensus_test.gleam", 83).
-spec encode_script_num_zero_test() -> nil.
encode_script_num_zero_test() ->
    _pipe = oni_consensus:encode_script_num(0),
    gleeunit_ffi:should_equal(_pipe, <<>>).

-file("test/oni_consensus_test.gleam", 87).
-spec encode_script_num_one_test() -> nil.
encode_script_num_one_test() ->
    _pipe = oni_consensus:encode_script_num(1),
    gleeunit_ffi:should_equal(_pipe, <<16#01>>).

-file("test/oni_consensus_test.gleam", 91).
-spec encode_script_num_negative_one_test() -> nil.
encode_script_num_negative_one_test() ->
    _pipe = oni_consensus:encode_script_num(-1),
    gleeunit_ffi:should_equal(_pipe, <<16#81>>).

-file("test/oni_consensus_test.gleam", 95).
-spec encode_script_num_127_test() -> nil.
encode_script_num_127_test() ->
    _pipe = oni_consensus:encode_script_num(127),
    gleeunit_ffi:should_equal(_pipe, <<16#7f>>).

-file("test/oni_consensus_test.gleam", 99).
-spec encode_script_num_128_test() -> nil.
encode_script_num_128_test() ->
    _pipe = oni_consensus:encode_script_num(128),
    gleeunit_ffi:should_equal(_pipe, <<16#80, 16#00>>).

-file("test/oni_consensus_test.gleam", 104).
-spec decode_script_num_empty_test() -> nil.
decode_script_num_empty_test() ->
    _pipe = oni_consensus:decode_script_num(<<>>),
    gleeunit_ffi:should_equal(_pipe, {ok, 0}).

-file("test/oni_consensus_test.gleam", 108).
-spec decode_script_num_one_test() -> nil.
decode_script_num_one_test() ->
    _pipe = oni_consensus:decode_script_num(<<16#01>>),
    gleeunit_ffi:should_equal(_pipe, {ok, 1}).

-file("test/oni_consensus_test.gleam", 112).
-spec decode_script_num_negative_one_test() -> nil.
decode_script_num_negative_one_test() ->
    _pipe = oni_consensus:decode_script_num(<<16#81>>),
    gleeunit_ffi:should_equal(_pipe, {ok, -1}).

-file("test/oni_consensus_test.gleam", 120).
-spec parse_empty_script_test() -> nil.
parse_empty_script_test() ->
    Result = oni_consensus:parse_script(<<>>),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Elements@1 = case Result of
        {ok, Elements} -> Elements;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"parse_empty_script_test"/utf8>>,
                        line => 123,
                        value => _assert_fail,
                        start => 3925,
                        'end' => 3957,
                        pattern_start => 3936,
                        pattern_end => 3948})
    end,
    _pipe@1 = Elements@1,
    gleeunit_ffi:should_equal(_pipe@1, []).

-file("test/oni_consensus_test.gleam", 127).
-spec parse_op_dup_test() -> nil.
parse_op_dup_test() ->
    Result = oni_consensus:parse_script(<<16#76>>),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Elements@1 = case Result of
        {ok, Elements} -> Elements;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"parse_op_dup_test"/utf8>>,
                        line => 131,
                        value => _assert_fail,
                        start => 4119,
                        'end' => 4151,
                        pattern_start => 4130,
                        pattern_end => 4142})
    end,
    case Elements@1 of
        [{op_element, op_dup}] ->
            gleeunit@should:be_true(true);

        _ ->
            gleeunit@should:fail()
    end.

-file("test/oni_consensus_test.gleam", 138).
-spec parse_push_data_test() -> nil.
parse_push_data_test() ->
    Result = oni_consensus:parse_script(<<16#03, 16#01, 16#02, 16#03>>),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Elements@1 = case Result of
        {ok, Elements} -> Elements;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"parse_push_data_test"/utf8>>,
                        line => 142,
                        value => _assert_fail,
                        start => 4448,
                        'end' => 4480,
                        pattern_start => 4459,
                        pattern_end => 4471})
    end,
    case Elements@1 of
        [{data_element, Data}] ->
            _pipe@1 = Data,
            gleeunit_ffi:should_equal(_pipe@1, <<16#01, 16#02, 16#03>>);

        _ ->
            gleeunit@should:fail()
    end.

-file("test/oni_consensus_test.gleam", 151).
-spec parse_op_true_test() -> nil.
parse_op_true_test() ->
    Result = oni_consensus:parse_script(<<16#51>>),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Elements@1 = case Result of
        {ok, Elements} -> Elements;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"parse_op_true_test"/utf8>>,
                        line => 155,
                        value => _assert_fail,
                        start => 4756,
                        'end' => 4788,
                        pattern_start => 4767,
                        pattern_end => 4779})
    end,
    case Elements@1 of
        [{op_element, op_true}] ->
            gleeunit@should:be_true(true);

        _ ->
            gleeunit@should:fail()
    end.

-file("test/oni_consensus_test.gleam", 166).
-spec execute_empty_script_test() -> oni_consensus:script_context().
execute_empty_script_test() ->
    Flags = oni_consensus:default_script_flags(),
    Ctx = oni_consensus:script_context_new(<<>>, Flags),
    Result = oni_consensus:execute_script(Ctx),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe).

-file("test/oni_consensus_test.gleam", 173).
-spec execute_op_true_test() -> nil.
execute_op_true_test() ->
    Flags = oni_consensus:default_script_flags(),
    Ctx = oni_consensus:script_context_new(<<16#51>>, Flags),
    Result = oni_consensus:execute_script(Ctx),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Final_ctx@1 = case Result of
        {ok, Final_ctx} -> Final_ctx;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"execute_op_true_test"/utf8>>,
                        line => 179,
                        value => _assert_fail,
                        start => 5564,
                        'end' => 5597,
                        pattern_start => 5575,
                        pattern_end => 5588})
    end,
    case erlang:element(2, Final_ctx@1) of
        [<<1:8>>] ->
            gleeunit@should:be_true(true);

        _ ->
            gleeunit@should:fail()
    end.

-file("test/oni_consensus_test.gleam", 187).
-spec execute_op_dup_test() -> nil.
execute_op_dup_test() ->
    Flags = oni_consensus:default_script_flags(),
    Ctx = oni_consensus:script_context_new(<<16#51, 16#76>>, Flags),
    Result = oni_consensus:execute_script(Ctx),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Final_ctx@1 = case Result of
        {ok, Final_ctx} -> Final_ctx;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"execute_op_dup_test"/utf8>>,
                        line => 193,
                        value => _assert_fail,
                        start => 5983,
                        'end' => 6016,
                        pattern_start => 5994,
                        pattern_end => 6007})
    end,
    case erlang:element(2, Final_ctx@1) of
        [<<1:8>>, <<1:8>>] ->
            gleeunit@should:be_true(true);

        _ ->
            gleeunit@should:fail()
    end.

-file("test/oni_consensus_test.gleam", 201).
-spec execute_op_equal_true_test() -> nil.
execute_op_equal_true_test() ->
    Flags = oni_consensus:default_script_flags(),
    Ctx = oni_consensus:script_context_new(<<16#51, 16#51, 16#87>>, Flags),
    Result = oni_consensus:execute_script(Ctx),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Final_ctx@1 = case Result of
        {ok, Final_ctx} -> Final_ctx;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"execute_op_equal_true_test"/utf8>>,
                        line => 207,
                        value => _assert_fail,
                        start => 6460,
                        'end' => 6493,
                        pattern_start => 6471,
                        pattern_end => 6484})
    end,
    case erlang:element(2, Final_ctx@1) of
        [<<1:8>>] ->
            gleeunit@should:be_true(true);

        _ ->
            gleeunit@should:fail()
    end.

-file("test/oni_consensus_test.gleam", 214).
-spec execute_op_equal_false_test() -> nil.
execute_op_equal_false_test() ->
    Flags = oni_consensus:default_script_flags(),
    Ctx = oni_consensus:script_context_new(<<16#51, 16#52, 16#87>>, Flags),
    Result = oni_consensus:execute_script(Ctx),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Final_ctx@1 = case Result of
        {ok, Final_ctx} -> Final_ctx;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"execute_op_equal_false_test"/utf8>>,
                        line => 220,
                        value => _assert_fail,
                        start => 6893,
                        'end' => 6926,
                        pattern_start => 6904,
                        pattern_end => 6917})
    end,
    case erlang:element(2, Final_ctx@1) of
        [<<>>] ->
            gleeunit@should:be_true(true);

        _ ->
            gleeunit@should:fail()
    end.

-file("test/oni_consensus_test.gleam", 227).
-spec execute_op_add_test() -> nil.
execute_op_add_test() ->
    Flags = oni_consensus:default_script_flags(),
    Ctx = oni_consensus:script_context_new(<<16#52, 16#53, 16#93>>, Flags),
    Result = oni_consensus:execute_script(Ctx),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Final_ctx@1 = case Result of
        {ok, Final_ctx} -> Final_ctx;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"execute_op_add_test"/utf8>>,
                        line => 233,
                        value => _assert_fail,
                        start => 7301,
                        'end' => 7334,
                        pattern_start => 7312,
                        pattern_end => 7325})
    end,
    case erlang:element(2, Final_ctx@1) of
        [<<5:8>>] ->
            gleeunit@should:be_true(true);

        _ ->
            gleeunit@should:fail()
    end.

-file("test/oni_consensus_test.gleam", 240).
-spec execute_hash160_test() -> nil.
execute_hash160_test() ->
    Flags = oni_consensus:default_script_flags(),
    Ctx = oni_consensus:script_context_new(<<16#01, 16#AB, 16#a9>>, Flags),
    Result = oni_consensus:execute_script(Ctx),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Final_ctx@1 = case Result of
        {ok, Final_ctx} -> Final_ctx;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_consensus_test"/utf8>>,
                        function => <<"execute_hash160_test"/utf8>>,
                        line => 246,
                        value => _assert_fail,
                        start => 7699,
                        'end' => 7732,
                        pattern_start => 7710,
                        pattern_end => 7723})
    end,
    case erlang:element(2, Final_ctx@1) of
        [Hash] ->
            gleeunit@should:be_true(erlang:byte_size(Hash) =:= 20);

        _ ->
            gleeunit@should:fail()
    end.
