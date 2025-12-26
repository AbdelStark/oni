-module(oni_storage).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/oni_storage.gleam").
-export([coin_new/3, coin_is_mature/2, utxo_view_new/0, chainstate_genesis/1, block_store_new/0, block_store_put/3, block_store_get/2, block_store_has/2, header_store_new/0, header_store_put/3, header_store_get/2, block_undo_new/0, block_undo_add/2, default_db_config/1, get_header/1, get_block/1, get_utxo/1, get_chainstate/0, utxo_get/2, utxo_add/3, utxo_remove/2, utxo_has/2]).
-export_type([storage_error/0, coin/0, utxo_view/0, block_index_entry/0, block_status/0, chainstate/0, block_store/0, header_store/0, tx_undo/0, block_undo/0, db_config/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type storage_error() :: not_found |
    corrupt_data |
    {database_error, binary()} |
    {io_error, binary()} |
    migration_required |
    checksum_mismatch |
    out_of_space |
    {other, binary()}.

-type coin() :: {coin, oni_bitcoin:tx_out(), integer(), boolean()}.

-type utxo_view() :: {utxo_view, gleam@dict:dict(binary(), coin())}.

-type block_index_entry() :: {block_index_entry,
        oni_bitcoin:block_hash(),
        oni_bitcoin:block_hash(),
        integer(),
        block_status(),
        integer(),
        gleam@option:option(integer()),
        gleam@option:option(integer())}.

-type block_status() :: block_valid_unknown |
    block_valid_header |
    block_valid_tree |
    block_valid_transactions |
    block_valid_chain |
    block_valid_scripts |
    block_failed |
    block_failed_child.

-type chainstate() :: {chainstate,
        oni_bitcoin:block_hash(),
        integer(),
        integer(),
        boolean(),
        gleam@option:option(integer())}.

-type block_store() :: {block_store,
        gleam@dict:dict(binary(), oni_bitcoin:block())}.

-type header_store() :: {header_store,
        gleam@dict:dict(binary(), oni_bitcoin:block_header())}.

-type tx_undo() :: {tx_undo, list(coin())}.

-type block_undo() :: {block_undo, list(tx_undo())}.

-type db_config() :: {db_config, binary(), integer(), integer()}.

-file("src/oni_storage.gleam", 48).
?DOC(" Create a new Coin\n").
-spec coin_new(oni_bitcoin:tx_out(), integer(), boolean()) -> coin().
coin_new(Output, Height, Is_coinbase) ->
    {coin, Output, Height, Is_coinbase}.

-file("src/oni_storage.gleam", 53).
?DOC(" Check if coin is mature for spending (for coinbase)\n").
-spec coin_is_mature(coin(), integer()) -> boolean().
coin_is_mature(Coin, Current_height) ->
    case erlang:element(4, Coin) of
        true ->
            (Current_height - erlang:element(3, Coin)) >= 100;

        false ->
            true
    end.

-file("src/oni_storage.gleam", 70).
?DOC(" Create an empty UTXO view\n").
-spec utxo_view_new() -> utxo_view().
utxo_view_new() ->
    {utxo_view, gleam@dict:new()}.

-file("src/oni_storage.gleam", 148).
?DOC(" Create initial chainstate with genesis\n").
-spec chainstate_genesis(oni_bitcoin:block_hash()) -> chainstate().
chainstate_genesis(Genesis_hash) ->
    {chainstate, Genesis_hash, 0, 1, false, none}.

-file("src/oni_storage.gleam", 168).
?DOC(" Create a new empty block store\n").
-spec block_store_new() -> block_store().
block_store_new() ->
    {block_store, gleam@dict:new()}.

-file("src/oni_storage.gleam", 173).
?DOC(" Store a block\n").
-spec block_store_put(
    block_store(),
    oni_bitcoin:block_hash(),
    oni_bitcoin:block()
) -> block_store().
block_store_put(Store, Hash, Block) ->
    Key = oni_bitcoin:block_hash_to_hex(Hash),
    {block_store, gleam@dict:insert(erlang:element(2, Store), Key, Block)}.

-file("src/oni_storage.gleam", 179).
?DOC(" Get a block by hash\n").
-spec block_store_get(block_store(), oni_bitcoin:block_hash()) -> {ok,
        oni_bitcoin:block()} |
    {error, storage_error()}.
block_store_get(Store, Hash) ->
    Key = oni_bitcoin:block_hash_to_hex(Hash),
    case gleam@dict:get(erlang:element(2, Store), Key) of
        {ok, Block} ->
            {ok, Block};

        {error, _} ->
            {error, not_found}
    end.

-file("src/oni_storage.gleam", 188).
?DOC(" Check if block exists\n").
-spec block_store_has(block_store(), oni_bitcoin:block_hash()) -> boolean().
block_store_has(Store, Hash) ->
    Key = oni_bitcoin:block_hash_to_hex(Hash),
    gleam@dict:has_key(erlang:element(2, Store), Key).

-file("src/oni_storage.gleam", 203).
?DOC(" Create a new header store\n").
-spec header_store_new() -> header_store().
header_store_new() ->
    {header_store, gleam@dict:new()}.

-file("src/oni_storage.gleam", 208).
?DOC(" Store a header\n").
-spec header_store_put(
    header_store(),
    oni_bitcoin:block_hash(),
    oni_bitcoin:block_header()
) -> header_store().
header_store_put(Store, Hash, Header) ->
    Key = oni_bitcoin:block_hash_to_hex(Hash),
    {header_store, gleam@dict:insert(erlang:element(2, Store), Key, Header)}.

-file("src/oni_storage.gleam", 214).
?DOC(" Get a header by hash\n").
-spec header_store_get(header_store(), oni_bitcoin:block_hash()) -> {ok,
        oni_bitcoin:block_header()} |
    {error, storage_error()}.
header_store_get(Store, Hash) ->
    Key = oni_bitcoin:block_hash_to_hex(Hash),
    case gleam@dict:get(erlang:element(2, Store), Key) of
        {ok, Header} ->
            {ok, Header};

        {error, _} ->
            {error, not_found}
    end.

-file("src/oni_storage.gleam", 237).
?DOC(" Create empty block undo\n").
-spec block_undo_new() -> block_undo().
block_undo_new() ->
    {block_undo, []}.

-file("src/oni_storage.gleam", 242).
?DOC(" Add transaction undo to block undo\n").
-spec block_undo_add(block_undo(), tx_undo()) -> block_undo().
block_undo_add(Undo, Tx_undo) ->
    {block_undo, [Tx_undo | erlang:element(2, Undo)]}.

-file("src/oni_storage.gleam", 260).
?DOC(" Default database configuration\n").
-spec default_db_config(binary()) -> db_config().
default_db_config(Path) ->
    {db_config, Path, (450 * 1024) * 1024, 64}.

-file("src/oni_storage.gleam", 273).
?DOC(" Get header by hash (placeholder)\n").
-spec get_header(oni_bitcoin:block_hash()) -> {ok, nil} |
    {error, storage_error()}.
get_header(_) ->
    {error, not_found}.

-file("src/oni_storage.gleam", 278).
?DOC(" Get block by hash (placeholder)\n").
-spec get_block(oni_bitcoin:block_hash()) -> {ok, oni_bitcoin:block()} |
    {error, storage_error()}.
get_block(_) ->
    {error, not_found}.

-file("src/oni_storage.gleam", 283).
?DOC(" Get UTXO by outpoint (placeholder)\n").
-spec get_utxo(oni_bitcoin:out_point()) -> {ok, coin()} |
    {error, storage_error()}.
get_utxo(_) ->
    {error, not_found}.

-file("src/oni_storage.gleam", 288).
?DOC(" Get current chainstate (placeholder)\n").
-spec get_chainstate() -> {ok, chainstate()} | {error, storage_error()}.
get_chainstate() ->
    {error, not_found}.

-file("src/oni_storage.gleam", 303).
-spec do_int_to_string(integer(), binary()) -> binary().
do_int_to_string(N, Acc) ->
    case N of
        0 ->
            Acc;

        _ ->
            Digit = N rem 10,
            Char = case Digit of
                0 ->
                    <<"0"/utf8>>;

                1 ->
                    <<"1"/utf8>>;

                2 ->
                    <<"2"/utf8>>;

                3 ->
                    <<"3"/utf8>>;

                4 ->
                    <<"4"/utf8>>;

                5 ->
                    <<"5"/utf8>>;

                6 ->
                    <<"6"/utf8>>;

                7 ->
                    <<"7"/utf8>>;

                8 ->
                    <<"8"/utf8>>;

                _ ->
                    <<"9"/utf8>>
            end,
            do_int_to_string(N div 10, <<Char/binary, Acc/binary>>)
    end.

-file("src/oni_storage.gleam", 296).
-spec int_to_string(integer()) -> binary().
int_to_string(N) ->
    case N of
        0 ->
            <<"0"/utf8>>;

        _ ->
            do_int_to_string(N, <<""/utf8>>)
    end.

-file("src/oni_storage.gleam", 99).
-spec outpoint_to_key(oni_bitcoin:out_point()) -> binary().
outpoint_to_key(Outpoint) ->
    <<<<(oni_bitcoin:txid_to_hex(erlang:element(2, Outpoint)))/binary,
            ":"/utf8>>/binary,
        (int_to_string(erlang:element(3, Outpoint)))/binary>>.

-file("src/oni_storage.gleam", 75).
?DOC(" Lookup a coin by outpoint\n").
-spec utxo_get(utxo_view(), oni_bitcoin:out_point()) -> gleam@option:option(coin()).
utxo_get(View, Outpoint) ->
    Key = outpoint_to_key(Outpoint),
    _pipe = gleam@dict:get(erlang:element(2, View), Key),
    gleam@option:from_result(_pipe).

-file("src/oni_storage.gleam", 82).
?DOC(" Add a coin to the view\n").
-spec utxo_add(utxo_view(), oni_bitcoin:out_point(), coin()) -> utxo_view().
utxo_add(View, Outpoint, Coin) ->
    Key = outpoint_to_key(Outpoint),
    {utxo_view, gleam@dict:insert(erlang:element(2, View), Key, Coin)}.

-file("src/oni_storage.gleam", 88).
?DOC(" Remove a coin from the view\n").
-spec utxo_remove(utxo_view(), oni_bitcoin:out_point()) -> utxo_view().
utxo_remove(View, Outpoint) ->
    Key = outpoint_to_key(Outpoint),
    {utxo_view, gleam@dict:delete(erlang:element(2, View), Key)}.

-file("src/oni_storage.gleam", 94).
?DOC(" Check if a coin exists\n").
-spec utxo_has(utxo_view(), oni_bitcoin:out_point()) -> boolean().
utxo_has(View, Outpoint) ->
    Key = outpoint_to_key(Outpoint),
    gleam@dict:has_key(erlang:element(2, View), Key).
