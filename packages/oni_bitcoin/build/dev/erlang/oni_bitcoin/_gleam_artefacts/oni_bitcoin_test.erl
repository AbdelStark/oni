-module(oni_bitcoin_test).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "test/oni_bitcoin_test.gleam").
-export([main/0, hash256_from_bytes_valid_test/0, hash256_from_bytes_invalid_test/0, txid_from_bytes_valid_test/0, hex_encode_test/0, hex_decode_valid_test/0, hex_decode_invalid_odd_length_test/0, hex_decode_invalid_chars_test/0, hex_roundtrip_test/0, amount_from_sats_valid_test/0, amount_from_sats_negative_test/0, amount_from_sats_max_test/0, amount_from_sats_exceeds_max_test/0, amount_add_test/0, amount_sub_test/0, amount_sub_negative_test/0, compact_size_encode_small_test/0, compact_size_encode_fd_test/0, compact_size_encode_fe_test/0, compact_size_decode_small_test/0, compact_size_decode_fd_test/0, compact_size_roundtrip_test/0, script_from_bytes_test/0, script_empty_test/0, outpoint_null_test/0, sha256_test/0, sha256d_test/0, ripemd160_test/0, hash160_test/0, pubkey_compressed_even_test/0, pubkey_compressed_odd_test/0, pubkey_uncompressed_test/0, pubkey_invalid_prefix_test/0, pubkey_wrong_length_test/0, xonly_pubkey_valid_test/0, xonly_pubkey_invalid_length_test/0, pubkey_to_xonly_test/0, schnorr_sig_valid_test/0, schnorr_sig_invalid_length_test/0]).

-file("test/oni_bitcoin_test.gleam", 5).
-spec main() -> nil.
main() ->
    gleeunit:main().

-file("test/oni_bitcoin_test.gleam", 13).
-spec hash256_from_bytes_valid_test() -> oni_bitcoin:hash256().
hash256_from_bytes_valid_test() ->
    Bytes = <<16#00,
        16#01,
        16#02,
        16#03,
        16#04,
        16#05,
        16#06,
        16#07,
        16#08,
        16#09,
        16#0a,
        16#0b,
        16#0c,
        16#0d,
        16#0e,
        16#0f,
        16#10,
        16#11,
        16#12,
        16#13,
        16#14,
        16#15,
        16#16,
        16#17,
        16#18,
        16#19,
        16#1a,
        16#1b,
        16#1c,
        16#1d,
        16#1e,
        16#1f>>,
    Result = oni_bitcoin:hash256_from_bytes(Bytes),
    gleeunit_ffi:should_be_ok(Result).

-file("test/oni_bitcoin_test.gleam", 24).
-spec hash256_from_bytes_invalid_test() -> binary().
hash256_from_bytes_invalid_test() ->
    Bytes = <<16#00, 16#01, 16#02>>,
    Result = oni_bitcoin:hash256_from_bytes(Bytes),
    gleeunit_ffi:should_be_error(Result).

-file("test/oni_bitcoin_test.gleam", 30).
-spec txid_from_bytes_valid_test() -> oni_bitcoin:txid().
txid_from_bytes_valid_test() ->
    Bytes = <<16#00,
        16#01,
        16#02,
        16#03,
        16#04,
        16#05,
        16#06,
        16#07,
        16#08,
        16#09,
        16#0a,
        16#0b,
        16#0c,
        16#0d,
        16#0e,
        16#0f,
        16#10,
        16#11,
        16#12,
        16#13,
        16#14,
        16#15,
        16#16,
        16#17,
        16#18,
        16#19,
        16#1a,
        16#1b,
        16#1c,
        16#1d,
        16#1e,
        16#1f>>,
    Result = oni_bitcoin:txid_from_bytes(Bytes),
    gleeunit_ffi:should_be_ok(Result).

-file("test/oni_bitcoin_test.gleam", 45).
-spec hex_encode_test() -> nil.
hex_encode_test() ->
    Bytes = <<16#DE, 16#AD, 16#BE, 16#EF>>,
    Hex = oni_bitcoin:hex_encode(Bytes),
    _pipe = Hex,
    gleeunit_ffi:should_equal(_pipe, <<"deadbeef"/utf8>>).

-file("test/oni_bitcoin_test.gleam", 51).
-spec hex_decode_valid_test() -> nil.
hex_decode_valid_test() ->
    Result = oni_bitcoin:hex_decode(<<"deadbeef"/utf8>>),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    Bytes@1 = case Result of
        {ok, Bytes} -> Bytes;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"hex_decode_valid_test"/utf8>>,
                        line => 54,
                        value => _assert_fail,
                        start => 1563,
                        'end' => 1592,
                        pattern_start => 1574,
                        pattern_end => 1583})
    end,
    _pipe@1 = Bytes@1,
    gleeunit_ffi:should_equal(_pipe@1, <<16#DE, 16#AD, 16#BE, 16#EF>>).

-file("test/oni_bitcoin_test.gleam", 58).
-spec hex_decode_invalid_odd_length_test() -> binary().
hex_decode_invalid_odd_length_test() ->
    Result = oni_bitcoin:hex_decode(<<"abc"/utf8>>),
    _pipe = Result,
    gleeunit_ffi:should_be_error(_pipe).

-file("test/oni_bitcoin_test.gleam", 63).
-spec hex_decode_invalid_chars_test() -> binary().
hex_decode_invalid_chars_test() ->
    Result = oni_bitcoin:hex_decode(<<"ghij"/utf8>>),
    _pipe = Result,
    gleeunit_ffi:should_be_error(_pipe).

-file("test/oni_bitcoin_test.gleam", 68).
-spec hex_roundtrip_test() -> nil.
hex_roundtrip_test() ->
    Original = <<16#01, 16#23, 16#45, 16#67, 16#89, 16#ab, 16#cd, 16#ef>>,
    Hex = oni_bitcoin:hex_encode(Original),
    Decoded@1 = case oni_bitcoin:hex_decode(Hex) of
        {ok, Decoded} -> Decoded;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"hex_roundtrip_test"/utf8>>,
                        line => 71,
                        value => _assert_fail,
                        start => 2033,
                        'end' => 2085,
                        pattern_start => 2044,
                        pattern_end => 2055})
    end,
    _pipe = Decoded@1,
    gleeunit_ffi:should_equal(_pipe, Original).

-file("test/oni_bitcoin_test.gleam", 79).
-spec amount_from_sats_valid_test() -> oni_bitcoin:amount().
amount_from_sats_valid_test() ->
    Result = oni_bitcoin:amount_from_sats(100000000),
    gleeunit_ffi:should_be_ok(Result).

-file("test/oni_bitcoin_test.gleam", 84).
-spec amount_from_sats_negative_test() -> binary().
amount_from_sats_negative_test() ->
    Result = oni_bitcoin:amount_from_sats(-1),
    gleeunit_ffi:should_be_error(Result).

-file("test/oni_bitcoin_test.gleam", 89).
-spec amount_from_sats_max_test() -> oni_bitcoin:amount().
amount_from_sats_max_test() ->
    Result = oni_bitcoin:amount_from_sats(2100000000000000),
    gleeunit_ffi:should_be_ok(Result).

-file("test/oni_bitcoin_test.gleam", 94).
-spec amount_from_sats_exceeds_max_test() -> binary().
amount_from_sats_exceeds_max_test() ->
    Result = oni_bitcoin:amount_from_sats(2100000000000000 + 1),
    gleeunit_ffi:should_be_error(Result).

-file("test/oni_bitcoin_test.gleam", 99).
-spec amount_add_test() -> nil.
amount_add_test() ->
    A@1 = case oni_bitcoin:amount_from_sats(100) of
        {ok, A} -> A;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"amount_add_test"/utf8>>,
                        line => 100,
                        value => _assert_fail,
                        start => 2853,
                        'end' => 2905,
                        pattern_start => 2864,
                        pattern_end => 2869})
    end,
    B@1 = case oni_bitcoin:amount_from_sats(200) of
        {ok, B} -> B;
        _assert_fail@1 ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"amount_add_test"/utf8>>,
                        line => 101,
                        value => _assert_fail@1,
                        start => 2908,
                        'end' => 2960,
                        pattern_start => 2919,
                        pattern_end => 2924})
    end,
    Result = oni_bitcoin:amount_add(A@1, B@1),
    Sum@1 = case Result of
        {ok, Sum} -> Sum;
        _assert_fail@2 ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"amount_add_test"/utf8>>,
                        line => 103,
                        value => _assert_fail@2,
                        start => 3007,
                        'end' => 3034,
                        pattern_start => 3018,
                        pattern_end => 3025})
    end,
    _pipe = oni_bitcoin:amount_to_sats(Sum@1),
    gleeunit_ffi:should_equal(_pipe, 300).

-file("test/oni_bitcoin_test.gleam", 107).
-spec amount_sub_test() -> nil.
amount_sub_test() ->
    A@1 = case oni_bitcoin:amount_from_sats(500) of
        {ok, A} -> A;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"amount_sub_test"/utf8>>,
                        line => 108,
                        value => _assert_fail,
                        start => 3122,
                        'end' => 3174,
                        pattern_start => 3133,
                        pattern_end => 3138})
    end,
    B@1 = case oni_bitcoin:amount_from_sats(200) of
        {ok, B} -> B;
        _assert_fail@1 ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"amount_sub_test"/utf8>>,
                        line => 109,
                        value => _assert_fail@1,
                        start => 3177,
                        'end' => 3229,
                        pattern_start => 3188,
                        pattern_end => 3193})
    end,
    Result = oni_bitcoin:amount_sub(A@1, B@1),
    Diff@1 = case Result of
        {ok, Diff} -> Diff;
        _assert_fail@2 ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"amount_sub_test"/utf8>>,
                        line => 111,
                        value => _assert_fail@2,
                        start => 3276,
                        'end' => 3304,
                        pattern_start => 3287,
                        pattern_end => 3295})
    end,
    _pipe = oni_bitcoin:amount_to_sats(Diff@1),
    gleeunit_ffi:should_equal(_pipe, 300).

-file("test/oni_bitcoin_test.gleam", 115).
-spec amount_sub_negative_test() -> binary().
amount_sub_negative_test() ->
    A@1 = case oni_bitcoin:amount_from_sats(100) of
        {ok, A} -> A;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"amount_sub_negative_test"/utf8>>,
                        line => 116,
                        value => _assert_fail,
                        start => 3402,
                        'end' => 3454,
                        pattern_start => 3413,
                        pattern_end => 3418})
    end,
    B@1 = case oni_bitcoin:amount_from_sats(200) of
        {ok, B} -> B;
        _assert_fail@1 ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"amount_sub_negative_test"/utf8>>,
                        line => 117,
                        value => _assert_fail@1,
                        start => 3457,
                        'end' => 3509,
                        pattern_start => 3468,
                        pattern_end => 3473})
    end,
    Result = oni_bitcoin:amount_sub(A@1, B@1),
    gleeunit_ffi:should_be_error(Result).

-file("test/oni_bitcoin_test.gleam", 126).
-spec compact_size_encode_small_test() -> nil.
compact_size_encode_small_test() ->
    Result = oni_bitcoin:compact_size_encode(252),
    _pipe = Result,
    gleeunit_ffi:should_equal(_pipe, <<252:8>>).

-file("test/oni_bitcoin_test.gleam", 131).
-spec compact_size_encode_fd_test() -> nil.
compact_size_encode_fd_test() ->
    Result = oni_bitcoin:compact_size_encode(253),
    _pipe = Result,
    gleeunit_ffi:should_equal(_pipe, <<16#FD:8, 253:16/little>>).

-file("test/oni_bitcoin_test.gleam", 136).
-spec compact_size_encode_fe_test() -> nil.
compact_size_encode_fe_test() ->
    Result = oni_bitcoin:compact_size_encode(16#10000),
    _pipe = Result,
    gleeunit_ffi:should_equal(_pipe, <<16#FE:8, 16#10000:32/little>>).

-file("test/oni_bitcoin_test.gleam", 141).
-spec compact_size_decode_small_test() -> nil.
compact_size_decode_small_test() ->
    Result = oni_bitcoin:compact_size_decode(<<42:8, 16#FF:8>>),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    {Value@1, Rest@1} = case Result of
        {ok, {Value, Rest}} -> {Value, Rest};
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"compact_size_decode_small_test"/utf8>>,
                        line => 144,
                        value => _assert_fail,
                        start => 4332,
                        'end' => 4370,
                        pattern_start => 4343,
                        pattern_end => 4361})
    end,
    _pipe@1 = Value@1,
    gleeunit_ffi:should_equal(_pipe@1, 42),
    _pipe@2 = Rest@1,
    gleeunit_ffi:should_equal(_pipe@2, <<16#FF:8>>).

-file("test/oni_bitcoin_test.gleam", 149).
-spec compact_size_decode_fd_test() -> nil.
compact_size_decode_fd_test() ->
    Result = oni_bitcoin:compact_size_decode(
        <<16#FD:8, 300:16/little, 16#FF:8>>
    ),
    _pipe = Result,
    gleeunit_ffi:should_be_ok(_pipe),
    {Value@1, Rest@1} = case Result of
        {ok, {Value, Rest}} -> {Value, Rest};
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"compact_size_decode_fd_test"/utf8>>,
                        line => 152,
                        value => _assert_fail,
                        start => 4585,
                        'end' => 4623,
                        pattern_start => 4596,
                        pattern_end => 4614})
    end,
    _pipe@1 = Value@1,
    gleeunit_ffi:should_equal(_pipe@1, 300),
    _pipe@2 = Rest@1,
    gleeunit_ffi:should_equal(_pipe@2, <<16#FF:8>>).

-file("test/oni_bitcoin_test.gleam", 157).
-spec compact_size_roundtrip_test() -> nil.
compact_size_roundtrip_test() ->
    Values = [0, 1, 252, 253, 16#FFFF, 16#10000, 16#FFFFFFFF],
    gleam@list:each(
        Values,
        fun(Val) ->
            Encoded = oni_bitcoin:compact_size_encode(Val),
            Decoded@1 = case oni_bitcoin:compact_size_decode(Encoded) of
                {ok, {Decoded, <<>>}} -> Decoded;
                _assert_fail ->
                    erlang:error(#{gleam_error => let_assert,
                                message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                                file => <<?FILEPATH/utf8>>,
                                module => <<"oni_bitcoin_test"/utf8>>,
                                function => <<"compact_size_roundtrip_test"/utf8>>,
                                line => 161,
                                value => _assert_fail,
                                start => 4877,
                                'end' => 4951,
                                pattern_start => 4888,
                                pattern_end => 4908})
            end,
            _pipe = Decoded@1,
            gleeunit_ffi:should_equal(_pipe, Val)
        end
    ).

-file("test/oni_bitcoin_test.gleam", 169).
-spec script_from_bytes_test() -> nil.
script_from_bytes_test() ->
    Bytes = <<16#76, 16#a9, 16#14>>,
    Script = oni_bitcoin:script_from_bytes(Bytes),
    _pipe = oni_bitcoin:script_size(Script),
    gleeunit_ffi:should_equal(_pipe, 3),
    _pipe@1 = oni_bitcoin:script_is_empty(Script),
    gleeunit@should:be_false(_pipe@1).

-file("test/oni_bitcoin_test.gleam", 176).
-spec script_empty_test() -> nil.
script_empty_test() ->
    Script = oni_bitcoin:script_from_bytes(<<>>),
    _pipe = oni_bitcoin:script_is_empty(Script),
    gleeunit@should:be_true(_pipe).

-file("test/oni_bitcoin_test.gleam", 185).
-spec outpoint_null_test() -> nil.
outpoint_null_test() ->
    Null = oni_bitcoin:outpoint_null(),
    _pipe = oni_bitcoin:outpoint_is_null(Null),
    gleeunit@should:be_true(_pipe).

-file("test/oni_bitcoin_test.gleam", 194).
-spec sha256_test() -> nil.
sha256_test() ->
    Input = <<"abc"/utf8>>,
    Result = oni_bitcoin:sha256(Input),
    Hex = oni_bitcoin:hex_encode(Result),
    _pipe = Hex,
    gleeunit_ffi:should_equal(
        _pipe,
        <<"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"/utf8>>
    ).

-file("test/oni_bitcoin_test.gleam", 202).
-spec sha256d_test() -> nil.
sha256d_test() ->
    Input = <<"abc"/utf8>>,
    Result = oni_bitcoin:sha256d(Input),
    Hex = oni_bitcoin:hex_encode(Result),
    _pipe = Hex,
    gleeunit_ffi:should_equal(
        _pipe,
        <<"4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358"/utf8>>
    ).

-file("test/oni_bitcoin_test.gleam", 214).
-spec ripemd160_test() -> nil.
ripemd160_test() ->
    Input = <<"abc"/utf8>>,
    Result = oni_bitcoin:ripemd160(Input),
    Hex = oni_bitcoin:hex_encode(Result),
    _pipe = Hex,
    gleeunit_ffi:should_equal(
        _pipe,
        <<"8eb208f7e05d987a9b044a8e98c6b087f15a0bfc"/utf8>>
    ).

-file("test/oni_bitcoin_test.gleam", 222).
-spec hash160_test() -> nil.
hash160_test() ->
    Input = <<"abc"/utf8>>,
    Result = oni_bitcoin:hash160(Input),
    _pipe = Result,
    gleeunit_ffi:should_equal(
        _pipe,
        oni_bitcoin:ripemd160(oni_bitcoin:sha256(Input))
    ).

-file("test/oni_bitcoin_test.gleam", 234).
-spec pubkey_compressed_even_test() -> nil.
pubkey_compressed_even_test() ->
    Bytes = <<16#02,
        16#79,
        16#BE,
        16#66,
        16#7E,
        16#F9,
        16#DC,
        16#BB,
        16#AC,
        16#55,
        16#A0,
        16#62,
        16#95,
        16#CE,
        16#87,
        16#0B,
        16#07,
        16#02,
        16#9B,
        16#FC,
        16#DB,
        16#2D,
        16#CE,
        16#28,
        16#D9,
        16#59,
        16#F2,
        16#81,
        16#5B,
        16#16,
        16#F8,
        16#17,
        16#98>>,
    Result = oni_bitcoin:pubkey_from_bytes(Bytes),
    gleeunit_ffi:should_be_ok(Result),
    Pubkey@1 = case Result of
        {ok, Pubkey} -> Pubkey;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"pubkey_compressed_even_test"/utf8>>,
                        line => 245,
                        value => _assert_fail,
                        start => 7991,
                        'end' => 8021,
                        pattern_start => 8002,
                        pattern_end => 8012})
    end,
    _pipe = oni_bitcoin:pubkey_is_compressed(Pubkey@1),
    gleeunit@should:be_true(_pipe).

-file("test/oni_bitcoin_test.gleam", 249).
-spec pubkey_compressed_odd_test() -> nil.
pubkey_compressed_odd_test() ->
    Bytes = <<16#03,
        16#79,
        16#BE,
        16#66,
        16#7E,
        16#F9,
        16#DC,
        16#BB,
        16#AC,
        16#55,
        16#A0,
        16#62,
        16#95,
        16#CE,
        16#87,
        16#0B,
        16#07,
        16#02,
        16#9B,
        16#FC,
        16#DB,
        16#2D,
        16#CE,
        16#28,
        16#D9,
        16#59,
        16#F2,
        16#81,
        16#5B,
        16#16,
        16#F8,
        16#17,
        16#98>>,
    Result = oni_bitcoin:pubkey_from_bytes(Bytes),
    gleeunit_ffi:should_be_ok(Result),
    Pubkey@1 = case Result of
        {ok, Pubkey} -> Pubkey;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"pubkey_compressed_odd_test"/utf8>>,
                        line => 260,
                        value => _assert_fail,
                        start => 8491,
                        'end' => 8521,
                        pattern_start => 8502,
                        pattern_end => 8512})
    end,
    _pipe = oni_bitcoin:pubkey_is_compressed(Pubkey@1),
    gleeunit@should:be_true(_pipe).

-file("test/oni_bitcoin_test.gleam", 264).
-spec pubkey_uncompressed_test() -> nil.
pubkey_uncompressed_test() ->
    Bytes = <<16#04,
        16#79,
        16#BE,
        16#66,
        16#7E,
        16#F9,
        16#DC,
        16#BB,
        16#AC,
        16#55,
        16#A0,
        16#62,
        16#95,
        16#CE,
        16#87,
        16#0B,
        16#07,
        16#02,
        16#9B,
        16#FC,
        16#DB,
        16#2D,
        16#CE,
        16#28,
        16#D9,
        16#59,
        16#F2,
        16#81,
        16#5B,
        16#16,
        16#F8,
        16#17,
        16#98,
        16#48,
        16#3A,
        16#DA,
        16#77,
        16#26,
        16#A3,
        16#C4,
        16#65,
        16#5D,
        16#A4,
        16#FB,
        16#FC,
        16#0E,
        16#11,
        16#08,
        16#A8,
        16#FD,
        16#17,
        16#B4,
        16#48,
        16#A6,
        16#85,
        16#54,
        16#19,
        16#9C,
        16#47,
        16#D0,
        16#8F,
        16#FB,
        16#10,
        16#D4,
        16#B8>>,
    Result = oni_bitcoin:pubkey_from_bytes(Bytes),
    gleeunit_ffi:should_be_ok(Result),
    Pubkey@1 = case Result of
        {ok, Pubkey} -> Pubkey;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"pubkey_uncompressed_test"/utf8>>,
                        line => 279,
                        value => _assert_fail,
                        start => 9199,
                        'end' => 9229,
                        pattern_start => 9210,
                        pattern_end => 9220})
    end,
    _pipe = oni_bitcoin:pubkey_is_compressed(Pubkey@1),
    gleeunit@should:be_false(_pipe).

-file("test/oni_bitcoin_test.gleam", 283).
-spec pubkey_invalid_prefix_test() -> oni_bitcoin:crypto_error().
pubkey_invalid_prefix_test() ->
    Bytes = <<16#05,
        16#79,
        16#BE,
        16#66,
        16#7E,
        16#F9,
        16#DC,
        16#BB,
        16#AC,
        16#55,
        16#A0,
        16#62,
        16#95,
        16#CE,
        16#87,
        16#0B,
        16#07,
        16#02,
        16#9B,
        16#FC,
        16#DB,
        16#2D,
        16#CE,
        16#28,
        16#D9,
        16#59,
        16#F2,
        16#81,
        16#5B,
        16#16,
        16#F8,
        16#17,
        16#98>>,
    Result = oni_bitcoin:pubkey_from_bytes(Bytes),
    gleeunit_ffi:should_be_error(Result).

-file("test/oni_bitcoin_test.gleam", 296).
-spec pubkey_wrong_length_test() -> oni_bitcoin:crypto_error().
pubkey_wrong_length_test() ->
    Bytes = <<16#02,
        16#79,
        16#BE,
        16#66,
        16#7E,
        16#F9,
        16#DC,
        16#BB,
        16#AC,
        16#55,
        16#A0,
        16#62,
        16#95,
        16#CE,
        16#87,
        16#0B,
        16#07,
        16#02,
        16#9B,
        16#FC,
        16#DB,
        16#2D,
        16#CE,
        16#28,
        16#D9,
        16#59,
        16#F2,
        16#81,
        16#5B,
        16#16>>,
    Result = oni_bitcoin:pubkey_from_bytes(Bytes),
    gleeunit_ffi:should_be_error(Result).

-file("test/oni_bitcoin_test.gleam", 309).
-spec xonly_pubkey_valid_test() -> oni_bitcoin:x_only_pub_key().
xonly_pubkey_valid_test() ->
    Bytes = <<16#79,
        16#BE,
        16#66,
        16#7E,
        16#F9,
        16#DC,
        16#BB,
        16#AC,
        16#55,
        16#A0,
        16#62,
        16#95,
        16#CE,
        16#87,
        16#0B,
        16#07,
        16#02,
        16#9B,
        16#FC,
        16#DB,
        16#2D,
        16#CE,
        16#28,
        16#D9,
        16#59,
        16#F2,
        16#81,
        16#5B,
        16#16,
        16#F8,
        16#17,
        16#98>>,
    Result = oni_bitcoin:xonly_pubkey_from_bytes(Bytes),
    gleeunit_ffi:should_be_ok(Result).

-file("test/oni_bitcoin_test.gleam", 321).
-spec xonly_pubkey_invalid_length_test() -> oni_bitcoin:crypto_error().
xonly_pubkey_invalid_length_test() ->
    Bytes = <<16#01, 16#02, 16#03>>,
    Result = oni_bitcoin:xonly_pubkey_from_bytes(Bytes),
    gleeunit_ffi:should_be_error(Result).

-file("test/oni_bitcoin_test.gleam", 327).
-spec pubkey_to_xonly_test() -> oni_bitcoin:x_only_pub_key().
pubkey_to_xonly_test() ->
    Compressed = <<16#02,
        16#79,
        16#BE,
        16#66,
        16#7E,
        16#F9,
        16#DC,
        16#BB,
        16#AC,
        16#55,
        16#A0,
        16#62,
        16#95,
        16#CE,
        16#87,
        16#0B,
        16#07,
        16#02,
        16#9B,
        16#FC,
        16#DB,
        16#2D,
        16#CE,
        16#28,
        16#D9,
        16#59,
        16#F2,
        16#81,
        16#5B,
        16#16,
        16#F8,
        16#17,
        16#98>>,
    Pubkey@1 = case oni_bitcoin:pubkey_from_bytes(Compressed) of
        {ok, Pubkey} -> Pubkey;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin_test"/utf8>>,
                        function => <<"pubkey_to_xonly_test"/utf8>>,
                        line => 336,
                        value => _assert_fail,
                        start => 10915,
                        'end' => 10980,
                        pattern_start => 10926,
                        pattern_end => 10936})
    end,
    Result = oni_bitcoin:pubkey_to_xonly(Pubkey@1),
    gleeunit_ffi:should_be_ok(Result).

-file("test/oni_bitcoin_test.gleam", 345).
-spec schnorr_sig_valid_test() -> oni_bitcoin:schnorr_sig().
schnorr_sig_valid_test() ->
    Bytes = <<16#00,
        16#01,
        16#02,
        16#03,
        16#04,
        16#05,
        16#06,
        16#07,
        16#08,
        16#09,
        16#0a,
        16#0b,
        16#0c,
        16#0d,
        16#0e,
        16#0f,
        16#10,
        16#11,
        16#12,
        16#13,
        16#14,
        16#15,
        16#16,
        16#17,
        16#18,
        16#19,
        16#1a,
        16#1b,
        16#1c,
        16#1d,
        16#1e,
        16#1f,
        16#20,
        16#21,
        16#22,
        16#23,
        16#24,
        16#25,
        16#26,
        16#27,
        16#28,
        16#29,
        16#2a,
        16#2b,
        16#2c,
        16#2d,
        16#2e,
        16#2f,
        16#30,
        16#31,
        16#32,
        16#33,
        16#34,
        16#35,
        16#36,
        16#37,
        16#38,
        16#39,
        16#3a,
        16#3b,
        16#3c,
        16#3d,
        16#3e,
        16#3f>>,
    Result = oni_bitcoin:schnorr_sig_from_bytes(Bytes),
    gleeunit_ffi:should_be_ok(Result).

-file("test/oni_bitcoin_test.gleam", 361).
-spec schnorr_sig_invalid_length_test() -> oni_bitcoin:crypto_error().
schnorr_sig_invalid_length_test() ->
    Bytes = <<16#00, 16#01, 16#02, 16#03>>,
    Result = oni_bitcoin:schnorr_sig_from_bytes(Bytes),
    gleeunit_ffi:should_be_error(Result).
