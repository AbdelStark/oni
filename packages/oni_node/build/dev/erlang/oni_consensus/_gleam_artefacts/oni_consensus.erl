-module(oni_consensus).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/oni_consensus.gleam").
-export([opcode_from_byte/1, opcode_is_disabled/1, default_script_flags/0, script_context_new/2, validate_tx_structure/1, tx_has_duplicate_inputs/1, tx_is_coinbase/1, validate_block_header/1, target_from_compact/1, validate_pow/2, compute_merkle_root/1, compute_witness_commitment/2, sighash_type_from_byte/1, validate_txid/1, parse_script/1, encode_script_num/1, decode_script_num/1, execute_script/1, verify_script/4, calculate_block_weight/1, validate_block_weight/1]).
-export_type([consensus_error/0, opcode/0, script_flags/0, script_context/0, target/0, sighash_type/0, script_element/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type consensus_error() :: script_invalid |
    script_disabled_opcode |
    script_stack_underflow |
    script_stack_overflow |
    script_verify_failed |
    script_equal_verify_failed |
    script_check_sig_failed |
    script_check_multisig_failed |
    script_push_size_exceeded |
    script_op_count_exceeded |
    script_bad_opcode |
    script_minimal_data |
    script_witness_malleated |
    script_witness_unexpected |
    script_clean_stack |
    tx_missing_inputs |
    tx_duplicate_inputs |
    tx_empty_inputs |
    tx_empty_outputs |
    tx_oversized |
    tx_bad_version |
    tx_invalid_amount |
    tx_output_value_overflow |
    tx_input_not_found |
    tx_input_spent |
    tx_inputs_not_available |
    tx_premature_coinbase_spend |
    tx_sequence_lock_not_met |
    tx_lock_time_not_met |
    tx_sig_op_count_exceeded |
    block_invalid_header |
    block_invalid_po_w |
    block_invalid_merkle_root |
    block_invalid_witness_commitment |
    block_timestamp_too_old |
    block_timestamp_too_far |
    block_bad_version |
    block_too_large |
    block_weight_exceeded |
    block_bad_coinbase |
    block_duplicate_tx |
    block_bad_prev_block |
    {other, binary()}.

-type opcode() :: op_false |
    {op_push_bytes, integer()} |
    op_push_data1 |
    op_push_data2 |
    op_push_data4 |
    op1_negate |
    op_reserved |
    op_true |
    {op_num, integer()} |
    op_nop |
    op_ver |
    op_if |
    op_not_if |
    op_ver_if |
    op_ver_not_if |
    op_else |
    op_end_if |
    op_verify |
    op_return |
    op_to_alt_stack |
    op_from_alt_stack |
    op2_drop |
    op2_dup |
    op3_dup |
    op2_over |
    op2_rot |
    op2_swap |
    op_if_dup |
    op_depth |
    op_drop |
    op_dup |
    op_nip |
    op_over |
    op_pick |
    op_roll |
    op_rot |
    op_swap |
    op_tuck |
    op_cat |
    op_substr |
    op_left |
    op_right |
    op_size |
    op_invert |
    op_and |
    op_or |
    op_xor |
    op_equal |
    op_equal_verify |
    op_reserved1 |
    op_reserved2 |
    op1_add |
    op1_sub |
    op2_mul |
    op2_div |
    op_negate |
    op_abs |
    op_not |
    op0_not_equal |
    op_add |
    op_sub |
    op_mul |
    op_div |
    op_mod |
    op_l_shift |
    op_r_shift |
    op_bool_and |
    op_bool_or |
    op_num_equal |
    op_num_equal_verify |
    op_num_not_equal |
    op_less_than |
    op_greater_than |
    op_less_than_or_equal |
    op_greater_than_or_equal |
    op_min |
    op_max |
    op_within |
    op_ripe_md160 |
    op_sha1 |
    op_sha256 |
    op_hash160 |
    op_hash256 |
    op_code_separator |
    op_check_sig |
    op_check_sig_verify |
    op_check_multi_sig |
    op_check_multi_sig_verify |
    op_nop1 |
    op_check_lock_time_verify |
    op_check_sequence_verify |
    op_nop4 |
    op_nop5 |
    op_nop6 |
    op_nop7 |
    op_nop8 |
    op_nop9 |
    op_nop10 |
    op_check_sig_add |
    {op_success, integer()} |
    op_invalid_opcode.

-type script_flags() :: {script_flags,
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean(),
        boolean()}.

-type script_context() :: {script_context,
        list(bitstring()),
        list(bitstring()),
        integer(),
        bitstring(),
        integer(),
        integer(),
        script_flags(),
        list(boolean())}.

-type target() :: {target, bitstring()}.

-type sighash_type() :: sighash_all |
    sighash_none |
    sighash_single |
    {sighash_anyone_can_pay, sighash_type()}.

-type script_element() :: {op_element, opcode()} | {data_element, bitstring()}.

-file("src/oni_consensus.gleam", 205).
?DOC(" Decode an opcode from a byte\n").
-spec opcode_from_byte(integer()) -> opcode().
opcode_from_byte(B) ->
    case B of
        16#00 ->
            op_false;

        N when (N >= 16#01) andalso (N =< 16#4b) ->
            {op_push_bytes, N};

        16#4c ->
            op_push_data1;

        16#4d ->
            op_push_data2;

        16#4e ->
            op_push_data4;

        16#4f ->
            op1_negate;

        16#50 ->
            op_reserved;

        16#51 ->
            op_true;

        N@1 when (N@1 >= 16#52) andalso (N@1 =< 16#60) ->
            {op_num, N@1 - 16#50};

        16#61 ->
            op_nop;

        16#62 ->
            op_ver;

        16#63 ->
            op_if;

        16#64 ->
            op_not_if;

        16#65 ->
            op_ver_if;

        16#66 ->
            op_ver_not_if;

        16#67 ->
            op_else;

        16#68 ->
            op_end_if;

        16#69 ->
            op_verify;

        16#6a ->
            op_return;

        16#6b ->
            op_to_alt_stack;

        16#6c ->
            op_from_alt_stack;

        16#6d ->
            op2_drop;

        16#6e ->
            op2_dup;

        16#6f ->
            op3_dup;

        16#70 ->
            op2_over;

        16#71 ->
            op2_rot;

        16#72 ->
            op2_swap;

        16#73 ->
            op_if_dup;

        16#74 ->
            op_depth;

        16#75 ->
            op_drop;

        16#76 ->
            op_dup;

        16#77 ->
            op_nip;

        16#78 ->
            op_over;

        16#79 ->
            op_pick;

        16#7a ->
            op_roll;

        16#7b ->
            op_rot;

        16#7c ->
            op_swap;

        16#7d ->
            op_tuck;

        16#7e ->
            op_cat;

        16#7f ->
            op_substr;

        16#80 ->
            op_left;

        16#81 ->
            op_right;

        16#82 ->
            op_size;

        16#83 ->
            op_invert;

        16#84 ->
            op_and;

        16#85 ->
            op_or;

        16#86 ->
            op_xor;

        16#87 ->
            op_equal;

        16#88 ->
            op_equal_verify;

        16#89 ->
            op_reserved1;

        16#8a ->
            op_reserved2;

        16#8b ->
            op1_add;

        16#8c ->
            op1_sub;

        16#8d ->
            op2_mul;

        16#8e ->
            op2_div;

        16#8f ->
            op_negate;

        16#90 ->
            op_abs;

        16#91 ->
            op_not;

        16#92 ->
            op0_not_equal;

        16#93 ->
            op_add;

        16#94 ->
            op_sub;

        16#95 ->
            op_mul;

        16#96 ->
            op_div;

        16#97 ->
            op_mod;

        16#98 ->
            op_l_shift;

        16#99 ->
            op_r_shift;

        16#9a ->
            op_bool_and;

        16#9b ->
            op_bool_or;

        16#9c ->
            op_num_equal;

        16#9d ->
            op_num_equal_verify;

        16#9e ->
            op_num_not_equal;

        16#9f ->
            op_less_than;

        16#a0 ->
            op_greater_than;

        16#a1 ->
            op_less_than_or_equal;

        16#a2 ->
            op_greater_than_or_equal;

        16#a3 ->
            op_min;

        16#a4 ->
            op_max;

        16#a5 ->
            op_within;

        16#a6 ->
            op_ripe_md160;

        16#a7 ->
            op_sha1;

        16#a8 ->
            op_sha256;

        16#a9 ->
            op_hash160;

        16#aa ->
            op_hash256;

        16#ab ->
            op_code_separator;

        16#ac ->
            op_check_sig;

        16#ad ->
            op_check_sig_verify;

        16#ae ->
            op_check_multi_sig;

        16#af ->
            op_check_multi_sig_verify;

        16#b0 ->
            op_nop1;

        16#b1 ->
            op_check_lock_time_verify;

        16#b2 ->
            op_check_sequence_verify;

        16#b3 ->
            op_nop4;

        16#b4 ->
            op_nop5;

        16#b5 ->
            op_nop6;

        16#b6 ->
            op_nop7;

        16#b7 ->
            op_nop8;

        16#b8 ->
            op_nop9;

        16#b9 ->
            op_nop10;

        16#ba ->
            op_check_sig_add;

        N@2 when (N@2 >= 16#bb) andalso (N@2 =< 16#fe) ->
            {op_success, N@2};

        _ ->
            op_invalid_opcode
    end.

-file("src/oni_consensus.gleam", 312).
?DOC(" Check if opcode is disabled\n").
-spec opcode_is_disabled(opcode()) -> boolean().
opcode_is_disabled(Op) ->
    case Op of
        op_cat ->
            true;

        op_substr ->
            true;

        op_left ->
            true;

        op_right ->
            true;

        op_invert ->
            true;

        op_and ->
            true;

        op_or ->
            true;

        op_xor ->
            true;

        op2_mul ->
            true;

        op2_div ->
            true;

        op_mul ->
            true;

        op_div ->
            true;

        op_mod ->
            true;

        op_l_shift ->
            true;

        op_r_shift ->
            true;

        _ ->
            false
    end.

-file("src/oni_consensus.gleam", 351).
?DOC(" Default flags for mainnet consensus\n").
-spec default_script_flags() -> script_flags().
default_script_flags() ->
    {script_flags,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        false}.

-file("src/oni_consensus.gleam", 389).
?DOC(" Create a new script context\n").
-spec script_context_new(bitstring(), script_flags()) -> script_context().
script_context_new(Script, Flags) ->
    {script_context, [], [], 0, Script, 0, 0, Flags, []}.

-file("src/oni_consensus.gleam", 459).
-spec validate_tx_outputs(list(oni_bitcoin:tx_out())) -> {ok, nil} |
    {error, consensus_error()}.
validate_tx_outputs(Outputs) ->
    Total = gleam@list:fold(Outputs, {ok, 0}, fun(Acc, Out) -> case Acc of
                {error, E} ->
                    {error, E};

                {ok, Sum} ->
                    Sats = oni_bitcoin:amount_to_sats(erlang:element(2, Out)),
                    case (Sats >= 0) andalso (Sats =< 2100000000000000) of
                        true ->
                            New_sum = Sum + Sats,
                            case New_sum =< 2100000000000000 of
                                true ->
                                    {ok, New_sum};

                                false ->
                                    {error, tx_output_value_overflow}
                            end;

                        false ->
                            {error, tx_invalid_amount}
                    end
            end end),
    case Total of
        {ok, _} ->
            {ok, nil};

        {error, E@1} ->
            {error, E@1}
    end.

-file("src/oni_consensus.gleam", 445).
?DOC(" Validate transaction structure (no UTXO context)\n").
-spec validate_tx_structure(oni_bitcoin:transaction()) -> {ok, nil} |
    {error, consensus_error()}.
validate_tx_structure(Tx) ->
    case gleam@list:is_empty(erlang:element(3, Tx)) of
        true ->
            {error, tx_empty_inputs};

        false ->
            case gleam@list:is_empty(erlang:element(4, Tx)) of
                true ->
                    {error, tx_empty_outputs};

                false ->
                    validate_tx_outputs(erlang:element(4, Tx))
            end
    end.

-file("src/oni_consensus.gleam", 487).
?DOC(" Check for duplicate inputs\n").
-spec tx_has_duplicate_inputs(oni_bitcoin:transaction()) -> boolean().
tx_has_duplicate_inputs(Tx) ->
    Prevouts = gleam@list:map(
        erlang:element(3, Tx),
        fun(Input) -> erlang:element(2, Input) end
    ),
    Unique = gleam@list:unique(Prevouts),
    gleam@list:length(Prevouts) /= gleam@list:length(Unique).

-file("src/oni_consensus.gleam", 494).
?DOC(" Check if transaction is coinbase\n").
-spec tx_is_coinbase(oni_bitcoin:transaction()) -> boolean().
tx_is_coinbase(Tx) ->
    case erlang:element(3, Tx) of
        [Input] ->
            oni_bitcoin:outpoint_is_null(erlang:element(2, Input));

        _ ->
            false
    end.

-file("src/oni_consensus.gleam", 506).
?DOC(" Validate block header structure\n").
-spec validate_block_header(oni_bitcoin:block_header()) -> {ok, nil} |
    {error, consensus_error()}.
validate_block_header(_) ->
    {ok, nil}.

-file("src/oni_consensus.gleam", 575).
-spec create_zero_bytes(integer(), bitstring()) -> bitstring().
create_zero_bytes(N, Acc) ->
    case N of
        0 ->
            Acc;

        _ ->
            create_zero_bytes(N - 1, gleam@bit_array:append(Acc, <<0:8>>))
    end.

-file("src/oni_consensus.gleam", 559).
-spec create_target_bytes(integer(), integer()) -> bitstring().
create_target_bytes(Mantissa, Shift) ->
    Zeros_after = Shift,
    Zeros_before = (32 - 3) - Zeros_after,
    case (Zeros_before >= 0) andalso (Zeros_after >= 0) of
        true ->
            Before = create_zero_bytes(Zeros_before, <<>>),
            After = create_zero_bytes(Zeros_after, <<>>),
            M = <<Mantissa:24/big>>,
            gleam_stdlib:bit_array_concat([Before, M, After]);

        false ->
            <<>>
    end.

-file("src/oni_consensus.gleam", 539).
?DOC(" Decode compact difficulty target from nBits\n").
-spec target_from_compact(integer()) -> target().
target_from_compact(Compact) ->
    Exponent = Compact div 16#1000000,
    Mantissa = Compact rem 16#1000000,
    Value = case Mantissa > 16#7FFFFF of
        true ->
            0;

        false ->
            Mantissa
    end,
    Shift = Exponent - 3,
    Target_bytes = case Shift >= 0 of
        true ->
            create_target_bytes(Value, Shift);

        false ->
            <<>>
    end,
    {target, Target_bytes}.

-file("src/oni_consensus.gleam", 594).
-spec compare_bytes(bitstring(), bitstring()) -> integer().
compare_bytes(A, B) ->
    case {A, B} of
        {<<Ah:8, Arest/bitstring>>, <<Bh:8, Brest/bitstring>>} ->
            case Ah - Bh of
                0 ->
                    compare_bytes(Arest, Brest);

                Diff ->
                    Diff
            end;

        {<<_:8, _/bitstring>>, <<>>} ->
            1;

        {<<>>, <<_:8, _/bitstring>>} ->
            -1;

        {<<>>, <<>>} ->
            0;

        {_, _} ->
            0
    end.

-file("src/oni_consensus.gleam", 583).
?DOC(" Compare block hash against target (hash <= target means valid PoW)\n").
-spec validate_pow(oni_bitcoin:block_hash(), integer()) -> {ok, nil} |
    {error, consensus_error()}.
validate_pow(Hash, Bits) ->
    Target = target_from_compact(Bits),
    Hash_bytes = oni_bitcoin:reverse_bytes(
        erlang:element(2, erlang:element(2, Hash))
    ),
    case compare_bytes(Hash_bytes, erlang:element(2, Target)) of
        Order when Order =< 0 ->
            {ok, nil};

        _ ->
            {error, block_invalid_po_w}
    end.

-file("src/oni_consensus.gleam", 643).
-spec merkle_hash_pair(oni_bitcoin:hash256(), oni_bitcoin:hash256()) -> oni_bitcoin:hash256().
merkle_hash_pair(A, B) ->
    Combined = gleam_stdlib:bit_array_concat(
        [erlang:element(2, A), erlang:element(2, B)]
    ),
    oni_bitcoin:hash256_digest(Combined).

-file("src/oni_consensus.gleam", 625).
-spec merkle_combine_level(
    list(oni_bitcoin:hash256()),
    list(oni_bitcoin:hash256())
) -> list(oni_bitcoin:hash256()).
merkle_combine_level(Hashes, Acc) ->
    case Hashes of
        [] ->
            gleam@list:reverse(Acc);

        [Single] ->
            Combined = merkle_hash_pair(Single, Single),
            gleam@list:reverse([Combined | Acc]);

        [First, Second | Rest] ->
            Combined@1 = merkle_hash_pair(First, Second),
            merkle_combine_level(Rest, [Combined@1 | Acc])
    end.

-file("src/oni_consensus.gleam", 614).
?DOC(" Compute merkle root of transaction hashes\n").
-spec compute_merkle_root(list(oni_bitcoin:hash256())) -> oni_bitcoin:hash256().
compute_merkle_root(Txids) ->
    case Txids of
        [] ->
            {hash256, <<0:256>>};

        [Single] ->
            Single;

        _ ->
            Next_level = merkle_combine_level(Txids, []),
            compute_merkle_root(Next_level)
    end.

-file("src/oni_consensus.gleam", 656).
?DOC(" Compute witness commitment\n").
-spec compute_witness_commitment(oni_bitcoin:hash256(), bitstring()) -> oni_bitcoin:hash256().
compute_witness_commitment(Wtxid_root, Witness_nonce) ->
    Commitment_data = gleam_stdlib:bit_array_concat(
        [erlang:element(2, Wtxid_root), Witness_nonce]
    ),
    oni_bitcoin:hash256_digest(Commitment_data).

-file("src/oni_consensus.gleam", 683).
?DOC(" Parse sighash type from byte\n").
-spec sighash_type_from_byte(integer()) -> sighash_type().
sighash_type_from_byte(B) ->
    Base = B rem 16#80,
    Anyonecanpay = B >= 16#80,
    Base_type = case Base of
        16#02 ->
            sighash_none;

        16#03 ->
            sighash_single;

        _ ->
            sighash_all
    end,
    case Anyonecanpay of
        true ->
            {sighash_anyone_can_pay, Base_type};

        false ->
            Base_type
    end.

-file("src/oni_consensus.gleam", 704).
?DOC(" Validate a txid (placeholder)\n").
-spec validate_txid(oni_bitcoin:txid()) -> {ok, nil} |
    {error, consensus_error()}.
validate_txid(_) ->
    {ok, nil}.

-file("src/oni_consensus.gleam", 836).
-spec extract_bytes(bitstring(), integer()) -> {ok, {bitstring(), bitstring()}} |
    {error, nil}.
extract_bytes(Data, N) ->
    case gleam_stdlib:bit_array_slice(Data, 0, N) of
        {ok, Extracted} ->
            Remaining_size = erlang:byte_size(Data) - N,
            case gleam_stdlib:bit_array_slice(Data, N, Remaining_size) of
                {ok, Remaining} ->
                    {ok, {Extracted, Remaining}};

                {error, _} ->
                    {ok, {Extracted, <<>>}}
            end;

        {error, _} ->
            {error, nil}
    end.

-file("src/oni_consensus.gleam", 767).
-spec parse_script_loop(bitstring(), list(script_element())) -> {ok,
        list(script_element())} |
    {error, consensus_error()}.
parse_script_loop(Remaining, Acc) ->
    case Remaining of
        <<>> ->
            {ok, gleam@list:reverse(Acc)};

        <<Opcode:8, Rest/bitstring>> ->
            Op = opcode_from_byte(Opcode),
            case Op of
                {op_push_bytes, N} ->
                    case extract_bytes(Rest, N) of
                        {ok, {Data, Remaining2}} ->
                            parse_script_loop(
                                Remaining2,
                                [{data_element, Data} | Acc]
                            );

                        {error, _} ->
                            {error, script_push_size_exceeded}
                    end;

                op_push_data1 ->
                    case Rest of
                        <<Len:8, After_len/bitstring>> ->
                            case extract_bytes(After_len, Len) of
                                {ok, {Data@1, Remaining2@1}} ->
                                    parse_script_loop(
                                        Remaining2@1,
                                        [{data_element, Data@1} | Acc]
                                    );

                                {error, _} ->
                                    {error, script_push_size_exceeded}
                            end;

                        _ ->
                            {error, script_invalid}
                    end;

                op_push_data2 ->
                    case Rest of
                        <<Len@1:16/little, After_len@1/bitstring>> ->
                            case extract_bytes(After_len@1, Len@1) of
                                {ok, {Data@2, Remaining2@2}} ->
                                    parse_script_loop(
                                        Remaining2@2,
                                        [{data_element, Data@2} | Acc]
                                    );

                                {error, _} ->
                                    {error, script_push_size_exceeded}
                            end;

                        _ ->
                            {error, script_invalid}
                    end;

                op_push_data4 ->
                    case Rest of
                        <<Len@2:32/little, After_len@2/bitstring>> ->
                            case extract_bytes(After_len@2, Len@2) of
                                {ok, {Data@3, Remaining2@3}} ->
                                    parse_script_loop(
                                        Remaining2@3,
                                        [{data_element, Data@3} | Acc]
                                    );

                                {error, _} ->
                                    {error, script_push_size_exceeded}
                            end;

                        _ ->
                            {error, script_invalid}
                    end;

                _ ->
                    parse_script_loop(Rest, [{op_element, Op} | Acc])
            end;

        _ ->
            {error, script_invalid}
    end.

-file("src/oni_consensus.gleam", 763).
?DOC(" Parse a script into elements\n").
-spec parse_script(bitstring()) -> {ok, list(script_element())} |
    {error, consensus_error()}.
parse_script(Script) ->
    parse_script_loop(Script, []).

-file("src/oni_consensus.gleam", 920).
-spec is_executing(list(boolean())) -> boolean().
is_executing(Exec_stack) ->
    gleam@list:all(Exec_stack, fun(X) -> X end).

-file("src/oni_consensus.gleam", 924).
-spec is_push_op(opcode()) -> boolean().
is_push_op(Op) ->
    case Op of
        op_false ->
            true;

        {op_push_bytes, _} ->
            true;

        op_push_data1 ->
            true;

        op_push_data2 ->
            true;

        op_push_data4 ->
            true;

        op1_negate ->
            true;

        op_true ->
            true;

        {op_num, _} ->
            true;

        _ ->
            false
    end.

-file("src/oni_consensus.gleam", 985).
?DOC(" Execute ELSE\n").
-spec execute_else(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_else(Ctx) ->
    case erlang:element(9, Ctx) of
        [] ->
            {error, script_invalid};

        [Current | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        erlang:element(2, _record),
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        [not Current | Rest]}
                end}
    end.

-file("src/oni_consensus.gleam", 996).
?DOC(" Execute ENDIF\n").
-spec execute_endif(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_endif(Ctx) ->
    case erlang:element(9, Ctx) of
        [] ->
            {error, script_invalid};

        [_ | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        erlang:element(2, _record),
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        Rest}
                end}
    end.

-file("src/oni_consensus.gleam", 1014).
-spec is_all_zeros(bitstring()) -> boolean().
is_all_zeros(Data) ->
    case Data of
        <<>> ->
            true;

        <<0:8, Rest/bitstring>> ->
            is_all_zeros(Rest);

        <<16#80:8>> ->
            true;

        _ ->
            false
    end.

-file("src/oni_consensus.gleam", 1006).
?DOC(" Check if a stack element is truthy\n").
-spec is_truthy(bitstring()) -> boolean().
is_truthy(Data) ->
    case erlang:byte_size(Data) of
        0 ->
            false;

        _ ->
            not is_all_zeros(Data)
    end.

-file("src/oni_consensus.gleam", 953).
?DOC(" Execute IF/NOTIF\n").
-spec execute_if(script_context(), opcode(), boolean()) -> {ok,
        script_context()} |
    {error, consensus_error()}.
execute_if(Ctx, Op, Should_execute) ->
    case Should_execute of
        false ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        erlang:element(2, _record),
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        [false | erlang:element(9, Ctx)]}
                end};

        true ->
            case erlang:element(2, Ctx) of
                [] ->
                    {error, script_stack_underflow};

                [Top | Rest] ->
                    Condition = case Op of
                        op_if ->
                            is_truthy(Top);

                        op_not_if ->
                            not is_truthy(Top);

                        _ ->
                            false
                    end,
                    {ok,
                        begin
                            _record@1 = Ctx,
                            {script_context,
                                Rest,
                                erlang:element(3, _record@1),
                                erlang:element(4, _record@1),
                                erlang:element(5, _record@1),
                                erlang:element(6, _record@1),
                                erlang:element(7, _record@1),
                                erlang:element(8, _record@1),
                                [Condition | erlang:element(9, Ctx)]}
                        end}
            end
    end.

-file("src/oni_consensus.gleam", 1133).
-spec execute_dup(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_dup(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Top | _] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [Top | erlang:element(2, Ctx)],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1140).
-spec execute_drop(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_drop(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [_ | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        Rest,
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1147).
-spec execute_2dup(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_2dup(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [A, B, A, B | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1154).
-spec execute_2drop(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_2drop(Ctx) ->
    case erlang:element(2, Ctx) of
        [_, _ | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        Rest,
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1161).
-spec execute_3dup(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_3dup(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B, C | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [A, B, C, A, B, C | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1168).
-spec execute_swap(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_swap(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [B, A | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1175).
-spec execute_over(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_over(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [B, A, B | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1182).
-spec execute_rot(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_rot(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B, C | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [C, A, B | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1189).
-spec execute_nip(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_nip(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, _ | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [A | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1196).
-spec execute_tuck(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_tuck(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [A, B, A | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1262).
-spec execute_ifdup(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_ifdup(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Top | _] ->
            case is_truthy(Top) of
                true ->
                    {ok,
                        begin
                            _record = Ctx,
                            {script_context,
                                [Top | erlang:element(2, Ctx)],
                                erlang:element(3, _record),
                                erlang:element(4, _record),
                                erlang:element(5, _record),
                                erlang:element(6, _record),
                                erlang:element(7, _record),
                                erlang:element(8, _record),
                                erlang:element(9, _record)}
                        end};

                false ->
                    {ok, Ctx}
            end
    end.

-file("src/oni_consensus.gleam", 1274).
-spec execute_toaltstack(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_toaltstack(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Top | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        Rest,
                        [Top | erlang:element(3, Ctx)],
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1281).
-spec execute_fromaltstack(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_fromaltstack(Ctx) ->
    case erlang:element(3, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Top | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [Top | erlang:element(2, Ctx)],
                        Rest,
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1288).
-spec execute_2over(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_2over(Ctx) ->
    case erlang:element(2, Ctx) of
        [_, _, C, D | _] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [C, D | erlang:element(2, Ctx)],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1295).
-spec execute_2rot(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_2rot(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B, C, D, E, F | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [E, F, A, B, C, D | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1302).
-spec execute_2swap(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_2swap(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B, C, D | Rest] ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [C, D, A, B | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1313).
-spec execute_equal(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_equal(Ctx) ->
    case erlang:element(2, Ctx) of
        [A, B | Rest] ->
            Result = case A =:= B of
                true ->
                    <<1:8>>;

                false ->
                    <<>>
            end,
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [Result | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1333).
-spec execute_verify(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_verify(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Top | Rest] ->
            case is_truthy(Top) of
                true ->
                    {ok,
                        begin
                            _record = Ctx,
                            {script_context,
                                Rest,
                                erlang:element(3, _record),
                                erlang:element(4, _record),
                                erlang:element(5, _record),
                                erlang:element(6, _record),
                                erlang:element(7, _record),
                                erlang:element(8, _record),
                                erlang:element(9, _record)}
                        end};

                false ->
                    {error, script_verify_failed}
            end
    end.

-file("src/oni_consensus.gleam", 1326).
-spec execute_equalverify(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_equalverify(Ctx) ->
    case execute_equal(Ctx) of
        {error, E} ->
            {error, E};

        {ok, New_ctx} ->
            execute_verify(New_ctx)
    end.

-file("src/oni_consensus.gleam", 1553).
-spec execute_ripemd160(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_ripemd160(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Data | Rest] ->
            Hash = oni_bitcoin:ripemd160(Data),
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [Hash | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1563).
-spec execute_sha256(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_sha256(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Data | Rest] ->
            Hash = oni_bitcoin:sha256(Data),
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [Hash | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1573).
-spec execute_hash160(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_hash160(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Data | Rest] ->
            Hash = oni_bitcoin:hash160(Data),
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [Hash | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1583).
-spec execute_hash256(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_hash256(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Data | Rest] ->
            Hash = oni_bitcoin:sha256d(Data),
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [Hash | Rest],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1616).
-spec encode_int_bytes(integer(), bitstring()) -> bitstring().
encode_int_bytes(N, Acc) ->
    case N of
        0 ->
            Acc;

        _ ->
            Byte = N rem 256,
            encode_int_bytes(N div 256, gleam@bit_array:append(Acc, <<Byte:8>>))
    end.

-file("src/oni_consensus.gleam", 1626).
-spec add_sign_bit(bitstring(), boolean()) -> bitstring().
add_sign_bit(Bytes, Negative) ->
    Size = erlang:byte_size(Bytes),
    case Size of
        0 ->
            <<>>;

        _ ->
            case gleam_stdlib:bit_array_slice(Bytes, Size - 1, 1) of
                {ok, <<Last:8>>} ->
                    case Last >= 16#80 of
                        true ->
                            Sign_byte = case Negative of
                                true ->
                                    <<16#80:8>>;

                                false ->
                                    <<16#00:8>>
                            end,
                            gleam@bit_array:append(Bytes, Sign_byte);

                        false ->
                            case Negative of
                                true ->
                                    New_last = Last + 16#80,
                                    case gleam_stdlib:bit_array_slice(
                                        Bytes,
                                        0,
                                        Size - 1
                                    ) of
                                        {ok, Prefix} ->
                                            gleam@bit_array:append(
                                                Prefix,
                                                <<New_last:8>>
                                            );

                                        {error, _} ->
                                            Bytes
                                    end;

                                false ->
                                    Bytes
                            end
                    end;

                _ ->
                    Bytes
            end
    end.

-file("src/oni_consensus.gleam", 1598).
?DOC(" Encode an integer as a script number\n").
-spec encode_script_num(integer()) -> bitstring().
encode_script_num(N) ->
    case N of
        0 ->
            <<>>;

        _ ->
            Abs_n = case N < 0 of
                true ->
                    0 - N;

                false ->
                    N
            end,
            Bytes = encode_int_bytes(Abs_n, <<>>),
            Bytes_with_sign = case N < 0 of
                true ->
                    add_sign_bit(Bytes, true);

                false ->
                    add_sign_bit(Bytes, false)
            end,
            Bytes_with_sign
    end.

-file("src/oni_consensus.gleam", 1247).
-spec execute_size(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_size(Ctx) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [Top | _] ->
            Size = erlang:byte_size(Top),
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [encode_script_num(Size) | erlang:element(2, Ctx)],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end}
    end.

-file("src/oni_consensus.gleam", 1257).
-spec execute_depth(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_depth(Ctx) ->
    Depth = gleam@list:length(erlang:element(2, Ctx)),
    {ok,
        begin
            _record = Ctx,
            {script_context,
                [encode_script_num(Depth) | erlang:element(2, Ctx)],
                erlang:element(3, _record),
                erlang:element(4, _record),
                erlang:element(5, _record),
                erlang:element(6, _record),
                erlang:element(7, _record),
                erlang:element(8, _record),
                erlang:element(9, _record)}
        end}.

-file("src/oni_consensus.gleam", 1704).
-spec pow256(integer()) -> integer().
pow256(N) ->
    case N of
        0 ->
            1;

        _ ->
            256 * pow256(N - 1)
    end.

-file("src/oni_consensus.gleam", 1685).
-spec decode_unsigned(bitstring(), integer(), integer(), boolean()) -> integer().
decode_unsigned(Bytes, Index, Acc, Negative) ->
    Size = erlang:byte_size(Bytes),
    case Index >= Size of
        true ->
            Acc;

        false ->
            case gleam_stdlib:bit_array_slice(Bytes, Index, 1) of
                {ok, <<Byte:8>>} ->
                    Value = case (Index =:= (Size - 1)) andalso Negative of
                        true ->
                            Byte - 16#80;

                        false ->
                            Byte
                    end,
                    decode_unsigned(
                        Bytes,
                        Index + 1,
                        Acc + (Value * pow256(Index)),
                        Negative
                    );

                _ ->
                    Acc
            end
    end.

-file("src/oni_consensus.gleam", 1664).
?DOC(" Decode a script number from bytes\n").
-spec decode_script_num(bitstring()) -> {ok, integer()} | {error, nil}.
decode_script_num(Bytes) ->
    case erlang:byte_size(Bytes) of
        0 ->
            {ok, 0};

        Size when Size > 4 ->
            {error, nil};

        Size@1 ->
            case gleam_stdlib:bit_array_slice(Bytes, Size@1 - 1, 1) of
                {ok, <<Last:8>>} ->
                    Negative = Last >= 16#80,
                    Unsigned = decode_unsigned(Bytes, 0, 0, Negative),
                    case Negative of
                        true ->
                            {ok, 0 - Unsigned};

                        false ->
                            {ok, Unsigned}
                    end;

                _ ->
                    {error, nil}
            end
    end.

-file("src/oni_consensus.gleam", 1493).
-spec execute_within(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_within(Ctx) ->
    case erlang:element(2, Ctx) of
        [Max_bytes, Min_bytes, X_bytes | Rest] ->
            case {decode_script_num(X_bytes),
                decode_script_num(Min_bytes),
                decode_script_num(Max_bytes)} of
                {{ok, X}, {ok, Min}, {ok, Max}} ->
                    Result = case (X >= Min) andalso (X < Max) of
                        true ->
                            1;

                        false ->
                            0
                    end,
                    {ok,
                        begin
                            _record = Ctx,
                            {script_context,
                                [encode_script_num(Result) | Rest],
                                erlang:element(3, _record),
                                erlang:element(4, _record),
                                erlang:element(5, _record),
                                erlang:element(6, _record),
                                erlang:element(7, _record),
                                erlang:element(8, _record),
                                erlang:element(9, _record)}
                        end};

                {_, _, _} ->
                    {error, script_invalid}
            end;

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1512).
?DOC(" Helper for unary numeric operations\n").
-spec unary_num_op(script_context(), fun((integer()) -> integer())) -> {ok,
        script_context()} |
    {error, consensus_error()}.
unary_num_op(Ctx, Op) ->
    case erlang:element(2, Ctx) of
        [] ->
            {error, script_stack_underflow};

        [A_bytes | Rest] ->
            case decode_script_num(A_bytes) of
                {error, _} ->
                    {error, script_invalid};

                {ok, A} ->
                    Result = Op(A),
                    {ok,
                        begin
                            _record = Ctx,
                            {script_context,
                                [encode_script_num(Result) | Rest],
                                erlang:element(3, _record),
                                erlang:element(4, _record),
                                erlang:element(5, _record),
                                erlang:element(6, _record),
                                erlang:element(7, _record),
                                erlang:element(8, _record),
                                erlang:element(9, _record)}
                        end}
            end
    end.

-file("src/oni_consensus.gleam", 1357).
-spec execute_1add(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_1add(Ctx) ->
    unary_num_op(Ctx, fun(A) -> A + 1 end).

-file("src/oni_consensus.gleam", 1361).
-spec execute_1sub(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_1sub(Ctx) ->
    unary_num_op(Ctx, fun(A) -> A - 1 end).

-file("src/oni_consensus.gleam", 1365).
-spec execute_negate(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_negate(Ctx) ->
    unary_num_op(Ctx, fun(A) -> 0 - A end).

-file("src/oni_consensus.gleam", 1369).
-spec execute_abs(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_abs(Ctx) ->
    unary_num_op(Ctx, fun(A) -> case A < 0 of
                true ->
                    0 - A;

                false ->
                    A
            end end).

-file("src/oni_consensus.gleam", 1378).
-spec execute_not(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_not(Ctx) ->
    unary_num_op(Ctx, fun(A) -> case A =:= 0 of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1387).
-spec execute_0notequal(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_0notequal(Ctx) ->
    unary_num_op(Ctx, fun(A) -> case A =:= 0 of
                true ->
                    0;

                false ->
                    1
            end end).

-file("src/oni_consensus.gleam", 1531).
?DOC(" Helper for binary numeric operations\n").
-spec binary_num_op(script_context(), fun((integer(), integer()) -> integer())) -> {ok,
        script_context()} |
    {error, consensus_error()}.
binary_num_op(Ctx, Op) ->
    case erlang:element(2, Ctx) of
        [B_bytes, A_bytes | Rest] ->
            case {decode_script_num(A_bytes), decode_script_num(B_bytes)} of
                {{ok, A}, {ok, B}} ->
                    Result = Op(A, B),
                    {ok,
                        begin
                            _record = Ctx,
                            {script_context,
                                [encode_script_num(Result) | Rest],
                                erlang:element(3, _record),
                                erlang:element(4, _record),
                                erlang:element(5, _record),
                                erlang:element(6, _record),
                                erlang:element(7, _record),
                                erlang:element(8, _record),
                                erlang:element(9, _record)}
                        end};

                {_, _} ->
                    {error, script_invalid}
            end;

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1349).
-spec execute_add(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_add(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> A + B end).

-file("src/oni_consensus.gleam", 1353).
-spec execute_sub(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_sub(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> A - B end).

-file("src/oni_consensus.gleam", 1396).
-spec execute_booland(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_booland(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case (A /= 0) andalso (B /= 0) of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1405).
-spec execute_boolor(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_boolor(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case (A /= 0) orelse (B /= 0) of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1414).
-spec execute_numequal(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_numequal(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case A =:= B of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1423).
-spec execute_numequalverify(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_numequalverify(Ctx) ->
    case execute_numequal(Ctx) of
        {error, E} ->
            {error, E};

        {ok, New_ctx} ->
            execute_verify(New_ctx)
    end.

-file("src/oni_consensus.gleam", 1430).
-spec execute_numnotequal(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_numnotequal(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case A /= B of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1439).
-spec execute_lessthan(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_lessthan(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case A < B of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1448).
-spec execute_greaterthan(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_greaterthan(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case A > B of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1457).
-spec execute_lessthanorequal(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_lessthanorequal(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case A =< B of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1466).
-spec execute_greaterthanorequal(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_greaterthanorequal(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case A >= B of
                true ->
                    1;

                false ->
                    0
            end end).

-file("src/oni_consensus.gleam", 1475).
-spec execute_min(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_min(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case A < B of
                true ->
                    A;

                false ->
                    B
            end end).

-file("src/oni_consensus.gleam", 1484).
-spec execute_max(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_max(Ctx) ->
    binary_num_op(Ctx, fun(A, B) -> case A > B of
                true ->
                    A;

                false ->
                    B
            end end).

-file("src/oni_consensus.gleam", 1715).
-spec list_nth(list(AOA), integer()) -> {ok, AOA} | {error, nil}.
list_nth(Lst, N) ->
    case {Lst, N} of
        {[], _} ->
            {error, nil};

        {[Head | _], 0} ->
            {ok, Head};

        {[_ | Tail], _} ->
            list_nth(Tail, N - 1)
    end.

-file("src/oni_consensus.gleam", 1203).
-spec execute_pick(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_pick(Ctx) ->
    case erlang:element(2, Ctx) of
        [N_bytes | Rest] ->
            case decode_script_num(N_bytes) of
                {error, _} ->
                    {error, script_invalid};

                {ok, N} ->
                    case (N < 0) orelse (N >= gleam@list:length(Rest)) of
                        true ->
                            {error, script_stack_underflow};

                        false ->
                            case list_nth(Rest, N) of
                                {error, _} ->
                                    {error, script_stack_underflow};

                                {ok, Item} ->
                                    {ok,
                                        begin
                                            _record = Ctx,
                                            {script_context,
                                                [Item | Rest],
                                                erlang:element(3, _record),
                                                erlang:element(4, _record),
                                                erlang:element(5, _record),
                                                erlang:element(6, _record),
                                                erlang:element(7, _record),
                                                erlang:element(8, _record),
                                                erlang:element(9, _record)}
                                        end}
                            end
                    end
            end;

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1727).
-spec list_remove_nth_loop(list(AOJ), integer(), list(AOJ)) -> {ok,
        {AOJ, list(AOJ)}} |
    {error, nil}.
list_remove_nth_loop(Lst, N, Acc) ->
    case {Lst, N} of
        {[], _} ->
            {error, nil};

        {[Head | Tail], 0} ->
            {ok, {Head, gleam@list:append(gleam@list:reverse(Acc), Tail)}};

        {[Head@1 | Tail@1], _} ->
            list_remove_nth_loop(Tail@1, N - 1, [Head@1 | Acc])
    end.

-file("src/oni_consensus.gleam", 1723).
-spec list_remove_nth(list(AOE), integer()) -> {ok, {AOE, list(AOE)}} |
    {error, nil}.
list_remove_nth(Lst, N) ->
    list_remove_nth_loop(Lst, N, []).

-file("src/oni_consensus.gleam", 1225).
-spec execute_roll(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_roll(Ctx) ->
    case erlang:element(2, Ctx) of
        [N_bytes | Rest] ->
            case decode_script_num(N_bytes) of
                {error, _} ->
                    {error, script_invalid};

                {ok, N} ->
                    case (N < 0) orelse (N >= gleam@list:length(Rest)) of
                        true ->
                            {error, script_stack_underflow};

                        false ->
                            case list_remove_nth(Rest, N) of
                                {error, _} ->
                                    {error, script_stack_underflow};

                                {ok, {Item, Remaining}} ->
                                    {ok,
                                        begin
                                            _record = Ctx,
                                            {script_context,
                                                [Item | Remaining],
                                                erlang:element(3, _record),
                                                erlang:element(4, _record),
                                                erlang:element(5, _record),
                                                erlang:element(6, _record),
                                                erlang:element(7, _record),
                                                erlang:element(8, _record),
                                                erlang:element(9, _record)}
                                        end}
                            end
                    end
            end;

        _ ->
            {error, script_stack_underflow}
    end.

-file("src/oni_consensus.gleam", 1024).
?DOC(" Execute a single opcode implementation\n").
-spec execute_opcode_impl(script_context(), opcode()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_opcode_impl(Ctx, Op) ->
    case Op of
        op_false ->
            {ok,
                begin
                    _record = Ctx,
                    {script_context,
                        [<<>> | erlang:element(2, Ctx)],
                        erlang:element(3, _record),
                        erlang:element(4, _record),
                        erlang:element(5, _record),
                        erlang:element(6, _record),
                        erlang:element(7, _record),
                        erlang:element(8, _record),
                        erlang:element(9, _record)}
                end};

        op_true ->
            {ok,
                begin
                    _record@1 = Ctx,
                    {script_context,
                        [<<1:8>> | erlang:element(2, Ctx)],
                        erlang:element(3, _record@1),
                        erlang:element(4, _record@1),
                        erlang:element(5, _record@1),
                        erlang:element(6, _record@1),
                        erlang:element(7, _record@1),
                        erlang:element(8, _record@1),
                        erlang:element(9, _record@1)}
                end};

        op1_negate ->
            {ok,
                begin
                    _record@2 = Ctx,
                    {script_context,
                        [<<16#81:8>> | erlang:element(2, Ctx)],
                        erlang:element(3, _record@2),
                        erlang:element(4, _record@2),
                        erlang:element(5, _record@2),
                        erlang:element(6, _record@2),
                        erlang:element(7, _record@2),
                        erlang:element(8, _record@2),
                        erlang:element(9, _record@2)}
                end};

        {op_num, N} ->
            {ok,
                begin
                    _record@3 = Ctx,
                    {script_context,
                        [encode_script_num(N) | erlang:element(2, Ctx)],
                        erlang:element(3, _record@3),
                        erlang:element(4, _record@3),
                        erlang:element(5, _record@3),
                        erlang:element(6, _record@3),
                        erlang:element(7, _record@3),
                        erlang:element(8, _record@3),
                        erlang:element(9, _record@3)}
                end};

        op_dup ->
            execute_dup(Ctx);

        op_drop ->
            execute_drop(Ctx);

        op2_dup ->
            execute_2dup(Ctx);

        op2_drop ->
            execute_2drop(Ctx);

        op3_dup ->
            execute_3dup(Ctx);

        op_swap ->
            execute_swap(Ctx);

        op_over ->
            execute_over(Ctx);

        op_rot ->
            execute_rot(Ctx);

        op_nip ->
            execute_nip(Ctx);

        op_tuck ->
            execute_tuck(Ctx);

        op_pick ->
            execute_pick(Ctx);

        op_roll ->
            execute_roll(Ctx);

        op_size ->
            execute_size(Ctx);

        op_depth ->
            execute_depth(Ctx);

        op_if_dup ->
            execute_ifdup(Ctx);

        op_to_alt_stack ->
            execute_toaltstack(Ctx);

        op_from_alt_stack ->
            execute_fromaltstack(Ctx);

        op_equal ->
            execute_equal(Ctx);

        op_equal_verify ->
            execute_equalverify(Ctx);

        op_verify ->
            execute_verify(Ctx);

        op_add ->
            execute_add(Ctx);

        op_sub ->
            execute_sub(Ctx);

        op1_add ->
            execute_1add(Ctx);

        op1_sub ->
            execute_1sub(Ctx);

        op_negate ->
            execute_negate(Ctx);

        op_abs ->
            execute_abs(Ctx);

        op_not ->
            execute_not(Ctx);

        op0_not_equal ->
            execute_0notequal(Ctx);

        op_bool_and ->
            execute_booland(Ctx);

        op_bool_or ->
            execute_boolor(Ctx);

        op_num_equal ->
            execute_numequal(Ctx);

        op_num_equal_verify ->
            execute_numequalverify(Ctx);

        op_num_not_equal ->
            execute_numnotequal(Ctx);

        op_less_than ->
            execute_lessthan(Ctx);

        op_greater_than ->
            execute_greaterthan(Ctx);

        op_less_than_or_equal ->
            execute_lessthanorequal(Ctx);

        op_greater_than_or_equal ->
            execute_greaterthanorequal(Ctx);

        op_min ->
            execute_min(Ctx);

        op_max ->
            execute_max(Ctx);

        op_within ->
            execute_within(Ctx);

        op_ripe_md160 ->
            execute_ripemd160(Ctx);

        op_sha256 ->
            execute_sha256(Ctx);

        op_hash160 ->
            execute_hash160(Ctx);

        op_hash256 ->
            execute_hash256(Ctx);

        op_nop ->
            {ok, Ctx};

        op_nop1 ->
            {ok, Ctx};

        op_nop4 ->
            {ok, Ctx};

        op_nop5 ->
            {ok, Ctx};

        op_nop6 ->
            {ok, Ctx};

        op_nop7 ->
            {ok, Ctx};

        op_nop8 ->
            {ok, Ctx};

        op_nop9 ->
            {ok, Ctx};

        op_nop10 ->
            {ok, Ctx};

        op_return ->
            {error, script_invalid};

        op_reserved ->
            {error, script_bad_opcode};

        op_reserved1 ->
            {error, script_bad_opcode};

        op_reserved2 ->
            {error, script_bad_opcode};

        op_ver ->
            {error, script_bad_opcode};

        op_ver_if ->
            {error, script_bad_opcode};

        op_ver_not_if ->
            {error, script_bad_opcode};

        op_invalid_opcode ->
            {error, script_bad_opcode};

        op_check_sig ->
            {ok, Ctx};

        op_check_sig_verify ->
            {ok, Ctx};

        op_check_multi_sig ->
            {ok, Ctx};

        op_check_multi_sig_verify ->
            {ok, Ctx};

        op_check_sig_add ->
            {ok, Ctx};

        op_check_lock_time_verify ->
            {ok, Ctx};

        op_check_sequence_verify ->
            {ok, Ctx};

        op_code_separator ->
            {ok,
                begin
                    _record@4 = Ctx,
                    {script_context,
                        erlang:element(2, _record@4),
                        erlang:element(3, _record@4),
                        erlang:element(4, _record@4),
                        erlang:element(5, _record@4),
                        erlang:element(6, _record@4),
                        erlang:element(6, Ctx),
                        erlang:element(8, _record@4),
                        erlang:element(9, _record@4)}
                end};

        {op_success, _} ->
            {ok, Ctx};

        op2_over ->
            execute_2over(Ctx);

        op2_rot ->
            execute_2rot(Ctx);

        op2_swap ->
            execute_2swap(Ctx);

        op_if ->
            {ok, Ctx};

        op_not_if ->
            {ok, Ctx};

        op_else ->
            {ok, Ctx};

        op_end_if ->
            {ok, Ctx};

        {op_push_bytes, _} ->
            {ok, Ctx};

        op_push_data1 ->
            {ok, Ctx};

        op_push_data2 ->
            {ok, Ctx};

        op_push_data4 ->
            {ok, Ctx};

        _ ->
            {error, script_disabled_opcode}
    end.

-file("src/oni_consensus.gleam", 933).
?DOC(" Execute a single opcode\n").
-spec execute_opcode(script_context(), opcode(), boolean()) -> {ok,
        script_context()} |
    {error, consensus_error()}.
execute_opcode(Ctx, Op, Should_execute) ->
    case Op of
        op_if ->
            execute_if(Ctx, Op, Should_execute);

        op_not_if ->
            execute_if(Ctx, Op, Should_execute);

        op_else ->
            execute_else(Ctx);

        op_end_if ->
            execute_endif(Ctx);

        _ ->
            case Should_execute of
                false ->
                    {ok, Ctx};

                true ->
                    execute_opcode_impl(Ctx, Op)
            end
    end.

-file("src/oni_consensus.gleam", 858).
-spec execute_elements(script_context(), list(script_element())) -> {ok,
        script_context()} |
    {error, consensus_error()}.
execute_elements(Ctx, Elements) ->
    case Elements of
        [] ->
            {ok, Ctx};

        [Element | Rest] ->
            Should_execute = is_executing(erlang:element(9, Ctx)),
            case Element of
                {data_element, Data} ->
                    case Should_execute of
                        true ->
                            case erlang:byte_size(Data) > 520 of
                                true ->
                                    {error, script_push_size_exceeded};

                                false ->
                                    New_ctx = begin
                                        _record = Ctx,
                                        {script_context,
                                            [Data | erlang:element(2, Ctx)],
                                            erlang:element(3, _record),
                                            erlang:element(4, _record),
                                            erlang:element(5, _record),
                                            erlang:element(6, _record),
                                            erlang:element(7, _record),
                                            erlang:element(8, _record),
                                            erlang:element(9, _record)}
                                    end,
                                    execute_elements(New_ctx, Rest)
                            end;

                        false ->
                            execute_elements(Ctx, Rest)
                    end;

                {op_element, Op} ->
                    case opcode_is_disabled(Op) andalso Should_execute of
                        true ->
                            {error, script_disabled_opcode};

                        false ->
                            New_op_count = case is_push_op(Op) of
                                true ->
                                    erlang:element(4, Ctx);

                                false ->
                                    erlang:element(4, Ctx) + 1
                            end,
                            case New_op_count > 201 of
                                true ->
                                    {error, script_op_count_exceeded};

                                false ->
                                    Ctx2 = begin
                                        _record@1 = Ctx,
                                        {script_context,
                                            erlang:element(2, _record@1),
                                            erlang:element(3, _record@1),
                                            New_op_count,
                                            erlang:element(5, _record@1),
                                            erlang:element(6, _record@1),
                                            erlang:element(7, _record@1),
                                            erlang:element(8, _record@1),
                                            erlang:element(9, _record@1)}
                                    end,
                                    case execute_opcode(
                                        Ctx2,
                                        Op,
                                        Should_execute
                                    ) of
                                        {error, E} ->
                                            {error, E};

                                        {ok, Ctx3} ->
                                            Stack_size = gleam@list:length(
                                                erlang:element(2, Ctx3)
                                            )
                                            + gleam@list:length(
                                                erlang:element(3, Ctx3)
                                            ),
                                            case Stack_size > 1000 of
                                                true ->
                                                    {error,
                                                        script_stack_overflow};

                                                false ->
                                                    execute_elements(Ctx3, Rest)
                                            end
                                    end
                            end
                    end
            end
    end.

-file("src/oni_consensus.gleam", 850).
?DOC(" Execute a script in the given context\n").
-spec execute_script(script_context()) -> {ok, script_context()} |
    {error, consensus_error()}.
execute_script(Ctx) ->
    case parse_script(erlang:element(5, Ctx)) of
        {error, E} ->
            {error, E};

        {ok, Elements} ->
            execute_elements(Ctx, Elements)
    end.

-file("src/oni_consensus.gleam", 709).
?DOC(" Verify a script execution succeeds\n").
-spec verify_script(
    oni_bitcoin:script(),
    oni_bitcoin:script(),
    list(bitstring()),
    script_flags()
) -> {ok, nil} | {error, consensus_error()}.
verify_script(Script_sig, Script_pubkey, _, Flags) ->
    Ctx = script_context_new(oni_bitcoin:script_to_bytes(Script_sig), Flags),
    case execute_script(Ctx) of
        {error, E} ->
            {error, E};

        {ok, Ctx_after_sig} ->
            Pubkey_ctx = begin
                _record = Ctx_after_sig,
                {script_context,
                    erlang:element(2, _record),
                    erlang:element(3, _record),
                    0,
                    oni_bitcoin:script_to_bytes(Script_pubkey),
                    0,
                    0,
                    erlang:element(8, _record),
                    erlang:element(9, _record)}
            end,
            case execute_script(Pubkey_ctx) of
                {error, E@1} ->
                    {error, E@1};

                {ok, Final_ctx} ->
                    case erlang:element(2, Final_ctx) of
                        [] ->
                            {error, script_verify_failed};

                        [Top | _] ->
                            case is_truthy(Top) of
                                true ->
                                    {ok, nil};

                                false ->
                                    {error, script_verify_failed}
                            end
                    end
            end
    end.

-file("src/oni_consensus.gleam", 513).
?DOC(" Calculate block weight\n").
-spec calculate_block_weight(oni_bitcoin:block()) -> integer().
calculate_block_weight(Block) ->
    (gleam@list:length(erlang:element(3, Block)) * 250) * 4.

-file("src/oni_consensus.gleam", 521).
?DOC(" Validate block weight\n").
-spec validate_block_weight(oni_bitcoin:block()) -> {ok, nil} |
    {error, consensus_error()}.
validate_block_weight(Block) ->
    Weight = calculate_block_weight(Block),
    case Weight =< 4000000 of
        true ->
            {ok, nil};

        false ->
            {error, block_weight_exceeded}
    end.
