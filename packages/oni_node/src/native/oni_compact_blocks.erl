%%% oni_compact_blocks - BIP152 Compact Block Relay
%%%
%%% Implements compact block relay for efficient block propagation:
%%% - sendcmpct message handling
%%% - cmpctblock message encoding/decoding
%%% - Short transaction ID computation
%%% - Block reconstruction from mempool
%%% - getblocktxn / blocktxn for missing transactions

-module(oni_compact_blocks).

-export([
    %% Configuration
    supports_compact_blocks/0,
    preferred_version/0,

    %% Message creation
    create_sendcmpct/2,
    create_cmpctblock/2,
    create_getblocktxn/2,
    create_blocktxn/2,

    %% Message parsing
    parse_sendcmpct/1,
    parse_cmpctblock/1,
    parse_getblocktxn/1,
    parse_blocktxn/1,

    %% Block handling
    reconstruct_block/2,
    compute_short_txids/2,
    compute_short_txid/3
]).

%% Compact block version (1 = original, 2 = with witness)
-define(CMPCTBLOCK_VERSION_1, 1).
-define(CMPCTBLOCK_VERSION_2, 2).

%% Short txid length in bytes
-define(SHORT_TXID_LENGTH, 6).

-record(compact_block, {
    header :: binary(),          % 80-byte block header
    nonce :: binary(),           % 8-byte nonce for short ID computation
    short_txids :: [binary()],   % List of 6-byte short transaction IDs
    prefilled_txns :: [{non_neg_integer(), binary()}]  % {index, tx} pairs
}).

-record(block_txn_request, {
    block_hash :: binary(),      % 32-byte block hash
    indexes :: [non_neg_integer()]  % Requested transaction indexes
}).

-record(block_txn_response, {
    block_hash :: binary(),      % 32-byte block hash
    transactions :: [binary()]   % Requested transactions
}).

%% ============================================================================
%% Configuration
%% ============================================================================

%% Check if compact blocks are supported
supports_compact_blocks() ->
    true.

%% Get preferred compact block version
preferred_version() ->
    ?CMPCTBLOCK_VERSION_2.  % Prefer version with witness data

%% ============================================================================
%% Message Creation
%% ============================================================================

%% Create a sendcmpct message
%% announce_mode: true = high-bandwidth mode (send cmpctblock without asking)
%%               false = low-bandwidth mode (send inv first)
%% version: compact block protocol version
create_sendcmpct(AnnounceMode, Version) ->
    AnnounceByte = case AnnounceMode of
        true -> 1;
        false -> 0
    end,
    <<AnnounceByte:8, Version:64/little>>.

%% Create a cmpctblock message from a full block
create_cmpctblock(Block, Nonce) ->
    Header = maps:get(header, Block),
    HeaderBytes = encode_header(Header),

    Txs = maps:get(transactions, Block, []),

    %% Compute short txids for all transactions except coinbase
    {CoinbaseTx, OtherTxs} = case Txs of
        [Cb | Rest] -> {Cb, Rest};
        _ -> {undefined, []}
    end,

    %% Always prefill coinbase
    PrefilledTxns = case CoinbaseTx of
        undefined -> [];
        _ -> [{0, encode_transaction(CoinbaseTx)}]
    end,

    %% Compute short IDs
    SipKey = compute_siphash_keys(HeaderBytes, Nonce),
    ShortTxids = lists:map(fun(Tx) ->
        TxHash = compute_tx_hash(Tx),
        compute_short_txid(TxHash, SipKey, ?SHORT_TXID_LENGTH)
    end, OtherTxs),

    %% Encode message
    encode_compact_block(#compact_block{
        header = HeaderBytes,
        nonce = Nonce,
        short_txids = ShortTxids,
        prefilled_txns = PrefilledTxns
    }).

%% Create getblocktxn request for missing transactions
create_getblocktxn(BlockHash, MissingIndexes) ->
    encode_getblocktxn(#block_txn_request{
        block_hash = BlockHash,
        indexes = MissingIndexes
    }).

%% Create blocktxn response with requested transactions
create_blocktxn(BlockHash, Transactions) ->
    encode_blocktxn(#block_txn_response{
        block_hash = BlockHash,
        transactions = Transactions
    }).

%% ============================================================================
%% Message Parsing
%% ============================================================================

%% Parse sendcmpct message
parse_sendcmpct(<<AnnounceMode:8, Version:64/little, Rest/binary>>) ->
    {ok, #{
        announce_mode => AnnounceMode =:= 1,
        version => Version
    }, Rest};
parse_sendcmpct(_) ->
    {error, invalid_sendcmpct}.

%% Parse cmpctblock message
parse_cmpctblock(Data) ->
    try
        %% Header (80 bytes)
        <<Header:80/binary, Rest1/binary>> = Data,

        %% Nonce (8 bytes)
        <<Nonce:64/little, Rest2/binary>> = Rest1,

        %% Short txid count (varint)
        {ShortIdCount, Rest3} = parse_varint(Rest2),

        %% Short txids (6 bytes each)
        {ShortTxids, Rest4} = parse_short_txids(Rest3, ShortIdCount, []),

        %% Prefilled txn count (varint)
        {PrefilledCount, Rest5} = parse_varint(Rest4),

        %% Prefilled transactions
        {PrefilledTxns, Rest6} = parse_prefilled_txns(Rest5, PrefilledCount, 0, []),

        {ok, #compact_block{
            header = Header,
            nonce = <<Nonce:64/little>>,
            short_txids = ShortTxids,
            prefilled_txns = PrefilledTxns
        }, Rest6}
    catch
        _:_ -> {error, invalid_cmpctblock}
    end.

%% Parse getblocktxn message
parse_getblocktxn(<<BlockHash:32/binary, Rest/binary>>) ->
    try
        {IndexCount, Rest2} = parse_varint(Rest),
        {Indexes, Rest3} = parse_differential_indexes(Rest2, IndexCount, 0, []),
        {ok, #block_txn_request{
            block_hash = BlockHash,
            indexes = Indexes
        }, Rest3}
    catch
        _:_ -> {error, invalid_getblocktxn}
    end;
parse_getblocktxn(_) ->
    {error, invalid_getblocktxn}.

%% Parse blocktxn message
parse_blocktxn(<<BlockHash:32/binary, Rest/binary>>) ->
    try
        {TxCount, Rest2} = parse_varint(Rest),
        {Transactions, Rest3} = parse_transactions(Rest2, TxCount, []),
        {ok, #block_txn_response{
            block_hash = BlockHash,
            transactions = Transactions
        }, Rest3}
    catch
        _:_ -> {error, invalid_blocktxn}
    end;
parse_blocktxn(_) ->
    {error, invalid_blocktxn}.

%% ============================================================================
%% Block Reconstruction
%% ============================================================================

%% Reconstruct a full block from compact block and mempool
reconstruct_block(CompactBlock, MempoolTxs) ->
    #compact_block{
        header = Header,
        nonce = Nonce,
        short_txids = ShortTxids,
        prefilled_txns = PrefilledTxns
    } = CompactBlock,

    %% Compute SipHash keys
    SipKey = compute_siphash_keys(Header, Nonce),

    %% Build map of short ID -> mempool tx
    ShortIdMap = build_short_id_map(MempoolTxs, SipKey),

    %% Try to match short txids to mempool transactions
    TotalTxCount = length(ShortTxids) + length(PrefilledTxns),
    {ReconstructedTxs, MissingIndexes} = reconstruct_transactions(
        ShortTxids,
        PrefilledTxns,
        ShortIdMap,
        TotalTxCount
    ),

    case MissingIndexes of
        [] ->
            %% Successfully reconstructed
            {ok, #{
                header => parse_header(Header),
                transactions => ReconstructedTxs
            }};
        _ ->
            %% Need to request missing transactions
            {incomplete, MissingIndexes}
    end.

%% Build a map from short txid to transaction
build_short_id_map(MempoolTxs, SipKey) ->
    lists:foldl(fun(Tx, Acc) ->
        TxHash = compute_tx_hash(Tx),
        ShortId = compute_short_txid(TxHash, SipKey, ?SHORT_TXID_LENGTH),
        maps:put(ShortId, Tx, Acc)
    end, #{}, MempoolTxs).

%% Reconstruct transactions from short IDs and prefilled
reconstruct_transactions(ShortTxids, PrefilledTxns, ShortIdMap, TotalCount) ->
    %% Initialize with placeholders
    EmptySlots = lists:duplicate(TotalCount, undefined),

    %% Fill in prefilled transactions
    Slots1 = lists:foldl(fun({Idx, Tx}, Acc) ->
        setelement(Idx + 1, Acc, Tx)
    end, list_to_tuple(EmptySlots), PrefilledTxns),

    %% Find non-prefilled positions
    PrefilledIdxs = [Idx || {Idx, _} <- PrefilledTxns],

    %% Fill from short IDs
    {FinalSlots, MissingIdxs, _} = lists:foldl(fun(ShortId, {Slots, Missing, Pos}) ->
        %% Skip prefilled positions
        ActualPos = find_non_prefilled_pos(Pos, PrefilledIdxs, TotalCount),
        case maps:get(ShortId, ShortIdMap, undefined) of
            undefined ->
                {Slots, [ActualPos | Missing], ActualPos + 1};
            Tx ->
                {setelement(ActualPos + 1, Slots, Tx), Missing, ActualPos + 1}
        end
    end, {Slots1, [], 0}, ShortTxids),

    {tuple_to_list(FinalSlots), lists:reverse(MissingIdxs)}.

find_non_prefilled_pos(Pos, PrefilledIdxs, MaxPos) when Pos >= MaxPos ->
    Pos;
find_non_prefilled_pos(Pos, PrefilledIdxs, MaxPos) ->
    case lists:member(Pos, PrefilledIdxs) of
        true -> find_non_prefilled_pos(Pos + 1, PrefilledIdxs, MaxPos);
        false -> Pos
    end.

%% ============================================================================
%% Short Transaction ID Computation
%% ============================================================================

%% Compute short transaction IDs for a block
compute_short_txids(Block, Nonce) ->
    Header = maps:get(header, Block),
    HeaderBytes = encode_header(Header),
    SipKey = compute_siphash_keys(HeaderBytes, Nonce),

    Txs = maps:get(transactions, Block, []),
    lists:map(fun(Tx) ->
        TxHash = compute_tx_hash(Tx),
        compute_short_txid(TxHash, SipKey, ?SHORT_TXID_LENGTH)
    end, Txs).

%% Compute a single short transaction ID using SipHash-2-4
compute_short_txid(TxHash, SipKey, Length) ->
    %% SipHash-2-4 of the transaction hash
    Hash = siphash(TxHash, SipKey),
    <<ShortId:Length/binary, _/binary>> = Hash,
    ShortId.

%% Compute SipHash keys from header and nonce
compute_siphash_keys(Header, Nonce) when is_binary(Nonce) ->
    %% Key = SHA256(header || nonce)
    KeyData = <<Header/binary, Nonce/binary>>,
    crypto:hash(sha256, KeyData);
compute_siphash_keys(Header, Nonce) when is_integer(Nonce) ->
    compute_siphash_keys(Header, <<Nonce:64/little>>).

%% SipHash-2-4 implementation (simplified)
siphash(Message, Key) ->
    %% Using Erlang's crypto for a similar hash
    %% In production, use actual SipHash-2-4
    crypto:mac(hmac, sha256, Key, Message).

%% ============================================================================
%% Encoding Helpers
%% ============================================================================

encode_compact_block(#compact_block{} = CB) ->
    ShortIdCount = length(CB#compact_block.short_txids),
    PrefilledCount = length(CB#compact_block.prefilled_txns),

    ShortIdBytes = list_to_binary(CB#compact_block.short_txids),

    PrefilledBytes = encode_prefilled_txns(CB#compact_block.prefilled_txns, 0),

    NonceBin = case CB#compact_block.nonce of
        <<N:64/little>> -> <<N:64/little>>;
        N when is_integer(N) -> <<N:64/little>>;
        Bin when is_binary(Bin) -> Bin
    end,

    <<
        (CB#compact_block.header)/binary,
        NonceBin/binary,
        (encode_varint(ShortIdCount))/binary,
        ShortIdBytes/binary,
        (encode_varint(PrefilledCount))/binary,
        PrefilledBytes/binary
    >>.

encode_prefilled_txns([], _LastIdx) ->
    <<>>;
encode_prefilled_txns([{Idx, Tx} | Rest], LastIdx) ->
    DiffIdx = Idx - LastIdx,
    RestBytes = encode_prefilled_txns(Rest, Idx + 1),
    <<(encode_varint(DiffIdx))/binary, Tx/binary, RestBytes/binary>>.

encode_getblocktxn(#block_txn_request{} = Req) ->
    IdxBytes = encode_differential_indexes(Req#block_txn_request.indexes),
    <<
        (Req#block_txn_request.block_hash)/binary,
        (encode_varint(length(Req#block_txn_request.indexes)))/binary,
        IdxBytes/binary
    >>.

encode_blocktxn(#block_txn_response{} = Resp) ->
    TxBytes = list_to_binary(Resp#block_txn_response.transactions),
    <<
        (Resp#block_txn_response.block_hash)/binary,
        (encode_varint(length(Resp#block_txn_response.transactions)))/binary,
        TxBytes/binary
    >>.

encode_differential_indexes(Indexes) ->
    encode_differential_indexes(Indexes, 0, <<>>).

encode_differential_indexes([], _LastIdx, Acc) ->
    Acc;
encode_differential_indexes([Idx | Rest], LastIdx, Acc) ->
    Diff = Idx - LastIdx,
    NewAcc = <<Acc/binary, (encode_varint(Diff))/binary>>,
    encode_differential_indexes(Rest, Idx + 1, NewAcc).

%% ============================================================================
%% Parsing Helpers
%% ============================================================================

parse_short_txids(Data, 0, Acc) ->
    {lists:reverse(Acc), Data};
parse_short_txids(<<ShortId:6/binary, Rest/binary>>, Count, Acc) ->
    parse_short_txids(Rest, Count - 1, [ShortId | Acc]);
parse_short_txids(_, _, _) ->
    throw(invalid_short_txids).

parse_prefilled_txns(Data, 0, _LastIdx, Acc) ->
    {lists:reverse(Acc), Data};
parse_prefilled_txns(Data, Count, LastIdx, Acc) ->
    {DiffIdx, Rest1} = parse_varint(Data),
    ActualIdx = LastIdx + DiffIdx,
    {Tx, Rest2} = parse_transaction(Rest1),
    parse_prefilled_txns(Rest2, Count - 1, ActualIdx + 1, [{ActualIdx, Tx} | Acc]).

parse_differential_indexes(Data, 0, _LastIdx, Acc) ->
    {lists:reverse(Acc), Data};
parse_differential_indexes(Data, Count, LastIdx, Acc) ->
    {DiffIdx, Rest} = parse_varint(Data),
    ActualIdx = LastIdx + DiffIdx,
    parse_differential_indexes(Rest, Count - 1, ActualIdx + 1, [ActualIdx | Acc]).

parse_transactions(Data, 0, Acc) ->
    {lists:reverse(Acc), Data};
parse_transactions(Data, Count, Acc) ->
    {Tx, Rest} = parse_transaction(Data),
    parse_transactions(Rest, Count - 1, [Tx | Acc]).

parse_transaction(Data) ->
    %% Simplified: would need proper tx parsing
    %% For now, assume we can find transaction boundaries
    {Data, <<>>}.

parse_header(<<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary,
               Timestamp:32/little, Bits:32/little, Nonce:32/little>>) ->
    #{
        version => Version,
        prev_block => PrevBlock,
        merkle_root => MerkleRoot,
        timestamp => Timestamp,
        bits => Bits,
        nonce => Nonce
    };
parse_header(_) ->
    #{}.

encode_header(#{version := Version, prev_block := PrevBlock,
                merkle_root := MerkleRoot, timestamp := Timestamp,
                bits := Bits, nonce := Nonce}) ->
    <<Version:32/little, PrevBlock/binary, MerkleRoot/binary,
      Timestamp:32/little, Bits:32/little, Nonce:32/little>>;
encode_header(_) ->
    <<0:640>>.

encode_transaction(_Tx) ->
    %% Would encode full transaction
    <<>>.

compute_tx_hash(Tx) when is_binary(Tx) ->
    crypto:hash(sha256, crypto:hash(sha256, Tx));
compute_tx_hash(_Tx) ->
    <<0:256>>.

%% Varint encoding/decoding
encode_varint(N) when N < 253 ->
    <<N:8>>;
encode_varint(N) when N =< 16#FFFF ->
    <<253:8, N:16/little>>;
encode_varint(N) when N =< 16#FFFFFFFF ->
    <<254:8, N:32/little>>;
encode_varint(N) ->
    <<255:8, N:64/little>>.

parse_varint(<<N:8, Rest/binary>>) when N < 253 ->
    {N, Rest};
parse_varint(<<253:8, N:16/little, Rest/binary>>) ->
    {N, Rest};
parse_varint(<<254:8, N:32/little, Rest/binary>>) ->
    {N, Rest};
parse_varint(<<255:8, N:64/little, Rest/binary>>) ->
    {N, Rest};
parse_varint(_) ->
    throw(invalid_varint).
