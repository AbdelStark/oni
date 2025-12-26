-module(oni_bitcoin).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/oni_bitcoin.gleam").
-export([hash256_from_bytes/1, txid_from_bytes/1, block_hash_from_bytes/1, amount_to_sats/1, script_from_bytes/1, script_to_bytes/1, script_is_empty/1, script_size/1, outpoint_new/2, outpoint_null/0, outpoint_is_null/1, txin_new/3, txout_new/2, transaction_new/4, transaction_has_witness/1, block_header_new/6, block_new/2, mainnet_params/0, testnet_params/0, regtest_params/0, hex_encode/1, hash256_to_hex/1, hex_decode/1, hash256_from_hex/1, reverse_bytes/1, hash256_to_hex_display/1, txid_from_hex/1, txid_to_hex/1, block_hash_from_hex/1, block_hash_to_hex/1, compact_size_encode/1, compact_size_decode/1, sha256/1, sha256d/1, ripemd160/1, hash160/1, hash256_digest/1, tagged_hash/2, pubkey_from_bytes/1, xonly_pubkey_from_bytes/1, pubkey_to_xonly/1, pubkey_to_bytes/1, pubkey_is_compressed/1, signature_from_der/1, schnorr_sig_from_bytes/1, signature_to_der/1, schnorr_sig_to_bytes/1, schnorr_verify/3, ecdsa_verify/3, amount_from_sats/1, amount_from_btc/1, amount_add/2, amount_sub/2]).
-export_type([hash256/0, txid/0, wtxid/0, block_hash/0, amount/0, script/0, out_point/0, tx_in/0, tx_out/0, transaction/0, block_header/0, block/0, network/0, network_params/0, erlang_atom/0, crypto_error/0, pub_key/0, x_only_pub_key/0, signature/0, schnorr_sig/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type hash256() :: {hash256, bitstring()}.

-type txid() :: {txid, hash256()}.

-type wtxid() :: {wtxid, hash256()}.

-type block_hash() :: {block_hash, hash256()}.

-type amount() :: {amount, integer()}.

-type script() :: {script, bitstring()}.

-type out_point() :: {out_point, txid(), integer()}.

-type tx_in() :: {tx_in, out_point(), script(), integer(), list(bitstring())}.

-type tx_out() :: {tx_out, amount(), script()}.

-type transaction() :: {transaction,
        integer(),
        list(tx_in()),
        list(tx_out()),
        integer()}.

-type block_header() :: {block_header,
        integer(),
        block_hash(),
        hash256(),
        integer(),
        integer(),
        integer()}.

-type block() :: {block, block_header(), list(transaction())}.

-type network() :: mainnet | testnet | regtest | signet.

-type network_params() :: {network_params,
        network(),
        integer(),
        integer(),
        binary(),
        integer(),
        block_hash()}.

-type erlang_atom() :: any().

-type crypto_error() :: invalid_public_key |
    invalid_signature |
    invalid_message |
    verification_failed |
    unsupported_operation.

-type pub_key() :: {compressed_pub_key, bitstring()} |
    {uncompressed_pub_key, bitstring()}.

-type x_only_pub_key() :: {x_only_pub_key, bitstring()}.

-type signature() :: {signature, bitstring()}.

-type schnorr_sig() :: {schnorr_sig, bitstring()}.

-file("src/oni_bitcoin.gleam", 41).
?DOC(" Create a Hash256 from raw bytes. Returns Error if not exactly 32 bytes.\n").
-spec hash256_from_bytes(bitstring()) -> {ok, hash256()} | {error, binary()}.
hash256_from_bytes(Bytes) ->
    case erlang:byte_size(Bytes) of
        32 ->
            {ok, {hash256, Bytes}};

        N ->
            {error,
                <<"Expected 32 bytes, got "/utf8,
                    (gleam@int:to_string(N))/binary>>}
    end.

-file("src/oni_bitcoin.gleam", 67).
?DOC(" Create a Txid from bytes (32 bytes, internal byte order)\n").
-spec txid_from_bytes(bitstring()) -> {ok, txid()} | {error, binary()}.
txid_from_bytes(Bytes) ->
    _pipe = hash256_from_bytes(Bytes),
    gleam@result:map(_pipe, fun(Field@0) -> {txid, Field@0} end).

-file("src/oni_bitcoin.gleam", 86).
?DOC(" Create a BlockHash from bytes\n").
-spec block_hash_from_bytes(bitstring()) -> {ok, block_hash()} |
    {error, binary()}.
block_hash_from_bytes(Bytes) ->
    _pipe = hash256_from_bytes(Bytes),
    gleam@result:map(_pipe, fun(Field@0) -> {block_hash, Field@0} end).

-file("src/oni_bitcoin.gleam", 132).
?DOC(" Get satoshi value\n").
-spec amount_to_sats(amount()) -> integer().
amount_to_sats(Amt) ->
    erlang:element(2, Amt).

-file("src/oni_bitcoin.gleam", 156).
?DOC(" Create a Script from raw bytes\n").
-spec script_from_bytes(bitstring()) -> script().
script_from_bytes(Bytes) ->
    {script, Bytes}.

-file("src/oni_bitcoin.gleam", 161).
?DOC(" Get Script bytes\n").
-spec script_to_bytes(script()) -> bitstring().
script_to_bytes(Script) ->
    erlang:element(2, Script).

-file("src/oni_bitcoin.gleam", 166).
?DOC(" Check if script is empty\n").
-spec script_is_empty(script()) -> boolean().
script_is_empty(Script) ->
    erlang:byte_size(erlang:element(2, Script)) =:= 0.

-file("src/oni_bitcoin.gleam", 171).
?DOC(" Get script size in bytes\n").
-spec script_size(script()) -> integer().
script_size(Script) ->
    erlang:byte_size(erlang:element(2, Script)).

-file("src/oni_bitcoin.gleam", 185).
?DOC(" Create an OutPoint\n").
-spec outpoint_new(txid(), integer()) -> out_point().
outpoint_new(Txid, Vout) ->
    {out_point, Txid, Vout}.

-file("src/oni_bitcoin.gleam", 190).
?DOC(" The null outpoint (used in coinbase transactions)\n").
-spec outpoint_null() -> out_point().
outpoint_null() ->
    Null_hash = {hash256, <<0:256>>},
    {out_point, {txid, Null_hash}, 16#FFFFFFFF}.

-file("src/oni_bitcoin.gleam", 196).
?DOC(" Check if this is a null outpoint\n").
-spec outpoint_is_null(out_point()) -> boolean().
outpoint_is_null(Op) ->
    erlang:element(3, Op) =:= 16#FFFFFFFF.

-file("src/oni_bitcoin.gleam", 215).
?DOC(" Create a TxIn\n").
-spec txin_new(out_point(), script(), integer()) -> tx_in().
txin_new(Prevout, Script_sig, Sequence) ->
    {tx_in, Prevout, Script_sig, Sequence, []}.

-file("src/oni_bitcoin.gleam", 239).
?DOC(" Create a TxOut\n").
-spec txout_new(amount(), script()) -> tx_out().
txout_new(Value, Script_pubkey) ->
    {tx_out, Value, Script_pubkey}.

-file("src/oni_bitcoin.gleam", 258).
?DOC(" Create a new transaction\n").
-spec transaction_new(integer(), list(tx_in()), list(tx_out()), integer()) -> transaction().
transaction_new(Version, Inputs, Outputs, Lock_time) ->
    {transaction, Version, Inputs, Outputs, Lock_time}.

-file("src/oni_bitcoin.gleam", 268).
?DOC(" Check if transaction has witness data\n").
-spec transaction_has_witness(transaction()) -> boolean().
transaction_has_witness(Tx) ->
    gleam@list:any(
        erlang:element(3, Tx),
        fun(Input) -> not gleam@list:is_empty(erlang:element(5, Input)) end
    ).

-file("src/oni_bitcoin.gleam", 289).
?DOC(" Create a block header\n").
-spec block_header_new(
    integer(),
    block_hash(),
    hash256(),
    integer(),
    integer(),
    integer()
) -> block_header().
block_header_new(Version, Prev_block, Merkle_root, Timestamp, Bits, Nonce) ->
    {block_header, Version, Prev_block, Merkle_root, Timestamp, Bits, Nonce}.

-file("src/oni_bitcoin.gleam", 310).
?DOC(" Create a block\n").
-spec block_new(block_header(), list(transaction())) -> block().
block_new(Header, Transactions) ->
    {block, Header, Transactions}.

-file("src/oni_bitcoin.gleam", 339).
?DOC(" Mainnet parameters\n").
-spec mainnet_params() -> network_params().
mainnet_params() ->
    Genesis_bytes = <<16#00,
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
    Genesis@1 = case block_hash_from_bytes(Genesis_bytes) of
        {ok, Genesis} -> Genesis;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin"/utf8>>,
                        function => <<"mainnet_params"/utf8>>,
                        line => 346,
                        value => _assert_fail,
                        start => 9275,
                        'end' => 9336,
                        pattern_start => 9286,
                        pattern_end => 9297})
    end,
    {network_params, mainnet, 16#00, 16#05, <<"bc"/utf8>>, 8333, Genesis@1}.

-file("src/oni_bitcoin.gleam", 359).
?DOC(" Testnet parameters\n").
-spec testnet_params() -> network_params().
testnet_params() ->
    Genesis_bytes = <<16#00,
        16#00,
        16#00,
        16#00,
        16#09,
        16#33,
        16#ea,
        16#01,
        16#ad,
        16#0e,
        16#e9,
        16#84,
        16#20,
        16#97,
        16#79,
        16#ba,
        16#ae,
        16#c3,
        16#ce,
        16#d9,
        16#0f,
        16#a3,
        16#f4,
        16#08,
        16#71,
        16#95,
        16#26,
        16#f8,
        16#d7,
        16#7f,
        16#49,
        16#43>>,
    Genesis@1 = case block_hash_from_bytes(Genesis_bytes) of
        {ok, Genesis} -> Genesis;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin"/utf8>>,
                        function => <<"testnet_params"/utf8>>,
                        line => 366,
                        value => _assert_fail,
                        start => 9809,
                        'end' => 9870,
                        pattern_start => 9820,
                        pattern_end => 9831})
    end,
    {network_params, testnet, 16#6F, 16#C4, <<"tb"/utf8>>, 18333, Genesis@1}.

-file("src/oni_bitcoin.gleam", 379).
?DOC(" Regtest parameters\n").
-spec regtest_params() -> network_params().
regtest_params() ->
    Genesis_bytes = <<16#0f,
        16#9e,
        16#8e,
        16#7f,
        16#fd,
        16#13,
        16#18,
        16#8e,
        16#49,
        16#77,
        16#5b,
        16#9b,
        16#02,
        16#13,
        16#e9,
        16#0f,
        16#94,
        16#03,
        16#68,
        16#9e,
        16#2c,
        16#3b,
        16#3f,
        16#4d,
        16#56,
        16#61,
        16#1e,
        16#ac,
        16#25,
        16#29,
        16#3f,
        16#06>>,
    Genesis@1 = case block_hash_from_bytes(Genesis_bytes) of
        {ok, Genesis} -> Genesis;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"oni_bitcoin"/utf8>>,
                        function => <<"regtest_params"/utf8>>,
                        line => 386,
                        value => _assert_fail,
                        start => 10344,
                        'end' => 10405,
                        pattern_start => 10355,
                        pattern_end => 10366})
    end,
    {network_params, regtest, 16#6F, 16#C4, <<"bcrt"/utf8>>, 18444, Genesis@1}.

-file("src/oni_bitcoin.gleam", 410).
-spec do_hex_encode(binary(), bitstring(), binary()) -> binary().
do_hex_encode(_, Bytes, Acc) ->
    case Bytes of
        <<B:8, Rest/bitstring>> ->
            Hi = gleam@int:to_base16(B div 16),
            Lo = gleam@int:to_base16(B rem 16),
            do_hex_encode(
                <<""/utf8>>,
                Rest,
                <<<<Acc/binary, (gleam@string:lowercase(Hi))/binary>>/binary,
                    (gleam@string:lowercase(Lo))/binary>>
            );

        _ ->
            Acc
    end.

-file("src/oni_bitcoin.gleam", 403).
?DOC(" Encode bytes to hex string\n").
-spec hex_encode(bitstring()) -> binary().
hex_encode(Bytes) ->
    _pipe = Bytes,
    _pipe@1 = gleam@bit_array:to_string(_pipe),
    _pipe@2 = gleam@result:unwrap(_pipe@1, <<""/utf8>>),
    do_hex_encode(_pipe@2, Bytes, <<""/utf8>>).

-file("src/oni_bitcoin.gleam", 57).
?DOC(" Convert Hash256 to hex string (internal byte order)\n").
-spec hash256_to_hex(hash256()) -> binary().
hash256_to_hex(Hash) ->
    hex_encode(erlang:element(2, Hash)).

-file("src/oni_bitcoin.gleam", 449).
-spec hex_char_to_int(binary()) -> {ok, integer()} | {error, binary()}.
hex_char_to_int(C) ->
    case C of
        <<"0"/utf8>> ->
            {ok, 0};

        <<"1"/utf8>> ->
            {ok, 1};

        <<"2"/utf8>> ->
            {ok, 2};

        <<"3"/utf8>> ->
            {ok, 3};

        <<"4"/utf8>> ->
            {ok, 4};

        <<"5"/utf8>> ->
            {ok, 5};

        <<"6"/utf8>> ->
            {ok, 6};

        <<"7"/utf8>> ->
            {ok, 7};

        <<"8"/utf8>> ->
            {ok, 8};

        <<"9"/utf8>> ->
            {ok, 9};

        <<"a"/utf8>> ->
            {ok, 10};

        <<"A"/utf8>> ->
            {ok, 10};

        <<"b"/utf8>> ->
            {ok, 11};

        <<"B"/utf8>> ->
            {ok, 11};

        <<"c"/utf8>> ->
            {ok, 12};

        <<"C"/utf8>> ->
            {ok, 12};

        <<"d"/utf8>> ->
            {ok, 13};

        <<"D"/utf8>> ->
            {ok, 13};

        <<"e"/utf8>> ->
            {ok, 14};

        <<"E"/utf8>> ->
            {ok, 14};

        <<"f"/utf8>> ->
            {ok, 15};

        <<"F"/utf8>> ->
            {ok, 15};

        _ ->
            {error, <<"Invalid hex character: "/utf8, C/binary>>}
    end.

-file("src/oni_bitcoin.gleam", 429).
-spec do_hex_decode(binary(), bitstring()) -> {ok, bitstring()} |
    {error, binary()}.
do_hex_decode(Hex, Acc) ->
    case gleam@string:pop_grapheme(Hex) of
        {error, _} ->
            {ok, Acc};

        {ok, {Hi, Rest}} ->
            case gleam@string:pop_grapheme(Rest) of
                {error, _} ->
                    {error, <<"Unexpected end of hex string"/utf8>>};

                {ok, {Lo, Rest2}} ->
                    case {hex_char_to_int(Hi), hex_char_to_int(Lo)} of
                        {{ok, H}, {ok, L}} ->
                            Byte = (H * 16) + L,
                            do_hex_decode(
                                Rest2,
                                gleam@bit_array:append(Acc, <<Byte:8>>)
                            );

                        {_, _} ->
                            {error, <<"Invalid hex character"/utf8>>}
                    end
            end
    end.

-file("src/oni_bitcoin.gleam", 422).
?DOC(" Decode hex string to bytes\n").
-spec hex_decode(binary()) -> {ok, bitstring()} | {error, binary()}.
hex_decode(Hex) ->
    case gleam@string:length(Hex) rem 2 of
        0 ->
            do_hex_decode(Hex, <<>>);

        _ ->
            {error, <<"Hex string must have even length"/utf8>>}
    end.

-file("src/oni_bitcoin.gleam", 49).
?DOC(" Create a Hash256 from a hex string (64 characters)\n").
-spec hash256_from_hex(binary()) -> {ok, hash256()} | {error, binary()}.
hash256_from_hex(Hex) ->
    case hex_decode(Hex) of
        {ok, Bytes} ->
            hash256_from_bytes(Bytes);

        {error, E} ->
            {error, E}
    end.

-file("src/oni_bitcoin.gleam", 480).
-spec do_reverse_bytes(bitstring(), bitstring()) -> bitstring().
do_reverse_bytes(Bytes, Acc) ->
    case Bytes of
        <<B:8, Rest/bitstring>> ->
            do_reverse_bytes(Rest, <<B:8, Acc/bitstring>>);

        _ ->
            Acc
    end.

-file("src/oni_bitcoin.gleam", 476).
?DOC(" Reverse byte order of a BitArray\n").
-spec reverse_bytes(bitstring()) -> bitstring().
reverse_bytes(Bytes) ->
    do_reverse_bytes(Bytes, <<>>).

-file("src/oni_bitcoin.gleam", 62).
?DOC(" Convert Hash256 to hex string in display order (reversed for txid/blockhash)\n").
-spec hash256_to_hex_display(hash256()) -> binary().
hash256_to_hex_display(Hash) ->
    hex_encode(reverse_bytes(erlang:element(2, Hash))).

-file("src/oni_bitcoin.gleam", 73).
?DOC(" Create a Txid from hex (display order - reversed)\n").
-spec txid_from_hex(binary()) -> {ok, txid()} | {error, binary()}.
txid_from_hex(Hex) ->
    case hex_decode(Hex) of
        {ok, Bytes} ->
            _pipe = hash256_from_bytes(reverse_bytes(Bytes)),
            gleam@result:map(_pipe, fun(Field@0) -> {txid, Field@0} end);

        {error, E} ->
            {error, E}
    end.

-file("src/oni_bitcoin.gleam", 81).
?DOC(" Convert Txid to display hex (reversed byte order as shown in explorers)\n").
-spec txid_to_hex(txid()) -> binary().
txid_to_hex(Txid) ->
    hash256_to_hex_display(erlang:element(2, Txid)).

-file("src/oni_bitcoin.gleam", 92).
?DOC(" Create a BlockHash from hex (display order)\n").
-spec block_hash_from_hex(binary()) -> {ok, block_hash()} | {error, binary()}.
block_hash_from_hex(Hex) ->
    case hex_decode(Hex) of
        {ok, Bytes} ->
            _pipe = hash256_from_bytes(reverse_bytes(Bytes)),
            gleam@result:map(_pipe, fun(Field@0) -> {block_hash, Field@0} end);

        {error, E} ->
            {error, E}
    end.

-file("src/oni_bitcoin.gleam", 100).
?DOC(" Convert BlockHash to display hex\n").
-spec block_hash_to_hex(block_hash()) -> binary().
block_hash_to_hex(Hash) ->
    hash256_to_hex_display(erlang:element(2, Hash)).

-file("src/oni_bitcoin.gleam", 492).
?DOC(" Encode an integer as CompactSize\n").
-spec compact_size_encode(integer()) -> bitstring().
compact_size_encode(N) ->
    case N of
        _ when N < 0 ->
            <<>>;

        _ when N < 16#FD ->
            <<N:8>>;

        _ when N =< 16#FFFF ->
            <<16#FD:8, N:16/little>>;

        _ when N =< 16#FFFFFFFF ->
            <<16#FE:8, N:32/little>>;

        _ ->
            <<16#FF:8, N:64/little>>
    end.

-file("src/oni_bitcoin.gleam", 503).
?DOC(" Decode a CompactSize from bytes. Returns (value, remaining_bytes) or Error.\n").
-spec compact_size_decode(bitstring()) -> {ok, {integer(), bitstring()}} |
    {error, binary()}.
compact_size_decode(Bytes) ->
    case Bytes of
        <<16#FF:8, N:64/little, Rest/bitstring>> ->
            {ok, {N, Rest}};

        <<16#FE:8, N@1:32/little, Rest@1/bitstring>> ->
            {ok, {N@1, Rest@1}};

        <<16#FD:8, N@2:16/little, Rest@2/bitstring>> ->
            {ok, {N@2, Rest@2}};

        <<N@3:8, Rest@3/bitstring>> ->
            {ok, {N@3, Rest@3}};

        _ ->
            {error, <<"Insufficient bytes for CompactSize"/utf8>>}
    end.

-file("src/oni_bitcoin.gleam", 518).
?DOC(" SHA256 hash\n").
-spec sha256(bitstring()) -> bitstring().
sha256(Data) ->
    crypto:hash(sha256, Data).

-file("src/oni_bitcoin.gleam", 523).
?DOC(" Double SHA256 (SHA256d) - used extensively in Bitcoin\n").
-spec sha256d(bitstring()) -> bitstring().
sha256d(Data) ->
    sha256(sha256(Data)).

-file("src/oni_bitcoin.gleam", 547).
-spec ripemd160_atom() -> erlang_atom().
ripemd160_atom() ->
    erlang:binary_to_atom(<<"ripemd160"/utf8>>).

-file("src/oni_bitcoin.gleam", 537).
?DOC(" Helper to call Erlang crypto:hash(ripemd160, data)\n").
-spec erlang_ripemd160(bitstring()) -> bitstring().
erlang_ripemd160(Data) ->
    crypto:hash(ripemd160_atom(), Data).

-file("src/oni_bitcoin.gleam", 528).
?DOC(" RIPEMD160 hash - uses Erlang's crypto module directly\n").
-spec ripemd160(bitstring()) -> bitstring().
ripemd160(Data) ->
    erlang_ripemd160(Data).

-file("src/oni_bitcoin.gleam", 552).
?DOC(" HASH160 = RIPEMD160(SHA256(data)) - used for addresses\n").
-spec hash160(bitstring()) -> bitstring().
hash160(Data) ->
    ripemd160(sha256(Data)).

-file("src/oni_bitcoin.gleam", 557).
?DOC(" Compute double-SHA256 hash and return as Hash256\n").
-spec hash256_digest(bitstring()) -> hash256().
hash256_digest(Data) ->
    {hash256, sha256d(Data)}.

-file("src/oni_bitcoin.gleam", 562).
?DOC(" Tagged hash as used in BIP-340 (Taproot)\n").
-spec tagged_hash(binary(), bitstring()) -> bitstring().
tagged_hash(Tag, Data) ->
    Tag_bytes = gleam_stdlib:identity(Tag),
    Tag_hash = sha256(Tag_bytes),
    sha256(gleam_stdlib:bit_array_concat([Tag_hash, Tag_hash, Data])).

-file("src/oni_bitcoin.gleam", 595).
?DOC(" Parse a public key from bytes\n").
-spec pubkey_from_bytes(bitstring()) -> {ok, pub_key()} |
    {error, crypto_error()}.
pubkey_from_bytes(Bytes) ->
    case Bytes of
        <<16#02:8, _:256/bitstring>> ->
            {ok, {compressed_pub_key, Bytes}};

        <<16#03:8, _:256/bitstring>> ->
            {ok, {compressed_pub_key, Bytes}};

        <<16#04:8, _:512/bitstring>> ->
            {ok, {uncompressed_pub_key, Bytes}};

        _ ->
            {error, invalid_public_key}
    end.

-file("src/oni_bitcoin.gleam", 611).
?DOC(" Parse an x-only public key from bytes (32 bytes)\n").
-spec xonly_pubkey_from_bytes(bitstring()) -> {ok, x_only_pub_key()} |
    {error, crypto_error()}.
xonly_pubkey_from_bytes(Bytes) ->
    case erlang:byte_size(Bytes) of
        32 ->
            {ok, {x_only_pub_key, Bytes}};

        _ ->
            {error, invalid_public_key}
    end.

-file("src/oni_bitcoin.gleam", 619).
?DOC(" Convert a compressed public key to x-only (strip the prefix byte)\n").
-spec pubkey_to_xonly(pub_key()) -> {ok, x_only_pub_key()} |
    {error, crypto_error()}.
pubkey_to_xonly(Pubkey) ->
    case Pubkey of
        {compressed_pub_key, Bytes} ->
            case Bytes of
                <<_:8, X:256/bitstring>> ->
                    {ok, {x_only_pub_key, X}};

                _ ->
                    {error, invalid_public_key}
            end;

        {uncompressed_pub_key, _} ->
            {error, unsupported_operation}
    end.

-file("src/oni_bitcoin.gleam", 632).
?DOC(" Get the raw bytes of a public key\n").
-spec pubkey_to_bytes(pub_key()) -> bitstring().
pubkey_to_bytes(Pubkey) ->
    case Pubkey of
        {compressed_pub_key, Bytes} ->
            Bytes;

        {uncompressed_pub_key, Bytes@1} ->
            Bytes@1
    end.

-file("src/oni_bitcoin.gleam", 640).
?DOC(" Check if a public key is compressed\n").
-spec pubkey_is_compressed(pub_key()) -> boolean().
pubkey_is_compressed(Pubkey) ->
    case Pubkey of
        {compressed_pub_key, _} ->
            true;

        {uncompressed_pub_key, _} ->
            false
    end.

-file("src/oni_bitcoin.gleam", 662).
?DOC(" Parse an ECDSA signature from DER bytes\n").
-spec signature_from_der(bitstring()) -> {ok, signature()} |
    {error, crypto_error()}.
signature_from_der(Der) ->
    case Der of
        <<16#30:8, Len:8, Rest/bitstring>> ->
            case erlang:byte_size(Rest) =:= Len of
                true ->
                    {ok, {signature, Der}};

                false ->
                    {error, invalid_signature}
            end;

        _ ->
            {error, invalid_signature}
    end.

-file("src/oni_bitcoin.gleam", 676).
?DOC(" Parse a Schnorr signature from bytes (64 bytes)\n").
-spec schnorr_sig_from_bytes(bitstring()) -> {ok, schnorr_sig()} |
    {error, crypto_error()}.
schnorr_sig_from_bytes(Bytes) ->
    case erlang:byte_size(Bytes) of
        64 ->
            {ok, {schnorr_sig, Bytes}};

        _ ->
            {error, invalid_signature}
    end.

-file("src/oni_bitcoin.gleam", 684).
?DOC(" Get the raw DER bytes of an ECDSA signature\n").
-spec signature_to_der(signature()) -> bitstring().
signature_to_der(Sig) ->
    erlang:element(2, Sig).

-file("src/oni_bitcoin.gleam", 689).
?DOC(" Get the raw bytes of a Schnorr signature\n").
-spec schnorr_sig_to_bytes(schnorr_sig()) -> bitstring().
schnorr_sig_to_bytes(Sig) ->
    erlang:element(2, Sig).

-file("src/oni_bitcoin.gleam", 717).
?DOC(
    " Verify a BIP-340 Schnorr signature\n"
    " Note: Erlang's crypto doesn't support BIP-340 Schnorr directly.\n"
    " This is a placeholder that will need NIF integration for production use.\n"
).
-spec schnorr_verify(schnorr_sig(), bitstring(), x_only_pub_key()) -> {ok,
        boolean()} |
    {error, crypto_error()}.
schnorr_verify(Sig, Msg_hash, Pubkey) ->
    case erlang:byte_size(Msg_hash) of
        32 ->
            _ = Sig,
            _ = Pubkey,
            {error, unsupported_operation};

        _ ->
            {error, invalid_message}
    end.

-file("src/oni_bitcoin.gleam", 760).
-spec ecdsa_atom() -> erlang_atom().
ecdsa_atom() ->
    erlang:binary_to_atom(<<"ecdsa"/utf8>>).

-file("src/oni_bitcoin.gleam", 764).
-spec sha256_atom() -> erlang_atom().
sha256_atom() ->
    erlang:binary_to_atom(<<"sha256"/utf8>>).

-file("src/oni_bitcoin.gleam", 768).
-spec secp256k1_atom() -> erlang_atom().
secp256k1_atom() ->
    erlang:binary_to_atom(<<"secp256k1"/utf8>>).

-file("src/oni_bitcoin.gleam", 736).
?DOC(" Erlang FFI for ECDSA verification on secp256k1\n").
-spec erlang_ecdsa_verify(bitstring(), bitstring(), bitstring()) -> boolean().
erlang_ecdsa_verify(Signature, Message, Pubkey) ->
    crypto:verify(
        ecdsa_atom(),
        sha256_atom(),
        Message,
        Signature,
        {Pubkey, secp256k1_atom()}
    ).

-file("src/oni_bitcoin.gleam", 699).
?DOC(
    " Verify an ECDSA signature against a message hash and public key\n"
    " Note: This uses Erlang's crypto module for secp256k1 ECDSA verification\n"
).
-spec ecdsa_verify(signature(), bitstring(), pub_key()) -> {ok, boolean()} |
    {error, crypto_error()}.
ecdsa_verify(Sig, Msg_hash, Pubkey) ->
    case erlang:byte_size(Msg_hash) of
        32 ->
            Pubkey_bytes = pubkey_to_bytes(Pubkey),
            Result = erlang_ecdsa_verify(
                erlang:element(2, Sig),
                Msg_hash,
                Pubkey_bytes
            ),
            {ok, Result};

        _ ->
            {error, invalid_message}
    end.

-file("src/oni_bitcoin.gleam", 784).
-spec do_float_to_int(float(), integer()) -> integer().
do_float_to_int(F, Acc) ->
    case F < 1.0 of
        true ->
            Acc;

        false ->
            do_float_to_int(F - 1.0, Acc + 1)
    end.

-file("src/oni_bitcoin.gleam", 777).
?DOC(" Convert float to int (truncates)\n").
-spec float_to_int(float()) -> integer().
float_to_int(F) ->
    case F < +0.0 of
        true ->
            0 - float_to_int(+0.0 - F);

        false ->
            do_float_to_int(F, 0)
    end.

-file("src/oni_bitcoin.gleam", 117).
?DOC(" Create an Amount from satoshis. Returns Error if negative or exceeds max.\n").
-spec amount_from_sats(integer()) -> {ok, amount()} | {error, binary()}.
amount_from_sats(Sats) ->
    case Sats of
        S when S < 0 ->
            {error, <<"Amount cannot be negative"/utf8>>};

        S@1 when S@1 > 2100000000000000 ->
            {error, <<"Amount exceeds maximum supply"/utf8>>};

        S@2 ->
            {ok, {amount, S@2}}
    end.

-file("src/oni_bitcoin.gleam", 126).
?DOC(" Create an Amount from BTC (floating point approximation for convenience)\n").
-spec amount_from_btc(float()) -> {ok, amount()} | {error, binary()}.
amount_from_btc(Btc) ->
    Sats = float_to_int(Btc * 100000000.0),
    amount_from_sats(Sats).

-file("src/oni_bitcoin.gleam", 137).
?DOC(" Add two amounts safely\n").
-spec amount_add(amount(), amount()) -> {ok, amount()} | {error, binary()}.
amount_add(A, B) ->
    amount_from_sats(erlang:element(2, A) + erlang:element(2, B)).

-file("src/oni_bitcoin.gleam", 142).
?DOC(" Subtract amounts (a - b). Returns Error if result would be negative.\n").
-spec amount_sub(amount(), amount()) -> {ok, amount()} | {error, binary()}.
amount_sub(A, B) ->
    amount_from_sats(erlang:element(2, A) - erlang:element(2, B)).
