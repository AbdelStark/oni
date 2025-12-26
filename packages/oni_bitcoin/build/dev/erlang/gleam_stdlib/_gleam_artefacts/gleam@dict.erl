-module(gleam@dict).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/dict.gleam").
-export([size/1, to_list/1, new/0, get/2, has_key/2, insert/3, from_list/1, keys/1, values/1, take/2, merge/2, delete/2, drop/2, update/3, fold/3, map_values/2, filter/2]).
-export_type([dict/2]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type dict(KS, KT) :: any() | {gleam_phantom, KS, KT}.

-file("src/gleam/dict.gleam", 36).
?DOC(
    " Determines the number of key-value pairs in the dict.\n"
    " This function runs in constant time and does not need to iterate the dict.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new() |> size\n"
    " // -> 0\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(\"key\", \"value\") |> size\n"
    " // -> 1\n"
    " ```\n"
).
-spec size(dict(any(), any())) -> integer().
size(Dict) ->
    maps:size(Dict).

-file("src/gleam/dict.gleam", 57).
?DOC(
    " Converts the dict to a list of 2-element tuples `#(key, value)`, one for\n"
    " each key-value pair in the dict.\n"
    "\n"
    " The tuples in the list have no specific order.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new()\n"
    " // -> from_list([])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(\"key\", 0)\n"
    " // -> from_list([#(\"key\", 0)])\n"
    " ```\n"
).
-spec to_list(dict(KY, KZ)) -> list({KY, KZ}).
to_list(Dict) ->
    maps:to_list(Dict).

-file("src/gleam/dict.gleam", 104).
?DOC(" Creates a fresh dict that contains no values.\n").
-spec new() -> dict(any(), any()).
new() ->
    maps:new().

-file("src/gleam/dict.gleam", 129).
?DOC(
    " Fetches a value from a dict for a given key.\n"
    "\n"
    " The dict may not have a value for the key, so the value is wrapped in a\n"
    " `Result`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(\"a\", 0) |> get(\"a\")\n"
    " // -> Ok(0)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(\"a\", 0) |> get(\"b\")\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec get(dict(MF, MG), MF) -> {ok, MG} | {error, nil}.
get(From, Get) ->
    gleam_stdlib:map_get(From, Get).

-file("src/gleam/dict.gleam", 93).
?DOC(
    " Determines whether or not a value present in the dict for a given key.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(\"a\", 0) |> has_key(\"a\")\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(\"a\", 0) |> has_key(\"b\")\n"
    " // -> False\n"
    " ```\n"
).
-spec has_key(dict(LP, any()), LP) -> boolean().
has_key(Dict, Key) ->
    maps:is_key(Key, Dict).

-file("src/gleam/dict.gleam", 154).
?DOC(
    " Inserts a value into the dict with the given key.\n"
    "\n"
    " If the dict already has a value for the given key then the value is\n"
    " replaced with the new value.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(\"a\", 0)\n"
    " // -> from_list([#(\"a\", 0)])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(\"a\", 0) |> insert(\"a\", 5)\n"
    " // -> from_list([#(\"a\", 5)])\n"
    " ```\n"
).
-spec insert(dict(MR, MS), MR, MS) -> dict(MR, MS).
insert(Dict, Key, Value) ->
    maps:put(Key, Value, Dict).

-file("src/gleam/dict.gleam", 69).
-spec fold_list_of_pair(list({LI, LJ}), dict(LI, LJ)) -> dict(LI, LJ).
fold_list_of_pair(List, Initial) ->
    case List of
        [] ->
            Initial;

        [X | Rest] ->
            fold_list_of_pair(
                Rest,
                insert(Initial, erlang:element(1, X), erlang:element(2, X))
            )
    end.

-file("src/gleam/dict.gleam", 65).
?DOC(
    " Converts a list of 2-element tuples `#(key, value)` to a dict.\n"
    "\n"
    " If two tuples have the same key the last one in the list will be the one\n"
    " that is present in the dict.\n"
).
-spec from_list(list({LD, LE})) -> dict(LD, LE).
from_list(List) ->
    maps:from_list(List).

-file("src/gleam/dict.gleam", 211).
-spec reverse_and_concat(list(TS), list(TS)) -> list(TS).
reverse_and_concat(Remaining, Accumulator) ->
    case Remaining of
        [] ->
            Accumulator;

        [Item | Rest] ->
            reverse_and_concat(Rest, [Item | Accumulator])
    end.

-file("src/gleam/dict.gleam", 218).
-spec do_keys_acc(list({OE, any()}), list(OE)) -> list(OE).
do_keys_acc(List, Acc) ->
    case List of
        [] ->
            reverse_and_concat(Acc, []);

        [X | Xs] ->
            do_keys_acc(Xs, [erlang:element(1, X) | Acc])
    end.

-file("src/gleam/dict.gleam", 201).
?DOC(
    " Gets a list of all keys in a given dict.\n"
    "\n"
    " Dicts are not ordered so the keys are not returned in any specific order. Do\n"
    " not write code that relies on the order keys are returned by this function\n"
    " as it may change in later versions of Gleam or Erlang.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)]) |> keys\n"
    " // -> [\"a\", \"b\"]\n"
    " ```\n"
).
-spec keys(dict(NR, any())) -> list(NR).
keys(Dict) ->
    maps:keys(Dict).

-file("src/gleam/dict.gleam", 248).
-spec do_values_acc(list({any(), OU}), list(OU)) -> list(OU).
do_values_acc(List, Acc) ->
    case List of
        [] ->
            reverse_and_concat(Acc, []);

        [X | Xs] ->
            do_values_acc(Xs, [erlang:element(2, X) | Acc])
    end.

-file("src/gleam/dict.gleam", 238).
?DOC(
    " Gets a list of all values in a given dict.\n"
    "\n"
    " Dicts are not ordered so the values are not returned in any specific order. Do\n"
    " not write code that relies on the order values are returned by this function\n"
    " as it may change in later versions of Gleam or Erlang.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)]) |> values\n"
    " // -> [0, 1]\n"
    " ```\n"
).
-spec values(dict(any(), OK)) -> list(OK).
values(Dict) ->
    maps:values(Dict).

-file("src/gleam/dict.gleam", 323).
-spec insert_taken(dict(PY, PZ), list(PY), dict(PY, PZ)) -> dict(PY, PZ).
insert_taken(Dict, Desired_keys, Acc) ->
    Insert = fun(Taken, Key) -> case get(Dict, Key) of
            {ok, Value} ->
                insert(Taken, Key, Value);

            _ ->
                Taken
        end end,
    case Desired_keys of
        [] ->
            Acc;

        [X | Xs] ->
            insert_taken(Dict, Xs, Insert(Acc, X))
    end.

-file("src/gleam/dict.gleam", 311).
?DOC(
    " Creates a new dict from a given dict, only including any entries for which the\n"
    " keys are in a given list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " |> take([\"b\"])\n"
    " // -> from_list([#(\"b\", 1)])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " |> take([\"a\", \"b\", \"c\"])\n"
    " // -> from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " ```\n"
).
-spec take(dict(PK, PL), list(PK)) -> dict(PK, PL).
take(Dict, Desired_keys) ->
    maps:with(Desired_keys, Dict).

-file("src/gleam/dict.gleam", 368).
-spec insert_pair(dict(QX, QY), {QX, QY}) -> dict(QX, QY).
insert_pair(Dict, Pair) ->
    insert(Dict, erlang:element(1, Pair), erlang:element(2, Pair)).

-file("src/gleam/dict.gleam", 372).
-spec fold_inserts(list({RD, RE}), dict(RD, RE)) -> dict(RD, RE).
fold_inserts(New_entries, Dict) ->
    case New_entries of
        [] ->
            Dict;

        [X | Xs] ->
            fold_inserts(Xs, insert_pair(Dict, X))
    end.

-file("src/gleam/dict.gleam", 354).
?DOC(
    " Creates a new dict from a pair of given dicts by combining their entries.\n"
    "\n"
    " If there are entries with the same keys in both dicts the entry from the\n"
    " second dict takes precedence.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " let a = from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " let b = from_list([#(\"b\", 2), #(\"c\", 3)])\n"
    " merge(a, b)\n"
    " // -> from_list([#(\"a\", 0), #(\"b\", 2), #(\"c\", 3)])\n"
    " ```\n"
).
-spec merge(dict(QH, QI), dict(QH, QI)) -> dict(QH, QI).
merge(Dict, New_entries) ->
    maps:merge(Dict, New_entries).

-file("src/gleam/dict.gleam", 394).
?DOC(
    " Creates a new dict from a given dict with all the same entries except for the\n"
    " one with a given key, if it exists.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)]) |> delete(\"a\")\n"
    " // -> from_list([#(\"b\", 1)])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)]) |> delete(\"c\")\n"
    " // -> from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " ```\n"
).
-spec delete(dict(RK, RL), RK) -> dict(RK, RL).
delete(Dict, Key) ->
    maps:remove(Key, Dict).

-file("src/gleam/dict.gleam", 422).
?DOC(
    " Creates a new dict from a given dict with all the same entries except any with\n"
    " keys found in a given list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)]) |> drop([\"a\"])\n"
    " // -> from_list([#(\"b\", 2)])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)]) |> drop([\"c\"])\n"
    " // -> from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)]) |> drop([\"a\", \"b\", \"c\"])\n"
    " // -> from_list([])\n"
    " ```\n"
).
-spec drop(dict(RW, RX), list(RW)) -> dict(RW, RX).
drop(Dict, Disallowed_keys) ->
    case Disallowed_keys of
        [] ->
            Dict;

        [X | Xs] ->
            drop(delete(Dict, X), Xs)
    end.

-file("src/gleam/dict.gleam", 455).
?DOC(
    " Creates a new dict with one entry updated using a given function.\n"
    "\n"
    " If there was not an entry in the dict for the given key then the function\n"
    " gets `None` as its argument, otherwise it gets `Some(value)`.\n"
    "\n"
    " ## Example\n"
    "\n"
    " ```gleam\n"
    " let dict = from_list([#(\"a\", 0)])\n"
    " let increment = fn(x) {\n"
    "   case x {\n"
    "     Some(i) -> i + 1\n"
    "     None -> 0\n"
    "   }\n"
    " }\n"
    "\n"
    "  update(dict, \"a\", increment)\n"
    " // -> from_list([#(\"a\", 1)])\n"
    "\n"
    " update(dict, \"b\", increment)\n"
    " // -> from_list([#(\"a\", 0), #(\"b\", 0)])\n"
    " ```\n"
).
-spec update(dict(SD, SE), SD, fun((gleam@option:option(SE)) -> SE)) -> dict(SD, SE).
update(Dict, Key, Fun) ->
    _pipe = Dict,
    _pipe@1 = get(_pipe, Key),
    _pipe@2 = gleam@option:from_result(_pipe@1),
    _pipe@3 = Fun(_pipe@2),
    insert(Dict, Key, _pipe@3).

-file("src/gleam/dict.gleam", 467).
-spec do_fold(list({SK, SL}), SN, fun((SN, SK, SL) -> SN)) -> SN.
do_fold(List, Initial, Fun) ->
    case List of
        [] ->
            Initial;

        [{K, V} | Rest] ->
            do_fold(Rest, Fun(Initial, K, V), Fun)
    end.

-file("src/gleam/dict.gleam", 503).
?DOC(
    " Combines all entries into a single value by calling a given function on each\n"
    " one.\n"
    "\n"
    " Dicts are not ordered so the values are not returned in any specific order. Do\n"
    " not write code that relies on the order entries are used by this function\n"
    " as it may change in later versions of Gleam or Erlang.\n"
    "\n"
    " # Examples\n"
    "\n"
    " ```gleam\n"
    " let dict = from_list([#(\"a\", 1), #(\"b\", 3), #(\"c\", 9)])\n"
    " fold(dict, 0, fn(accumulator, key, value) { accumulator + value })\n"
    " // -> 13\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " import gleam/string\n"
    "\n"
    " let dict = from_list([#(\"a\", 1), #(\"b\", 3), #(\"c\", 9)])\n"
    " fold(dict, \"\", fn(accumulator, key, value) {\n"
    "   string.append(accumulator, key)\n"
    " })\n"
    " // -> \"abc\"\n"
    " ```\n"
).
-spec fold(dict(SO, SP), SS, fun((SS, SO, SP) -> SS)) -> SS.
fold(Dict, Initial, Fun) ->
    _pipe = Dict,
    _pipe@1 = maps:to_list(_pipe),
    do_fold(_pipe@1, Initial, Fun).

-file("src/gleam/dict.gleam", 177).
?DOC(
    " Updates all values in a given dict by calling a given function on each key\n"
    " and value.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([#(3, 3), #(2, 4)])\n"
    " |> map_values(fn(key, value) { key * value })\n"
    " // -> from_list([#(3, 9), #(2, 8)])\n"
    " ```\n"
).
-spec map_values(dict(ND, NE), fun((ND, NE) -> NH)) -> dict(ND, NH).
map_values(Dict, Fun) ->
    maps:map(Fun, Dict).

-file("src/gleam/dict.gleam", 272).
?DOC(
    " Creates a new dict from a given dict, minus any entries that a given function\n"
    " returns `False` for.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " |> filter(fn(key, value) { value != 0 })\n"
    " // -> from_list([#(\"b\", 1)])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " |> filter(fn(key, value) { True })\n"
    " // -> from_list([#(\"a\", 0), #(\"b\", 1)])\n"
    " ```\n"
).
-spec filter(dict(OY, OZ), fun((OY, OZ) -> boolean())) -> dict(OY, OZ).
filter(Dict, Predicate) ->
    maps:filter(Predicate, Dict).
