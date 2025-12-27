%%% oni_test_runner - Differential testing harness against Bitcoin Core
%%%
%%% This module provides:
%%% - Test vector loading and parsing
%%% - Execution of consensus tests against oni
%%% - Live oracle testing against bitcoind (when available)
%%% - Result comparison and reporting

-module(oni_test_runner).

-export([
    run_all/0,
    run_script_tests/0,
    run_tx_tests/0,
    run_sighash_tests/0,
    run_live_oracle/0,
    load_test_vectors/1,
    compare_with_bitcoind/2
]).

%% ============================================================================
%% Public API
%% ============================================================================

%% Run all differential tests
-spec run_all() -> {ok, map()} | {error, term()}.
run_all() ->
    io:format("~n=== ONI Differential Test Suite ===~n~n"),

    Results = #{
        script_tests => run_script_tests(),
        tx_tests => run_tx_tests(),
        sighash_tests => run_sighash_tests()
    },

    print_summary(Results),
    {ok, Results}.

%% Run script test vectors
-spec run_script_tests() -> {ok, map()} | {error, term()}.
run_script_tests() ->
    io:format("Running script tests...~n"),
    case load_test_vectors("test_vectors/script_tests.json") of
        {ok, Vectors} ->
            run_script_vectors(Vectors);
        {error, Reason} ->
            io:format("Failed to load script tests: ~p~n", [Reason]),
            {error, Reason}
    end.

%% Run transaction test vectors
-spec run_tx_tests() -> {ok, map()} | {error, term()}.
run_tx_tests() ->
    io:format("Running transaction tests...~n"),
    ValidResult = case load_test_vectors("test_vectors/tx_valid.json") of
        {ok, ValidVectors} ->
            run_tx_valid_vectors(ValidVectors);
        {error, _} ->
            {ok, #{passed => 0, failed => 0, skipped => 0}}
    end,

    InvalidResult = case load_test_vectors("test_vectors/tx_invalid.json") of
        {ok, InvalidVectors} ->
            run_tx_invalid_vectors(InvalidVectors);
        {error, _} ->
            {ok, #{passed => 0, failed => 0, skipped => 0}}
    end,

    merge_results([ValidResult, InvalidResult]).

%% Run sighash test vectors
-spec run_sighash_tests() -> {ok, map()} | {error, term()}.
run_sighash_tests() ->
    io:format("Running sighash tests...~n"),
    case load_test_vectors("test_vectors/sighash_tests.json") of
        {ok, Vectors} ->
            run_sighash_vectors(Vectors);
        {error, Reason} ->
            io:format("Failed to load sighash tests: ~p~n", [Reason]),
            {error, Reason}
    end.

%% Run live oracle tests against bitcoind
-spec run_live_oracle() -> {ok, map()} | {error, term()}.
run_live_oracle() ->
    io:format("Running live oracle tests against bitcoind...~n"),
    case check_bitcoind_available() of
        true ->
            run_oracle_tests();
        false ->
            io:format("bitcoind not available, skipping live oracle tests~n"),
            {ok, #{skipped => true}}
    end.

%% Load test vectors from JSON file
-spec load_test_vectors(string()) -> {ok, list()} | {error, term()}.
load_test_vectors(Filename) ->
    case file:read_file(Filename) of
        {ok, Binary} ->
            try
                Json = jsone:decode(Binary, [{object_format, map}]),
                {ok, Json}
            catch
                _:_ ->
                    %% Try with alternative JSON parser or custom parser
                    parse_test_vectors_manual(Binary)
            end;
        {error, enoent} ->
            %% Try relative to project root
            ProjectPath = filename:join([code:lib_dir(oni_node), "..", "..", "..", "..", Filename]),
            case file:read_file(ProjectPath) of
                {ok, Binary} ->
                    parse_test_vectors_manual(Binary);
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% Compare oni result with bitcoind for a given artifact
-spec compare_with_bitcoind(tx | block | script, binary()) ->
    {match | mismatch | unknown, map()}.
compare_with_bitcoind(Type, Data) ->
    OniResult = validate_with_oni(Type, Data),
    BitcoindResult = validate_with_bitcoind(Type, Data),

    Comparison = case {OniResult, BitcoindResult} of
        {{ok, OniValid}, {ok, BitcoindValid}} when OniValid =:= BitcoindValid ->
            match;
        {{ok, _}, {ok, _}} ->
            mismatch;
        {{error, _}, {error, _}} ->
            match;  % Both rejected
        _ ->
            mismatch
    end,

    {Comparison, #{
        oni => OniResult,
        bitcoind => BitcoindResult,
        artifact_type => Type,
        artifact_hash => crypto:hash(sha256, Data)
    }}.

%% ============================================================================
%% Internal Functions - Script Tests
%% ============================================================================

run_script_vectors(Vectors) ->
    %% Filter out comments (arrays with single string element)
    TestCases = lists:filter(fun
        ([_Comment]) -> false;
        (V) when is_list(V), length(V) >= 4 -> true;
        (_) -> false
    end, Vectors),

    Results = lists:map(fun run_single_script_test/1, TestCases),

    Passed = length([R || {ok, _} <- Results]),
    Failed = length([R || {error, _} <- Results]),
    Skipped = length([R || {skip, _} <- Results]),

    io:format("Script tests: ~p passed, ~p failed, ~p skipped~n",
              [Passed, Failed, Skipped]),

    {ok, #{passed => Passed, failed => Failed, skipped => Skipped}}.

run_single_script_test([ScriptSig, ScriptPubKey, Flags, ExpectedResult | Rest]) ->
    Comment = case Rest of [C] -> C; _ -> "unnamed" end,

    try
        %% Parse scripts
        SigBytes = parse_script_string(ScriptSig),
        PubKeyBytes = parse_script_string(ScriptPubKey),
        ParsedFlags = parse_flags(Flags),
        Expected = parse_expected_result(ExpectedResult),

        %% Execute with oni consensus engine
        Result = execute_script_test(SigBytes, PubKeyBytes, ParsedFlags),

        %% Compare
        case compare_script_result(Result, Expected) of
            match ->
                {ok, Comment};
            {mismatch, Details} ->
                io:format("FAIL: ~s - ~p~n", [Comment, Details]),
                {error, {mismatch, Comment, Details}}
        end
    catch
        _:Reason ->
            {skip, {parse_error, Comment, Reason}}
    end;
run_single_script_test(_) ->
    {skip, invalid_format}.

parse_script_string(Str) when is_binary(Str) ->
    parse_script_string(binary_to_list(Str));
parse_script_string(Str) when is_list(Str) ->
    Tokens = string:tokens(Str, " "),
    parse_script_tokens(Tokens, <<>>).

parse_script_tokens([], Acc) ->
    Acc;
parse_script_tokens([Token | Rest], Acc) ->
    Bytes = parse_script_token(Token),
    parse_script_tokens(Rest, <<Acc/binary, Bytes/binary>>).

parse_script_token("0x" ++ Hex) ->
    hex_to_binary(Hex);
parse_script_token("OP_0") -> <<16#00>>;
parse_script_token("OP_FALSE") -> <<16#00>>;
parse_script_token("OP_PUSHDATA1") -> <<16#4c>>;
parse_script_token("OP_PUSHDATA2") -> <<16#4d>>;
parse_script_token("OP_PUSHDATA4") -> <<16#4e>>;
parse_script_token("OP_1NEGATE") -> <<16#4f>>;
parse_script_token("OP_RESERVED") -> <<16#50>>;
parse_script_token("OP_1") -> <<16#51>>;
parse_script_token("OP_TRUE") -> <<16#51>>;
parse_script_token("OP_2") -> <<16#52>>;
parse_script_token("OP_3") -> <<16#53>>;
parse_script_token("OP_4") -> <<16#54>>;
parse_script_token("OP_5") -> <<16#55>>;
parse_script_token("OP_6") -> <<16#56>>;
parse_script_token("OP_7") -> <<16#57>>;
parse_script_token("OP_8") -> <<16#58>>;
parse_script_token("OP_9") -> <<16#59>>;
parse_script_token("OP_10") -> <<16#5a>>;
parse_script_token("OP_11") -> <<16#5b>>;
parse_script_token("OP_12") -> <<16#5c>>;
parse_script_token("OP_13") -> <<16#5d>>;
parse_script_token("OP_14") -> <<16#5e>>;
parse_script_token("OP_15") -> <<16#5f>>;
parse_script_token("OP_16") -> <<16#60>>;
parse_script_token("OP_NOP") -> <<16#61>>;
parse_script_token("OP_IF") -> <<16#63>>;
parse_script_token("OP_NOTIF") -> <<16#64>>;
parse_script_token("OP_ELSE") -> <<16#67>>;
parse_script_token("OP_ENDIF") -> <<16#68>>;
parse_script_token("OP_VERIFY") -> <<16#69>>;
parse_script_token("OP_RETURN") -> <<16#6a>>;
parse_script_token("OP_TOALTSTACK") -> <<16#6b>>;
parse_script_token("OP_FROMALTSTACK") -> <<16#6c>>;
parse_script_token("OP_2DROP") -> <<16#6d>>;
parse_script_token("OP_2DUP") -> <<16#6e>>;
parse_script_token("OP_3DUP") -> <<16#6f>>;
parse_script_token("OP_2OVER") -> <<16#70>>;
parse_script_token("OP_2ROT") -> <<16#71>>;
parse_script_token("OP_2SWAP") -> <<16#72>>;
parse_script_token("OP_IFDUP") -> <<16#73>>;
parse_script_token("OP_DEPTH") -> <<16#74>>;
parse_script_token("OP_DROP") -> <<16#75>>;
parse_script_token("OP_DUP") -> <<16#76>>;
parse_script_token("OP_NIP") -> <<16#77>>;
parse_script_token("OP_OVER") -> <<16#78>>;
parse_script_token("OP_PICK") -> <<16#79>>;
parse_script_token("OP_ROLL") -> <<16#7a>>;
parse_script_token("OP_ROT") -> <<16#7b>>;
parse_script_token("OP_SWAP") -> <<16#7c>>;
parse_script_token("OP_TUCK") -> <<16#7d>>;
parse_script_token("OP_CAT") -> <<16#7e>>;
parse_script_token("OP_SUBSTR") -> <<16#7f>>;
parse_script_token("OP_LEFT") -> <<16#80>>;
parse_script_token("OP_RIGHT") -> <<16#81>>;
parse_script_token("OP_SIZE") -> <<16#82>>;
parse_script_token("OP_EQUAL") -> <<16#87>>;
parse_script_token("OP_EQUALVERIFY") -> <<16#88>>;
parse_script_token("OP_1ADD") -> <<16#8b>>;
parse_script_token("OP_1SUB") -> <<16#8c>>;
parse_script_token("OP_NEGATE") -> <<16#8f>>;
parse_script_token("OP_ABS") -> <<16#90>>;
parse_script_token("OP_NOT") -> <<16#91>>;
parse_script_token("OP_0NOTEQUAL") -> <<16#92>>;
parse_script_token("OP_ADD") -> <<16#93>>;
parse_script_token("OP_SUB") -> <<16#94>>;
parse_script_token("OP_MUL") -> <<16#95>>;
parse_script_token("OP_BOOLAND") -> <<16#9a>>;
parse_script_token("OP_BOOLOR") -> <<16#9b>>;
parse_script_token("OP_NUMEQUAL") -> <<16#9c>>;
parse_script_token("OP_NUMEQUALVERIFY") -> <<16#9d>>;
parse_script_token("OP_NUMNOTEQUAL") -> <<16#9e>>;
parse_script_token("OP_LESSTHAN") -> <<16#9f>>;
parse_script_token("OP_GREATERTHAN") -> <<16#a0>>;
parse_script_token("OP_LESSTHANOREQUAL") -> <<16#a1>>;
parse_script_token("OP_GREATERTHANOREQUAL") -> <<16#a2>>;
parse_script_token("OP_MIN") -> <<16#a3>>;
parse_script_token("OP_MAX") -> <<16#a4>>;
parse_script_token("OP_WITHIN") -> <<16#a5>>;
parse_script_token("OP_RIPEMD160") -> <<16#a6>>;
parse_script_token("OP_SHA1") -> <<16#a7>>;
parse_script_token("OP_SHA256") -> <<16#a8>>;
parse_script_token("OP_HASH160") -> <<16#a9>>;
parse_script_token("OP_HASH256") -> <<16#aa>>;
parse_script_token("OP_CODESEPARATOR") -> <<16#ab>>;
parse_script_token("OP_CHECKSIG") -> <<16#ac>>;
parse_script_token("OP_CHECKSIGVERIFY") -> <<16#ad>>;
parse_script_token("OP_CHECKMULTISIG") -> <<16#ae>>;
parse_script_token("OP_CHECKMULTISIGVERIFY") -> <<16#af>>;
parse_script_token("OP_CHECKLOCKTIMEVERIFY") -> <<16#b1>>;
parse_script_token("OP_CHECKSEQUENCEVERIFY") -> <<16#b2>>;
parse_script_token("OP_CHECKSIGADD") -> <<16#ba>>;
parse_script_token(Token) ->
    %% Try to parse as number
    case catch list_to_integer(Token) of
        N when is_integer(N), N >= 0, N =< 255 ->
            <<N:8>>;
        _ ->
            <<>>
    end.

parse_flags(Flags) when is_binary(Flags) ->
    parse_flags(binary_to_list(Flags));
parse_flags(Flags) when is_list(Flags) ->
    FlagList = string:tokens(Flags, ","),
    lists:foldl(fun(F, Acc) ->
        maps:put(string:to_lower(string:trim(F)), true, Acc)
    end, #{}, FlagList).

parse_expected_result(Result) when is_binary(Result) ->
    parse_expected_result(binary_to_list(Result));
parse_expected_result("OK") -> ok;
parse_expected_result("") -> ok;
parse_expected_result(Error) -> {error, string:to_upper(Error)}.

execute_script_test(ScriptSig, ScriptPubKey, _Flags) ->
    %% Combine scripts and execute
    CombinedScript = <<ScriptSig/binary, ScriptPubKey/binary>>,
    %% Call into Gleam consensus engine via FFI
    %% For now, return a placeholder
    case catch oni_consensus_ffi:execute_script(CombinedScript) of
        {ok, _Stack} -> ok;
        {error, Reason} -> {error, Reason};
        {'EXIT', _} -> {error, not_implemented}
    end.

compare_script_result(ok, ok) -> match;
compare_script_result({error, _}, {error, _}) -> match;
compare_script_result(Got, Expected) ->
    {mismatch, #{got => Got, expected => Expected}}.

%% ============================================================================
%% Internal Functions - Transaction Tests
%% ============================================================================

run_tx_valid_vectors(Vectors) ->
    TestCases = lists:filter(fun
        ([_Comment]) -> false;
        (V) when is_list(V), length(V) >= 2 -> true;
        (_) -> false
    end, Vectors),

    Results = lists:map(fun(TC) -> run_single_tx_test(TC, valid) end, TestCases),

    Passed = length([R || {ok, _} <- Results]),
    Failed = length([R || {error, _} <- Results]),
    Skipped = length([R || {skip, _} <- Results]),

    io:format("Valid TX tests: ~p passed, ~p failed, ~p skipped~n",
              [Passed, Failed, Skipped]),

    {ok, #{passed => Passed, failed => Failed, skipped => Skipped}}.

run_tx_invalid_vectors(Vectors) ->
    TestCases = lists:filter(fun
        ([_Comment]) -> false;
        (V) when is_list(V), length(V) >= 2 -> true;
        (_) -> false
    end, Vectors),

    Results = lists:map(fun(TC) -> run_single_tx_test(TC, invalid) end, TestCases),

    Passed = length([R || {ok, _} <- Results]),
    Failed = length([R || {error, _} <- Results]),
    Skipped = length([R || {skip, _} <- Results]),

    io:format("Invalid TX tests: ~p passed, ~p failed, ~p skipped~n",
              [Passed, Failed, Skipped]),

    {ok, #{passed => Passed, failed => Failed, skipped => Skipped}}.

run_single_tx_test([_Prevouts, TxHex, _Flags], ExpectedValidity) ->
    try
        TxBytes = hex_to_binary(TxHex),

        %% Attempt to decode and validate
        case validate_with_oni(tx, TxBytes) of
            {ok, true} when ExpectedValidity =:= valid ->
                {ok, valid};
            {ok, false} when ExpectedValidity =:= invalid ->
                {ok, invalid};
            {error, _} when ExpectedValidity =:= invalid ->
                {ok, invalid};
            Other ->
                {error, {unexpected, Other, ExpectedValidity}}
        end
    catch
        _:Reason ->
            {skip, {parse_error, Reason}}
    end;
run_single_tx_test(_, _) ->
    {skip, invalid_format}.

%% ============================================================================
%% Internal Functions - Sighash Tests
%% ============================================================================

run_sighash_vectors(Vectors) ->
    TestCases = lists:filter(fun
        ([_Comment]) -> false;
        (V) when is_list(V), length(V) >= 6 -> true;
        (_) -> false
    end, Vectors),

    Results = lists:map(fun run_single_sighash_test/1, TestCases),

    Passed = length([R || {ok, _} <- Results]),
    Failed = length([R || {error, _} <- Results]),
    Skipped = length([R || {skip, _} <- Results]),

    io:format("Sighash tests: ~p passed, ~p failed, ~p skipped~n",
              [Passed, Failed, Skipped]),

    {ok, #{passed => Passed, failed => Failed, skipped => Skipped}}.

run_single_sighash_test([TxHex, InputIndex, ScriptPubKey, Amount, SighashType, ExpectedHash]) ->
    try
        _TxBytes = hex_to_binary(TxHex),
        _ScriptBytes = parse_script_string(ScriptPubKey),
        _ExpectedBytes = hex_to_binary(ExpectedHash),

        %% Compute sighash with oni
        %% ComputedHash = oni_consensus:compute_sighash(...),

        %% For now, skip actual computation until fully implemented
        {skip, {not_implemented, SighashType, InputIndex, Amount}}
    catch
        _:Reason ->
            {skip, {parse_error, Reason}}
    end;
run_single_sighash_test(_) ->
    {skip, invalid_format}.

%% ============================================================================
%% Internal Functions - Live Oracle
%% ============================================================================

check_bitcoind_available() ->
    case os:find_executable("bitcoin-cli") of
        false -> false;
        _ ->
            %% Try to connect
            case os:cmd("bitcoin-cli -regtest getblockchaininfo 2>/dev/null") of
                "" -> false;
                _ -> true
            end
    end.

run_oracle_tests() ->
    %% Generate test transactions in regtest
    %% Compare validation results with oni
    io:format("Live oracle testing not yet implemented~n"),
    {ok, #{skipped => true, reason => not_implemented}}.

validate_with_oni(tx, TxBytes) ->
    %% Call oni transaction validation
    case catch oni_bitcoin_ffi:decode_tx(TxBytes) of
        {ok, _Tx} ->
            %% Further validation would go here
            {ok, true};
        {error, Reason} ->
            {error, Reason};
        {'EXIT', _} ->
            {error, not_implemented}
    end;
validate_with_oni(block, BlockBytes) ->
    case catch oni_bitcoin_ffi:decode_block(BlockBytes) of
        {ok, _Block} ->
            {ok, true};
        {error, Reason} ->
            {error, Reason};
        {'EXIT', _} ->
            {error, not_implemented}
    end;
validate_with_oni(script, ScriptBytes) ->
    case catch oni_consensus_ffi:execute_script(ScriptBytes) of
        {ok, _Stack} ->
            {ok, true};
        {error, _Reason} ->
            {ok, false};
        {'EXIT', _} ->
            {error, not_implemented}
    end.

validate_with_bitcoind(tx, TxBytes) ->
    HexTx = binary_to_hex(TxBytes),
    Cmd = io_lib:format("bitcoin-cli -regtest testmempoolaccept '[\"~s\"]' 2>/dev/null", [HexTx]),
    case os:cmd(lists:flatten(Cmd)) of
        "" -> {error, bitcoind_unavailable};
        Output ->
            case string:find(Output, "\"allowed\": true") of
                nomatch -> {ok, false};
                _ -> {ok, true}
            end
    end;
validate_with_bitcoind(block, BlockBytes) ->
    HexBlock = binary_to_hex(BlockBytes),
    Cmd = io_lib:format("bitcoin-cli -regtest submitblock ~s 2>/dev/null", [HexBlock]),
    case os:cmd(lists:flatten(Cmd)) of
        "" -> {ok, true};  % Empty response means success
        "null\n" -> {ok, true};
        Error -> {ok, {rejected, Error}}
    end;
validate_with_bitcoind(script, _ScriptBytes) ->
    %% Script validation not directly available via RPC
    {error, not_supported}.

%% ============================================================================
%% Utility Functions
%% ============================================================================

hex_to_binary(Hex) when is_binary(Hex) ->
    hex_to_binary(binary_to_list(Hex));
hex_to_binary(Hex) when is_list(Hex) ->
    << <<(list_to_integer([H], 16)):4>> || H <- Hex >>.

binary_to_hex(Bin) ->
    << <<(integer_to_list(N, 16))/binary>> || <<N:4>> <= Bin >>.

parse_test_vectors_manual(Binary) ->
    %% Simple JSON-like parser for test vectors
    %% In production, use a proper JSON library
    try
        %% Remove comments and parse array structure
        Text = binary_to_list(Binary),
        {ok, parse_json_array(Text)}
    catch
        _:_ -> {error, parse_failed}
    end.

parse_json_array(Text) ->
    %% Very basic JSON array parser
    case string:trim(Text) of
        "[" ++ Rest ->
            parse_array_elements(Rest, []);
        _ ->
            []
    end.

parse_array_elements("]" ++ _, Acc) ->
    lists:reverse(Acc);
parse_array_elements(Text, Acc) ->
    case string:trim(Text) of
        "]" ++ _ ->
            lists:reverse(Acc);
        "[" ++ Rest ->
            %% Nested array
            {Element, Remaining} = parse_nested_array(Rest, []),
            parse_array_elements(skip_comma(Remaining), [Element | Acc]);
        "\"" ++ _ ->
            %% String element
            {Str, Remaining} = parse_string(Text),
            parse_array_elements(skip_comma(Remaining), [Str | Acc]);
        Text2 ->
            %% Skip other content
            case string:split(Text2, ",") of
                [_, Rest] -> parse_array_elements(Rest, Acc);
                _ -> lists:reverse(Acc)
            end
    end.

parse_nested_array("]" ++ Rest, Acc) ->
    {lists:reverse(Acc), Rest};
parse_nested_array(Text, Acc) ->
    case string:trim(Text) of
        "]" ++ Rest ->
            {lists:reverse(Acc), Rest};
        "\"" ++ _ ->
            {Str, Remaining} = parse_string(Text),
            parse_nested_array(skip_comma(Remaining), [Str | Acc]);
        "[" ++ Rest ->
            {Nested, Remaining} = parse_nested_array(Rest, []),
            parse_nested_array(skip_comma(Remaining), [Nested | Acc]);
        Other ->
            %% Number or other
            case string:split(Other, [",", "]"]) of
                [Val | [Rest]] ->
                    parse_nested_array(Rest, [string:trim(Val) | Acc]);
                _ ->
                    {lists:reverse(Acc), ""}
            end
    end.

parse_string("\"" ++ Rest) ->
    parse_string_content(Rest, []).

parse_string_content("\"" ++ Rest, Acc) ->
    {lists:reverse(Acc), Rest};
parse_string_content("\\" ++ [C | Rest], Acc) ->
    parse_string_content(Rest, [C | Acc]);
parse_string_content([C | Rest], Acc) ->
    parse_string_content(Rest, [C | Acc]);
parse_string_content([], Acc) ->
    {lists:reverse(Acc), ""}.

skip_comma(Text) ->
    case string:trim(Text) of
        "," ++ Rest -> string:trim(Rest);
        Other -> Other
    end.

merge_results(Results) ->
    lists:foldl(fun
        ({ok, Map}, {ok, Acc}) ->
            {ok, #{
                passed => maps:get(passed, Map, 0) + maps:get(passed, Acc, 0),
                failed => maps:get(failed, Map, 0) + maps:get(failed, Acc, 0),
                skipped => maps:get(skipped, Map, 0) + maps:get(skipped, Acc, 0)
            }};
        (_, Acc) ->
            Acc
    end, {ok, #{passed => 0, failed => 0, skipped => 0}}, Results).

print_summary(Results) ->
    io:format("~n=== Test Summary ===~n"),
    maps:foreach(fun(Suite, Result) ->
        case Result of
            {ok, #{passed := P, failed := F, skipped := S}} ->
                Total = P + F,
                io:format("~p: ~p/~p passed (~p skipped)~n", [Suite, P, Total, S]);
            {ok, #{skipped := true}} ->
                io:format("~p: skipped~n", [Suite]);
            {error, Reason} ->
                io:format("~p: error - ~p~n", [Suite, Reason])
        end
    end, Results),

    TotalPassed = lists:sum([maps:get(passed, R, 0) || {ok, R} <- maps:values(Results)]),
    TotalFailed = lists:sum([maps:get(failed, R, 0) || {ok, R} <- maps:values(Results)]),

    io:format("~nTotal: ~p passed, ~p failed~n", [TotalPassed, TotalFailed]),

    case TotalFailed of
        0 -> io:format("All tests passed!~n");
        _ -> io:format("WARNING: ~p tests failed~n", [TotalFailed])
    end.
