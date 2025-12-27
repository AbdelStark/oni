%%% oni_block_validator - Parallel block validation pipeline
%%%
%%% Responsibilities:
%%% - Validate block headers (PoW, timestamps, difficulty)
%%% - Validate block structure (merkle root, size, weight)
%%% - Parallel transaction validation with script verification
%%% - UTXO updates and signature verification
%%% - Witness commitment validation for SegWit blocks

-module(oni_block_validator).

-export([
    validate_block/2,
    validate_header/2,
    validate_transactions/3,
    verify_merkle_root/1,
    verify_witness_commitment/1,
    compute_block_reward/1
]).

%% Validation flags
-record(validation_ctx, {
    height :: non_neg_integer(),
    prev_block_time :: non_neg_integer(),
    median_time_past :: non_neg_integer(),
    target :: binary(),
    utxo_view :: term(),
    flags :: map()
}).

%% Block validation result
-record(validation_result, {
    valid :: boolean(),
    error :: atom() | undefined,
    details :: term()
}).

%% Constants
-define(MAX_BLOCK_WEIGHT, 4000000).
-define(MAX_BLOCK_SIGOPS, 80000).
-define(WITNESS_SCALE_FACTOR, 4).
-define(COINBASE_MATURITY, 100).

%% ============================================================================
%% Public API
%% ============================================================================

%% Validate a complete block (header + transactions)
-spec validate_block(map(), #validation_ctx{}) ->
    {ok, #validation_result{}} | {error, atom()}.
validate_block(Block, Ctx) ->
    %% Stage 1: Header validation
    case validate_header(Block, Ctx) of
        {error, _} = Err ->
            Err;
        ok ->
            %% Stage 2: Structure validation
            case validate_block_structure(Block, Ctx) of
                {error, _} = Err ->
                    Err;
                ok ->
                    %% Stage 3: Transaction validation (parallel)
                    case validate_transactions(Block, Ctx, parallel) of
                        {error, _} = Err ->
                            Err;
                        {ok, _} ->
                            {ok, #validation_result{valid = true}}
                    end
            end
    end.

%% Validate block header only
-spec validate_header(map(), #validation_ctx{}) -> ok | {error, atom()}.
validate_header(Block, Ctx) ->
    Header = maps:get(header, Block, #{}),

    Checks = [
        {check_version, fun() -> check_version(Header, Ctx) end},
        {check_timestamp, fun() -> check_timestamp(Header, Ctx) end},
        {check_difficulty, fun() -> check_difficulty(Header, Ctx) end},
        {check_proof_of_work, fun() -> check_proof_of_work(Header, Ctx) end},
        {check_prev_block, fun() -> check_prev_block(Header, Ctx) end}
    ],

    run_checks(Checks).

%% Validate all transactions in a block
-spec validate_transactions(map(), #validation_ctx{}, parallel | sequential) ->
    {ok, map()} | {error, atom()}.
validate_transactions(Block, Ctx, Mode) ->
    Transactions = maps:get(transactions, Block, []),

    case Transactions of
        [] ->
            {error, no_transactions};
        [Coinbase | Rest] ->
            %% Validate coinbase separately
            case validate_coinbase(Coinbase, Block, Ctx) of
                {error, _} = Err ->
                    Err;
                ok ->
                    %% Validate other transactions
                    case Mode of
                        parallel ->
                            validate_transactions_parallel(Rest, Ctx);
                        sequential ->
                            validate_transactions_sequential(Rest, Ctx)
                    end
            end
    end.

%% Verify merkle root matches transactions
-spec verify_merkle_root(map()) -> ok | {error, atom()}.
verify_merkle_root(Block) ->
    Header = maps:get(header, Block, #{}),
    Transactions = maps:get(transactions, Block, []),

    ClaimedRoot = maps:get(merkle_root, Header),
    ComputedRoot = compute_merkle_root(Transactions),

    case ClaimedRoot =:= ComputedRoot of
        true -> ok;
        false -> {error, merkle_root_mismatch}
    end.

%% Verify witness commitment (BIP141)
-spec verify_witness_commitment(map()) -> ok | {error, atom()} | not_required.
verify_witness_commitment(Block) ->
    Transactions = maps:get(transactions, Block, []),

    %% Check if any transaction has witness data
    HasWitness = lists:any(fun has_witness/1, Transactions),

    case HasWitness of
        false ->
            not_required;
        true ->
            verify_witness_commitment_impl(Block)
    end.

%% Compute block reward for a given height
-spec compute_block_reward(non_neg_integer()) -> non_neg_integer().
compute_block_reward(Height) ->
    %% Initial reward is 50 BTC = 5,000,000,000 satoshis
    %% Halves every 210,000 blocks
    Halvings = Height div 210000,
    case Halvings >= 64 of
        true -> 0;  % No more reward after 64 halvings
        false -> 5000000000 bsr Halvings
    end.

%% ============================================================================
%% Header Validation
%% ============================================================================

check_version(Header, _Ctx) ->
    Version = maps:get(version, Header, 0),
    %% Version must be positive
    case Version > 0 of
        true -> ok;
        false -> {error, invalid_version}
    end.

check_timestamp(Header, Ctx) ->
    Timestamp = maps:get(timestamp, Header, 0),
    MedianTime = Ctx#validation_ctx.median_time_past,
    CurrentTime = erlang:system_time(second),

    %% Timestamp must be > median time of last 11 blocks
    case Timestamp > MedianTime of
        false ->
            {error, timestamp_too_old};
        true ->
            %% Timestamp must not be more than 2 hours in future
            MaxTime = CurrentTime + 2 * 60 * 60,
            case Timestamp =< MaxTime of
                true -> ok;
                false -> {error, timestamp_too_far_ahead}
            end
    end.

check_difficulty(Header, Ctx) ->
    Bits = maps:get(bits, Header, 0),
    ExpectedTarget = Ctx#validation_ctx.target,

    %% Convert bits to target
    ActualTarget = bits_to_target(Bits),

    %% Target must not exceed expected
    case target_le(ActualTarget, ExpectedTarget) of
        true -> ok;
        false -> {error, difficulty_too_low}
    end.

check_proof_of_work(Header, _Ctx) ->
    %% Compute block hash
    HeaderBytes = encode_header(Header),
    Hash = crypto:hash(sha256, crypto:hash(sha256, HeaderBytes)),

    %% Get target from bits
    Bits = maps:get(bits, Header, 0),
    Target = bits_to_target(Bits),

    %% Hash must be <= target
    case hash_le_target(Hash, Target) of
        true -> ok;
        false -> {error, proof_of_work_failed}
    end.

check_prev_block(Header, Ctx) ->
    PrevHash = maps:get(prev_block, Header, <<0:256>>),

    %% For genesis block, prev hash is all zeros
    case Ctx#validation_ctx.height of
        0 ->
            case PrevHash =:= <<0:256>> of
                true -> ok;
                false -> {error, invalid_genesis_prev}
            end;
        _ ->
            %% Verify prev block exists and matches
            case oni_chainstate:has_block(PrevHash) of
                true -> ok;
                false -> {error, prev_block_not_found}
            end
    end.

%% ============================================================================
%% Block Structure Validation
%% ============================================================================

validate_block_structure(Block, Ctx) ->
    Checks = [
        {check_merkle_root, fun() -> verify_merkle_root(Block) end},
        {check_block_weight, fun() -> check_block_weight(Block, Ctx) end},
        {check_witness_commitment, fun() -> verify_witness_commitment(Block) end},
        {check_sigops, fun() -> check_block_sigops(Block, Ctx) end}
    ],

    run_checks(Checks).

check_block_weight(Block, _Ctx) ->
    Weight = compute_block_weight(Block),
    case Weight =< ?MAX_BLOCK_WEIGHT of
        true -> ok;
        false -> {error, block_weight_exceeded}
    end.

check_block_sigops(Block, _Ctx) ->
    SigOps = count_block_sigops(Block),
    case SigOps =< ?MAX_BLOCK_SIGOPS of
        true -> ok;
        false -> {error, sigops_exceeded}
    end.

compute_block_weight(Block) ->
    Transactions = maps:get(transactions, Block, []),

    %% Base size (non-witness data) * 3 + total size
    lists:foldl(fun(Tx, Acc) ->
        BaseSize = compute_tx_base_size(Tx),
        WitnessSize = compute_tx_witness_size(Tx),
        TxWeight = BaseSize * (?WITNESS_SCALE_FACTOR - 1) + BaseSize + WitnessSize,
        Acc + TxWeight
    end, 0, Transactions).

count_block_sigops(Block) ->
    Transactions = maps:get(transactions, Block, []),
    lists:foldl(fun(Tx, Acc) ->
        Acc + count_tx_sigops(Tx)
    end, 0, Transactions).

%% ============================================================================
%% Transaction Validation
%% ============================================================================

validate_coinbase(Coinbase, Block, Ctx) ->
    Checks = [
        {check_coinbase_structure, fun() -> check_coinbase_structure(Coinbase) end},
        {check_coinbase_height, fun() -> check_coinbase_height(Coinbase, Ctx) end},
        {check_coinbase_value, fun() -> check_coinbase_value(Coinbase, Block, Ctx) end}
    ],

    run_checks(Checks).

check_coinbase_structure(Coinbase) ->
    Inputs = maps:get(inputs, Coinbase, []),

    case Inputs of
        [Input] ->
            %% Must have null prevout
            Prevout = maps:get(prevout, Input, #{}),
            TxId = maps:get(txid, Prevout, <<>>),
            Vout = maps:get(vout, Prevout, 0),

            case {TxId, Vout} of
                {<<0:256>>, 16#FFFFFFFF} -> ok;
                _ -> {error, invalid_coinbase_prevout}
            end;
        _ ->
            {error, coinbase_must_have_one_input}
    end.

check_coinbase_height(Coinbase, Ctx) ->
    %% BIP34: Height must be in coinbase script
    Height = Ctx#validation_ctx.height,

    case Height < 227931 of
        true ->
            ok;  % BIP34 not yet active
        false ->
            Inputs = maps:get(inputs, Coinbase, []),
            case Inputs of
                [Input] ->
                    Script = maps:get(script_sig, Input, <<>>),
                    verify_bip34_height(Script, Height);
                _ ->
                    {error, invalid_coinbase}
            end
    end.

verify_bip34_height(<<Len:8, HeightBytes:Len/binary, _/binary>>, ExpectedHeight) ->
    %% Decode script number
    EncodedHeight = decode_script_num(HeightBytes),
    case EncodedHeight =:= ExpectedHeight of
        true -> ok;
        false -> {error, bip34_height_mismatch}
    end;
verify_bip34_height(_, _) ->
    {error, invalid_bip34_encoding}.

check_coinbase_value(Coinbase, Block, Ctx) ->
    %% Coinbase output value must not exceed reward + fees
    CoinbaseValue = sum_output_values(Coinbase),
    BlockReward = compute_block_reward(Ctx#validation_ctx.height),
    TotalFees = compute_block_fees(Block, Ctx),

    MaxValue = BlockReward + TotalFees,
    case CoinbaseValue =< MaxValue of
        true -> ok;
        false -> {error, coinbase_value_exceeded}
    end.

%% Parallel transaction validation
validate_transactions_parallel(Transactions, Ctx) ->
    %% Create worker pool
    NumWorkers = erlang:system_info(schedulers),
    Parent = self(),

    %% Split transactions into batches
    Batches = split_into_batches(Transactions, NumWorkers),

    %% Spawn workers
    Workers = lists:map(fun(Batch) ->
        spawn_link(fun() ->
            Result = validate_tx_batch(Batch, Ctx),
            Parent ! {self(), Result}
        end)
    end, Batches),

    %% Collect results
    collect_results(Workers, [], Ctx).

split_into_batches(List, N) ->
    BatchSize = max(1, (length(List) + N - 1) div N),
    split_into_batches_acc(List, BatchSize, []).

split_into_batches_acc([], _, Acc) ->
    lists:reverse(Acc);
split_into_batches_acc(List, Size, Acc) ->
    {Batch, Rest} = lists:split(min(Size, length(List)), List),
    split_into_batches_acc(Rest, Size, [Batch | Acc]).

validate_tx_batch(Transactions, Ctx) ->
    lists:foldl(fun(Tx, Acc) ->
        case Acc of
            {error, _} -> Acc;
            ok -> validate_single_tx(Tx, Ctx)
        end
    end, ok, Transactions).

collect_results([], Errors, _Ctx) ->
    case Errors of
        [] -> {ok, #{}};
        [Err | _] -> Err
    end;
collect_results([Worker | Rest], Errors, Ctx) ->
    receive
        {Worker, ok} ->
            collect_results(Rest, Errors, Ctx);
        {Worker, {error, _} = Err} ->
            collect_results(Rest, [Err | Errors], Ctx)
    after 60000 ->
        {error, validation_timeout}
    end.

%% Sequential transaction validation
validate_transactions_sequential(Transactions, Ctx) ->
    lists:foldl(fun(Tx, Acc) ->
        case Acc of
            {error, _} -> Acc;
            {ok, _} -> validate_single_tx(Tx, Ctx)
        end
    end, {ok, #{}}, Transactions).

%% Validate a single transaction
validate_single_tx(Tx, Ctx) ->
    Checks = [
        {check_tx_structure, fun() -> check_tx_structure(Tx) end},
        {check_tx_inputs, fun() -> check_tx_inputs(Tx, Ctx) end},
        {check_tx_outputs, fun() -> check_tx_outputs(Tx) end},
        {verify_signatures, fun() -> verify_tx_signatures(Tx, Ctx) end}
    ],

    run_checks(Checks).

check_tx_structure(Tx) ->
    Inputs = maps:get(inputs, Tx, []),
    Outputs = maps:get(outputs, Tx, []),

    case {Inputs, Outputs} of
        {[], _} -> {error, no_inputs};
        {_, []} -> {error, no_outputs};
        _ -> ok
    end.

check_tx_inputs(Tx, Ctx) ->
    Inputs = maps:get(inputs, Tx, []),
    UtxoView = Ctx#validation_ctx.utxo_view,

    lists:foldl(fun(Input, Acc) ->
        case Acc of
            {error, _} -> Acc;
            ok ->
                Prevout = maps:get(prevout, Input, #{}),
                case lookup_utxo(Prevout, UtxoView) of
                    {ok, _Coin} -> ok;
                    {error, _} -> {error, missing_input}
                end
        end
    end, ok, Inputs).

check_tx_outputs(Tx) ->
    Outputs = maps:get(outputs, Tx, []),

    lists:foldl(fun(Output, Acc) ->
        case Acc of
            {error, _} -> Acc;
            ok ->
                Value = maps:get(value, Output, 0),
                case Value >= 0 andalso Value =< 21000000 * 100000000 of
                    true -> ok;
                    false -> {error, invalid_output_value}
                end
        end
    end, ok, Outputs).

verify_tx_signatures(Tx, Ctx) ->
    Inputs = maps:get(inputs, Tx, []),
    UtxoView = Ctx#validation_ctx.utxo_view,
    Flags = Ctx#validation_ctx.flags,

    verify_inputs_loop(Inputs, Tx, UtxoView, Flags, 0).

verify_inputs_loop([], _Tx, _UtxoView, _Flags, _Index) ->
    ok;
verify_inputs_loop([Input | Rest], Tx, UtxoView, Flags, Index) ->
    Prevout = maps:get(prevout, Input, #{}),

    case lookup_utxo(Prevout, UtxoView) of
        {ok, Coin} ->
            case verify_input_script(Tx, Index, Input, Coin, Flags) of
                ok ->
                    verify_inputs_loop(Rest, Tx, UtxoView, Flags, Index + 1);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

verify_input_script(Tx, InputIndex, Input, Coin, Flags) ->
    ScriptSig = maps:get(script_sig, Input, <<>>),
    Witness = maps:get(witness, Input, []),
    ScriptPubKey = maps:get(script_pubkey, Coin, <<>>),
    Amount = maps:get(value, Coin, 0),

    %% Call into consensus script engine
    case catch oni_consensus_ffi:verify_script(
        ScriptSig, ScriptPubKey, Witness, Tx, InputIndex, Amount, Flags
    ) of
        {ok, true} -> ok;
        {ok, false} -> {error, script_verification_failed};
        {error, Reason} -> {error, Reason};
        {'EXIT', _} -> {error, script_engine_error}
    end.

%% ============================================================================
%% Witness Commitment
%% ============================================================================

verify_witness_commitment_impl(Block) ->
    [Coinbase | Transactions] = maps:get(transactions, Block, []),

    %% Find witness commitment in coinbase outputs
    case find_witness_commitment(Coinbase) of
        {ok, ClaimedCommitment} ->
            %% Compute expected commitment
            WtxidRoot = compute_wtxid_merkle_root(Transactions),
            WitnessNonce = get_witness_nonce(Coinbase),
            ExpectedCommitment = compute_witness_commitment(WtxidRoot, WitnessNonce),

            case ClaimedCommitment =:= ExpectedCommitment of
                true -> ok;
                false -> {error, witness_commitment_mismatch}
            end;
        {error, not_found} ->
            {error, missing_witness_commitment}
    end.

find_witness_commitment(Coinbase) ->
    Outputs = maps:get(outputs, Coinbase, []),
    find_witness_commitment_in_outputs(lists:reverse(Outputs)).

find_witness_commitment_in_outputs([]) ->
    {error, not_found};
find_witness_commitment_in_outputs([Output | Rest]) ->
    Script = maps:get(script_pubkey, Output, <<>>),
    case Script of
        <<16#6a, 16#24, 16#aa, 16#21, 16#a9, 16#ed, Commitment:32/binary, _/binary>> ->
            {ok, Commitment};
        _ ->
            find_witness_commitment_in_outputs(Rest)
    end.

get_witness_nonce(Coinbase) ->
    Inputs = maps:get(inputs, Coinbase, []),
    case Inputs of
        [Input] ->
            Witness = maps:get(witness, Input, []),
            case Witness of
                [Nonce] when byte_size(Nonce) =:= 32 -> Nonce;
                _ -> <<0:256>>
            end;
        _ ->
            <<0:256>>
    end.

compute_witness_commitment(WtxidRoot, Nonce) ->
    Data = <<WtxidRoot/binary, Nonce/binary>>,
    crypto:hash(sha256, crypto:hash(sha256, Data)).

compute_wtxid_merkle_root(Transactions) ->
    %% Coinbase wtxid is 0x00...00
    Wtxids = [<<0:256>> | lists:map(fun compute_wtxid/1, Transactions)],
    compute_merkle_root_from_hashes(Wtxids).

compute_wtxid(Tx) ->
    %% wtxid = hash of tx with witness
    TxBytes = encode_tx_with_witness(Tx),
    crypto:hash(sha256, crypto:hash(sha256, TxBytes)).

%% ============================================================================
%% Utility Functions
%% ============================================================================

run_checks([]) ->
    ok;
run_checks([{_Name, CheckFun} | Rest]) ->
    case CheckFun() of
        ok -> run_checks(Rest);
        not_required -> run_checks(Rest);
        {error, _} = Err -> Err
    end.

encode_header(#{version := Version, prev_block := PrevBlock,
                merkle_root := MerkleRoot, timestamp := Timestamp,
                bits := Bits, nonce := Nonce}) ->
    <<Version:32/little, PrevBlock/binary, MerkleRoot/binary,
      Timestamp:32/little, Bits:32/little, Nonce:32/little>>;
encode_header(_) ->
    <<0:640>>.

bits_to_target(Bits) ->
    Exponent = (Bits bsr 24) band 16#FF,
    Mantissa = Bits band 16#7FFFFF,
    case Exponent =< 3 of
        true ->
            <<(Mantissa bsr (8 * (3 - Exponent))):256>>;
        false ->
            <<(Mantissa bsl (8 * (Exponent - 3))):256>>
    end.

target_le(Target1, Target2) ->
    %% Compare as big integers
    binary_to_integer(Target1) =< binary_to_integer(Target2).

hash_le_target(Hash, Target) ->
    %% Hash bytes are little-endian, reverse for comparison
    ReversedHash = reverse_bytes(Hash),
    binary_to_integer(ReversedHash) =< binary_to_integer(Target).

reverse_bytes(Bin) ->
    list_to_binary(lists:reverse(binary_to_list(Bin))).

binary_to_integer(<<>>) ->
    0;
binary_to_integer(Bin) ->
    binary:decode_unsigned(Bin, big).

compute_merkle_root([]) ->
    <<0:256>>;
compute_merkle_root(Transactions) ->
    Hashes = lists:map(fun compute_txid/1, Transactions),
    compute_merkle_root_from_hashes(Hashes).

compute_merkle_root_from_hashes([Hash]) ->
    Hash;
compute_merkle_root_from_hashes(Hashes) ->
    PaddedHashes = case length(Hashes) rem 2 of
        0 -> Hashes;
        1 -> Hashes ++ [lists:last(Hashes)]
    end,
    NextLevel = pair_hashes(PaddedHashes, []),
    compute_merkle_root_from_hashes(NextLevel).

pair_hashes([], Acc) ->
    lists:reverse(Acc);
pair_hashes([H1, H2 | Rest], Acc) ->
    Combined = crypto:hash(sha256, crypto:hash(sha256, <<H1/binary, H2/binary>>)),
    pair_hashes(Rest, [Combined | Acc]).

compute_txid(Tx) ->
    TxBytes = encode_tx_without_witness(Tx),
    crypto:hash(sha256, crypto:hash(sha256, TxBytes)).

encode_tx_without_witness(_Tx) ->
    %% Would encode transaction without witness data
    <<>>.

encode_tx_with_witness(_Tx) ->
    %% Would encode transaction with witness data
    <<>>.

has_witness(Tx) ->
    Inputs = maps:get(inputs, Tx, []),
    lists:any(fun(Input) ->
        Witness = maps:get(witness, Input, []),
        Witness =/= []
    end, Inputs).

compute_tx_base_size(_Tx) ->
    %% Would compute size without witness
    250.  % Placeholder

compute_tx_witness_size(_Tx) ->
    %% Would compute witness size
    0.  % Placeholder

count_tx_sigops(_Tx) ->
    %% Would count signature operations
    1.  % Placeholder

sum_output_values(Tx) ->
    Outputs = maps:get(outputs, Tx, []),
    lists:foldl(fun(Output, Acc) ->
        Acc + maps:get(value, Output, 0)
    end, 0, Outputs).

compute_block_fees(_Block, _Ctx) ->
    %% Would compute total fees from block transactions
    0.  % Placeholder

lookup_utxo(Prevout, UtxoView) ->
    TxId = maps:get(txid, Prevout, <<0:256>>),
    Vout = maps:get(vout, Prevout, 0),
    oni_storage_ffi:utxo_get(UtxoView, TxId, Vout).

decode_script_num(<<>>) ->
    0;
decode_script_num(Bytes) ->
    %% Little-endian with sign bit
    Size = byte_size(Bytes),
    <<Last:8>> = binary:part(Bytes, Size - 1, 1),

    Negative = (Last band 16#80) =/= 0,
    MaskedLast = Last band 16#7F,

    Value = case Size of
        1 -> MaskedLast;
        _ ->
            RestBytes = binary:part(Bytes, 0, Size - 1),
            binary:decode_unsigned(RestBytes, little) + (MaskedLast bsl ((Size - 1) * 8))
    end,

    case Negative of
        true -> -Value;
        false -> Value
    end.
