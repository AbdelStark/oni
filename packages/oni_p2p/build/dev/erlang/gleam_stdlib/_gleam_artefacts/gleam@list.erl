-module(gleam@list).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/list.gleam").
-export([length/1, reverse/1, is_empty/1, contains/2, first/1, rest/1, filter/2, filter_map/2, map/2, map2/3, index_map/2, try_map/2, drop/2, take/2, new/0, append/2, prepend/2, concat/1, flatten/1, flat_map/2, fold/3, group/2, map_fold/3, fold_right/3, index_fold/3, try_fold/3, fold_until/3, find/2, find_map/2, all/2, any/2, zip/2, strict_zip/2, unzip/1, intersperse/2, at/2, unique/1, sort/2, range/2, repeat/2, split/2, split_while/2, key_find/2, key_filter/2, pop/2, pop_map/2, key_pop/2, key_set/3, each/2, try_each/2, partition/2, permutations/1, window/2, window_by_2/1, drop_while/2, take_while/2, chunk/2, sized_chunk/2, reduce/2, scan/3, last/1, combinations/2, combination_pairs/1, transpose/1, interleave/1, shuffle/1]).
-export_type([length_mismatch/0, continue_or_stop/1]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

?MODULEDOC(
    " Lists are an ordered sequence of elements and are one of the most common\n"
    " data types in Gleam.\n"
    "\n"
    " New elements can be added and removed from the front of a list in\n"
    " constant time, while adding and removing from the end requires traversing\n"
    " the copying the whole list, so keep this in mind when designing your\n"
    " programs.\n"
    "\n"
    " There is a dedicated syntax for prefixing to a list:\n"
    "\n"
    " ```gleam\n"
    " let new_list = [1, 2, ..existing_list]\n"
    " ```\n"
    "\n"
    " And a matching syntax for getting the first elements of a list:\n"
    "\n"
    " ```gleam\n"
    " case list {\n"
    "   [first_element, ..rest] -> first_element\n"
    "   _ -> \"this pattern matches when the list is empty\"\n"
    " }\n"
    " ```\n"
    "\n"
).

-type length_mismatch() :: length_mismatch.

-type continue_or_stop(XP) :: {continue, XP} | {stop, XP}.

-file("src/gleam/list.gleam", 62).
?DOC(
    " Counts the number of elements in a given list.\n"
    "\n"
    " This function has to traverse the list to determine the number of elements,\n"
    " so it runs in linear time.\n"
    "\n"
    " This function is natively implemented by the virtual machine and is highly\n"
    " optimised.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " length([])\n"
    " // -> 0\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " length([1])\n"
    " // -> 1\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " length([1, 2])\n"
    " // -> 2\n"
    " ```\n"
).
-spec length(list(any())) -> integer().
length(List) ->
    erlang:length(List).

-file("src/gleam/list.gleam", 109).
?DOC(
    " Creates a new list from a given list containing the same elements but in the\n"
    " opposite order.\n"
    "\n"
    " This function has to traverse the list to create the new reversed list, so\n"
    " it runs in linear time.\n"
    "\n"
    " This function is natively implemented by the virtual machine and is highly\n"
    " optimised.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " reverse([])\n"
    " // -> []\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " reverse([1])\n"
    " // -> [1]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " reverse([1, 2])\n"
    " // -> [2, 1]\n"
    " ```\n"
).
-spec reverse(list(XU)) -> list(XU).
reverse(Xs) ->
    lists:reverse(Xs).

-file("src/gleam/list.gleam", 151).
?DOC(
    " Determines whether or not the list is empty.\n"
    "\n"
    " This function runs in constant time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " is_empty([])\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " is_empty([1])\n"
    " // -> False\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " is_empty([1, 1])\n"
    " // -> False\n"
    " ```\n"
).
-spec is_empty(list(any())) -> boolean().
is_empty(List) ->
    List =:= [].

-file("src/gleam/list.gleam", 187).
?DOC(
    " Determines whether or not a given element exists within a given list.\n"
    "\n"
    " This function traverses the list to find the element, so it runs in linear\n"
    " time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " [] |> contains(any: 0)\n"
    " // -> False\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " [0] |> contains(any: 0)\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " [1] |> contains(any: 0)\n"
    " // -> False\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " [1, 1] |> contains(any: 0)\n"
    " // -> False\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " [1, 0] |> contains(any: 0)\n"
    " // -> True\n"
    " ```\n"
).
-spec contains(list(YC), YC) -> boolean().
contains(List, Elem) ->
    case List of
        [] ->
            false;

        [First | _] when First =:= Elem ->
            true;

        [_ | Rest] ->
            contains(Rest, Elem)
    end.

-file("src/gleam/list.gleam", 214).
?DOC(
    " Gets the first element from the start of the list, if there is one.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " first([])\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " first([0])\n"
    " // -> Ok(0)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " first([1, 2])\n"
    " // -> Ok(1)\n"
    " ```\n"
).
-spec first(list(YE)) -> {ok, YE} | {error, nil}.
first(List) ->
    case List of
        [] ->
            {error, nil};

        [X | _] ->
            {ok, X}
    end.

-file("src/gleam/list.gleam", 243).
?DOC(
    " Returns the list minus the first element. If the list is empty, `Error(Nil)` is\n"
    " returned.\n"
    "\n"
    " This function runs in constant time and does not make a copy of the list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " rest([])\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " rest([0])\n"
    " // -> Ok([])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " rest([1, 2])\n"
    " // -> Ok([2])\n"
    " ```\n"
).
-spec rest(list(YI)) -> {ok, list(YI)} | {error, nil}.
rest(List) ->
    case List of
        [] ->
            {error, nil};

        [_ | Xs] ->
            {ok, Xs}
    end.

-file("src/gleam/list.gleam", 250).
-spec update_group(fun((YN) -> YO)) -> fun((gleam@dict:dict(YO, list(YN)), YN) -> gleam@dict:dict(YO, list(YN))).
update_group(F) ->
    fun(Groups, Elem) -> case gleam@dict:get(Groups, F(Elem)) of
            {ok, Existing} ->
                gleam@dict:insert(Groups, F(Elem), [Elem | Existing]);

            {error, _} ->
                gleam@dict:insert(Groups, F(Elem), [Elem])
        end end.

-file("src/gleam/list.gleam", 296).
-spec do_filter(list(AAB), fun((AAB) -> boolean()), list(AAB)) -> list(AAB).
do_filter(List, Fun, Acc) ->
    case List of
        [] ->
            reverse(Acc);

        [X | Xs] ->
            New_acc = case Fun(X) of
                true ->
                    [X | Acc];

                false ->
                    Acc
            end,
            do_filter(Xs, Fun, New_acc)
    end.

-file("src/gleam/list.gleam", 324).
?DOC(
    " Returns a new list containing only the elements from the first list for\n"
    " which the given functions returns `True`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " filter([2, 4, 6, 1], fn(x) { x > 2 })\n"
    " // -> [4, 6]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " filter([2, 4, 6, 1], fn(x) { x > 6 })\n"
    " // -> []\n"
    " ```\n"
).
-spec filter(list(AAF), fun((AAF) -> boolean())) -> list(AAF).
filter(List, Predicate) ->
    do_filter(List, Predicate, []).

-file("src/gleam/list.gleam", 328).
-spec do_filter_map(
    list(AAI),
    fun((AAI) -> {ok, AAK} | {error, any()}),
    list(AAK)
) -> list(AAK).
do_filter_map(List, Fun, Acc) ->
    case List of
        [] ->
            reverse(Acc);

        [X | Xs] ->
            New_acc = case Fun(X) of
                {ok, X@1} ->
                    [X@1 | Acc];

                {error, _} ->
                    Acc
            end,
            do_filter_map(Xs, Fun, New_acc)
    end.

-file("src/gleam/list.gleam", 360).
?DOC(
    " Returns a new list containing only the elements from the first list for\n"
    " which the given functions returns `Ok(_)`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " filter_map([2, 4, 6, 1], Error)\n"
    " // -> []\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " filter_map([2, 4, 6, 1], fn(x) { Ok(x + 1) })\n"
    " // -> [3, 5, 7, 2]\n"
    " ```\n"
).
-spec filter_map(list(AAQ), fun((AAQ) -> {ok, AAS} | {error, any()})) -> list(AAS).
filter_map(List, Fun) ->
    do_filter_map(List, Fun, []).

-file("src/gleam/list.gleam", 364).
-spec do_map(list(AAX), fun((AAX) -> AAZ), list(AAZ)) -> list(AAZ).
do_map(List, Fun, Acc) ->
    case List of
        [] ->
            reverse(Acc);

        [X | Xs] ->
            do_map(Xs, Fun, [Fun(X) | Acc])
    end.

-file("src/gleam/list.gleam", 381).
?DOC(
    " Returns a new list containing only the elements of the first list after the\n"
    " function has been applied to each one.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " map([2, 4, 6], fn(x) { x * 2 })\n"
    " // -> [4, 8, 12]\n"
    " ```\n"
).
-spec map(list(ABC), fun((ABC) -> ABE)) -> list(ABE).
map(List, Fun) ->
    do_map(List, Fun, []).

-file("src/gleam/list.gleam", 409).
-spec do_map2(list(ABM), list(ABO), fun((ABM, ABO) -> ABQ), list(ABQ)) -> list(ABQ).
do_map2(List1, List2, Fun, Acc) ->
    case {List1, List2} of
        {[], _} ->
            reverse(Acc);

        {_, []} ->
            reverse(Acc);

        {[A | As_], [B | Bs]} ->
            do_map2(As_, Bs, Fun, [Fun(A, B) | Acc])
    end.

-file("src/gleam/list.gleam", 401).
?DOC(
    " Combines two lists into a single list using the given function.\n"
    "\n"
    " If a list is longer than the other the extra elements are dropped.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " map2([1, 2, 3], [4, 5, 6], fn(x, y) { x + y })\n"
    " // -> [5, 7, 9]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " map2([1, 2], [\"a\", \"b\", \"c\"], fn(i, x) { #(i, x) })\n"
    " // -> [#(1, \"a\"), #(2, \"b\")]\n"
    " ```\n"
).
-spec map2(list(ABG), list(ABI), fun((ABG, ABI) -> ABK)) -> list(ABK).
map2(List1, List2, Fun) ->
    do_map2(List1, List2, Fun, []).

-file("src/gleam/list.gleam", 447).
-spec do_index_map(
    list(ABY),
    fun((ABY, integer()) -> ACA),
    integer(),
    list(ACA)
) -> list(ACA).
do_index_map(List, Fun, Index, Acc) ->
    case List of
        [] ->
            reverse(Acc);

        [X | Xs] ->
            Acc@1 = [Fun(X, Index) | Acc],
            do_index_map(Xs, Fun, Index + 1, Acc@1)
    end.

-file("src/gleam/list.gleam", 475).
?DOC(
    " Returns a new list containing only the elements of the first list after the\n"
    " function has been applied to each one and their index.\n"
    "\n"
    " The index starts at 0, so the first element is 0, the second is 1, and so\n"
    " on.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " index_map([\"a\", \"b\"], fn(x, i) { #(i, x) })\n"
    " // -> [#(0, \"a\"), #(1, \"b\")]\n"
    " ```\n"
).
-spec index_map(list(ACD), fun((ACD, integer()) -> ACF)) -> list(ACF).
index_map(List, Fun) ->
    do_index_map(List, Fun, 0, []).

-file("src/gleam/list.gleam", 479).
-spec do_try_map(list(ACH), fun((ACH) -> {ok, ACJ} | {error, ACK}), list(ACJ)) -> {ok,
        list(ACJ)} |
    {error, ACK}.
do_try_map(List, Fun, Acc) ->
    case List of
        [] ->
            {ok, reverse(Acc)};

        [X | Xs] ->
            case Fun(X) of
                {ok, Y} ->
                    do_try_map(Xs, Fun, [Y | Acc]);

                {error, Error} ->
                    {error, Error}
            end
    end.

-file("src/gleam/list.gleam", 526).
?DOC(
    " Takes a function that returns a `Result` and applies it to each element in a\n"
    " given list in turn.\n"
    "\n"
    " If the function returns `Ok(new_value)` for all elements in the list then a\n"
    " list of the new values is returned.\n"
    "\n"
    " If the function returns `Error(reason)` for any of the elements then it is\n"
    " returned immediately. None of the elements in the list are processed after\n"
    " one returns an `Error`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " try_map([1, 2, 3], fn(x) { Ok(x + 2) })\n"
    " // -> Ok([3, 4, 5])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " try_map([1, 2, 3], fn(_) { Error(0) })\n"
    " // -> Error(0)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " try_map([[1], [2, 3]], first)\n"
    " // -> Ok([1, 2])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " try_map([[1], [], [2]], first)\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec try_map(list(ACR), fun((ACR) -> {ok, ACT} | {error, ACU})) -> {ok,
        list(ACT)} |
    {error, ACU}.
try_map(List, Fun) ->
    do_try_map(List, Fun, []).

-file("src/gleam/list.gleam", 553).
?DOC(
    " Returns a list that is the given list with up to the given number of\n"
    " elements removed from the front of the list.\n"
    "\n"
    " If the element has less than the number of elements an empty list is\n"
    " returned.\n"
    "\n"
    " This function runs in linear time but does not copy the list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " drop([1, 2, 3, 4], 2)\n"
    " // -> [3, 4]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " drop([1, 2, 3, 4], 9)\n"
    " // -> []\n"
    " ```\n"
).
-spec drop(list(ADA), integer()) -> list(ADA).
drop(List, N) ->
    case N =< 0 of
        true ->
            List;

        false ->
            case List of
                [] ->
                    [];

                [_ | Xs] ->
                    drop(Xs, N - 1)
            end
    end.

-file("src/gleam/list.gleam", 564).
-spec do_take(list(ADD), integer(), list(ADD)) -> list(ADD).
do_take(List, N, Acc) ->
    case N =< 0 of
        true ->
            reverse(Acc);

        false ->
            case List of
                [] ->
                    reverse(Acc);

                [X | Xs] ->
                    do_take(Xs, N - 1, [X | Acc])
            end
    end.

-file("src/gleam/list.gleam", 595).
?DOC(
    " Returns a list containing the first given number of elements from the given\n"
    " list.\n"
    "\n"
    " If the element has less than the number of elements then the full list is\n"
    " returned.\n"
    "\n"
    " This function runs in linear time but does not copy the list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " take([1, 2, 3, 4], 2)\n"
    " // -> [1, 2]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " take([1, 2, 3, 4], 9)\n"
    " // -> [1, 2, 3, 4]\n"
    " ```\n"
).
-spec take(list(ADH), integer()) -> list(ADH).
take(List, N) ->
    do_take(List, N, []).

-file("src/gleam/list.gleam", 608).
?DOC(
    " Returns a new empty list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new()\n"
    " // -> []\n"
    " ```\n"
).
-spec new() -> list(any()).
new() ->
    [].

-file("src/gleam/list.gleam", 624).
?DOC(
    " Joins one list onto the end of another.\n"
    "\n"
    " This function runs in linear time, and it traverses and copies the first\n"
    " list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " append([1, 2], [3])\n"
    " // -> [1, 2, 3]\n"
    " ```\n"
).
-spec append(list(ADM), list(ADM)) -> list(ADM).
append(First, Second) ->
    lists:append(First, Second).

-file("src/gleam/list.gleam", 658).
?DOC(
    " Prefixes an item to a list. This can also be done using the dedicated\n"
    " syntax instead\n"
    "\n"
    " ```gleam\n"
    " let existing_list = [2, 3, 4]\n"
    "\n"
    " [1, ..existing_list]\n"
    " // -> [1, 2, 3, 4]\n"
    "\n"
    " prepend(to: existing_list, this: 1)\n"
    " // -> [1, 2, 3, 4]\n"
    " ```\n"
).
-spec prepend(list(ADU), ADU) -> list(ADU).
prepend(List, Item) ->
    [Item | List].

-file("src/gleam/list.gleam", 663).
-spec reverse_and_prepend(list(ADX), list(ADX)) -> list(ADX).
reverse_and_prepend(Prefix, Suffix) ->
    case Prefix of
        [] ->
            Suffix;

        [First | Rest] ->
            reverse_and_prepend(Rest, [First | Suffix])
    end.

-file("src/gleam/list.gleam", 670).
-spec do_concat(list(list(AEB)), list(AEB)) -> list(AEB).
do_concat(Lists, Acc) ->
    case Lists of
        [] ->
            reverse(Acc);

        [List | Further_lists] ->
            do_concat(Further_lists, reverse_and_prepend(List, Acc))
    end.

-file("src/gleam/list.gleam", 689).
?DOC(
    " Joins a list of lists into a single list.\n"
    "\n"
    " This function traverses all elements twice.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " concat([[1], [2, 3], []])\n"
    " // -> [1, 2, 3]\n"
    " ```\n"
).
-spec concat(list(list(AEG))) -> list(AEG).
concat(Lists) ->
    do_concat(Lists, []).

-file("src/gleam/list.gleam", 705).
?DOC(
    " This is the same as `concat`: it joins a list of lists into a single\n"
    " list.\n"
    "\n"
    " This function traverses all elements twice.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " flatten([[1], [2, 3], []])\n"
    " // -> [1, 2, 3]\n"
    " ```\n"
).
-spec flatten(list(list(AEK))) -> list(AEK).
flatten(Lists) ->
    do_concat(Lists, []).

-file("src/gleam/list.gleam", 718).
?DOC(
    " Maps the list with the given function into a list of lists, and then flattens it.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " flat_map([2, 4, 6], fn(x) { [x, x + 1] })\n"
    " // -> [2, 3, 4, 5, 6, 7]\n"
    " ```\n"
).
-spec flat_map(list(AEO), fun((AEO) -> list(AEQ))) -> list(AEQ).
flat_map(List, Fun) ->
    _pipe = map(List, Fun),
    concat(_pipe).

-file("src/gleam/list.gleam", 731).
?DOC(
    " Reduces a list of elements into a single value by calling a given function\n"
    " on each element, going from left to right.\n"
    "\n"
    " `fold([1, 2, 3], 0, add)` is the equivalent of\n"
    " `add(add(add(0, 1), 2), 3)`.\n"
    "\n"
    " This function runs in linear time.\n"
).
-spec fold(list(AET), AEV, fun((AEV, AET) -> AEV)) -> AEV.
fold(List, Initial, Fun) ->
    case List of
        [] ->
            Initial;

        [X | Rest] ->
            fold(Rest, Fun(Initial, X), Fun)
    end.

-file("src/gleam/list.gleam", 292).
?DOC(
    " Takes a list and groups the values by a key\n"
    " which is built from a key function.\n"
    "\n"
    " Does not preserve the initial value order.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " import gleam/dict\n"
    "\n"
    " [Ok(3), Error(\"Wrong\"), Ok(200), Ok(73)]\n"
    " |> group(by: fn(i) {\n"
    "   case i {\n"
    "     Ok(_) -> \"Successful\"\n"
    "     Error(_) -> \"Failed\"\n"
    "   }\n"
    " })\n"
    " |> dict.to_list\n"
    " // -> [\n"
    " //   #(\"Failed\", [Error(\"Wrong\")]),\n"
    " //   #(\"Successful\", [Ok(73), Ok(200), Ok(3)])\n"
    " // ]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " import gleam/dict\n"
    " group([1,2,3,4,5], by: fn(i) { i - i / 3 * 3 })\n"
    " |> dict.to_list\n"
    " // -> [#(0, [3]), #(1, [4, 1]), #(2, [5, 2])]\n"
    " ```\n"
).
-spec group(list(YV), fun((YV) -> YX)) -> gleam@dict:dict(YX, list(YV)).
group(List, Key) ->
    fold(List, gleam@dict:new(), update_group(Key)).

-file("src/gleam/list.gleam", 434).
?DOC(
    " Similar to `map` but also lets you pass around an accumulated value.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " map_fold(\n"
    "   over: [1, 2, 3],\n"
    "   from: 100,\n"
    "   with: fn(memo, i) { #(memo + i, i * 2) }\n"
    " )\n"
    " // -> #(106, [2, 4, 6])\n"
    " ```\n"
).
-spec map_fold(list(ABT), ABV, fun((ABV, ABT) -> {ABV, ABW})) -> {ABV,
    list(ABW)}.
map_fold(List, Acc, Fun) ->
    _pipe = fold(
        List,
        {Acc, []},
        fun(Acc@1, Item) ->
            {Current_acc, Items} = Acc@1,
            {Next_acc, Next_item} = Fun(Current_acc, Item),
            {Next_acc, [Next_item | Items]}
        end
    ),
    gleam@pair:map_second(_pipe, fun reverse/1).

-file("src/gleam/list.gleam", 753).
?DOC(
    " Reduces a list of elements into a single value by calling a given function\n"
    " on each element, going from right to left.\n"
    "\n"
    " `fold_right([1, 2, 3], 0, add)` is the equivalent of\n"
    " `add(add(add(0, 3), 2), 1)`.\n"
    "\n"
    " This function runs in linear time.\n"
    "\n"
    " Unlike `fold` this function is not tail recursive. Where possible use\n"
    " `fold` instead as it will use less memory.\n"
).
-spec fold_right(list(AEW), AEY, fun((AEY, AEW) -> AEY)) -> AEY.
fold_right(List, Initial, Fun) ->
    case List of
        [] ->
            Initial;

        [X | Rest] ->
            Fun(fold_right(Rest, Initial, Fun), X)
    end.

-file("src/gleam/list.gleam", 764).
-spec do_index_fold(
    list(AEZ),
    AFB,
    fun((AFB, AEZ, integer()) -> AFB),
    integer()
) -> AFB.
do_index_fold(Over, Acc, With, Index) ->
    case Over of
        [] ->
            Acc;

        [First | Rest] ->
            do_index_fold(Rest, With(Acc, First, Index), With, Index + 1)
    end.

-file("src/gleam/list.gleam", 786).
?DOC(
    " Like fold but the folding function also receives the index of the current element.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " [\"a\", \"b\", \"c\"]\n"
    " |> index_fold([], fn(acc, item, index) { ... })\n"
    " ```\n"
).
-spec index_fold(list(AFC), AFE, fun((AFE, AFC, integer()) -> AFE)) -> AFE.
index_fold(Over, Initial, Fun) ->
    do_index_fold(Over, Initial, Fun, 0).

-file("src/gleam/list.gleam", 813).
?DOC(
    " A variant of fold that might fail.\n"
    "\n"
    " The folding function should return `Result(accumulator, error)`.\n"
    " If the returned value is `Ok(accumulator)` try_fold will try the next value in the list.\n"
    " If the returned value is `Error(error)` try_fold will stop and return that error.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " [1, 2, 3, 4]\n"
    " |> try_fold(0, fn(acc, i) {\n"
    "   case i < 3 {\n"
    "     True -> Ok(acc + i)\n"
    "     False -> Error(Nil)\n"
    "   }\n"
    " })\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec try_fold(list(AFF), AFH, fun((AFH, AFF) -> {ok, AFH} | {error, AFI})) -> {ok,
        AFH} |
    {error, AFI}.
try_fold(Collection, Accumulator, Fun) ->
    case Collection of
        [] ->
            {ok, Accumulator};

        [First | Rest] ->
            case Fun(Accumulator, First) of
                {ok, Result} ->
                    try_fold(Rest, Result, Fun);

                {error, _} = Error ->
                    Error
            end
    end.

-file("src/gleam/list.gleam", 852).
?DOC(
    " A variant of fold that allows to stop folding earlier.\n"
    "\n"
    " The folding function should return `ContinueOrStop(accumulator)`.\n"
    " If the returned value is `Continue(accumulator)` fold_until will try the next value in the list.\n"
    " If the returned value is `Stop(accumulator)` fold_until will stop and return that accumulator.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " [1, 2, 3, 4]\n"
    " |> fold_until(0, fn(acc, i) {\n"
    "   case i < 3 {\n"
    "     True -> Continue(acc + i)\n"
    "     False -> Stop(acc)\n"
    "   }\n"
    " })\n"
    " // -> 6\n"
    " ```\n"
).
-spec fold_until(list(AFN), AFP, fun((AFP, AFN) -> continue_or_stop(AFP))) -> AFP.
fold_until(Collection, Accumulator, Fun) ->
    case Collection of
        [] ->
            Accumulator;

        [First | Rest] ->
            case Fun(Accumulator, First) of
                {continue, Next_accumulator} ->
                    fold_until(Rest, Next_accumulator, Fun);

                {stop, B} ->
                    B
            end
    end.

-file("src/gleam/list.gleam", 889).
?DOC(
    " Finds the first element in a given list for which the given function returns\n"
    " `True`.\n"
    "\n"
    " Returns `Error(Nil)` if no such element is found.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " find([1, 2, 3], fn(x) { x > 2 })\n"
    " // -> Ok(3)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " find([1, 2, 3], fn(x) { x > 4 })\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " find([], fn(_) { True })\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec find(list(AFR), fun((AFR) -> boolean())) -> {ok, AFR} | {error, nil}.
find(Haystack, Is_desired) ->
    case Haystack of
        [] ->
            {error, nil};

        [X | Rest] ->
            case Is_desired(X) of
                true ->
                    {ok, X};

                _ ->
                    find(Rest, Is_desired)
            end
    end.

-file("src/gleam/list.gleam", 925).
?DOC(
    " Finds the first element in a given list for which the given function returns\n"
    " `Ok(new_value)`, then returns the wrapped `new_value`.\n"
    "\n"
    " Returns `Error(Nil)` if no such element is found.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " find_map([[], [2], [3]], first)\n"
    " // -> Ok(2)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " find_map([[], []], first)\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " find_map([], first)\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec find_map(list(AFV), fun((AFV) -> {ok, AFX} | {error, any()})) -> {ok, AFX} |
    {error, nil}.
find_map(Haystack, Fun) ->
    case Haystack of
        [] ->
            {error, nil};

        [X | Rest] ->
            case Fun(X) of
                {ok, X@1} ->
                    {ok, X@1};

                _ ->
                    find_map(Rest, Fun)
            end
    end.

-file("src/gleam/list.gleam", 960).
?DOC(
    " Returns `True` if the given function returns `True` for all the elements in\n"
    " the given list. If the function returns `False` for any of the elements it\n"
    " immediately returns `False` without checking the rest of the list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " all([], fn(x) { x > 3 })\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " all([4, 5], fn(x) { x > 3 })\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " all([4, 3], fn(x) { x > 3 })\n"
    " // -> False\n"
    " ```\n"
).
-spec all(list(AGD), fun((AGD) -> boolean())) -> boolean().
all(List, Predicate) ->
    case List of
        [] ->
            true;

        [First | Rest] ->
            case Predicate(First) of
                true ->
                    all(Rest, Predicate);

                false ->
                    false
            end
    end.

-file("src/gleam/list.gleam", 997).
?DOC(
    " Returns `True` if the given function returns `True` for any the elements in\n"
    " the given list. If the function returns `True` for any of the elements it\n"
    " immediately returns `True` without checking the rest of the list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " any([], fn(x) { x > 3 })\n"
    " // -> False\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " any([4, 5], fn(x) { x > 3 })\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " any([4, 3], fn(x) { x > 4 })\n"
    " // -> False\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " any([3, 4], fn(x) { x > 3 })\n"
    " // -> True\n"
    " ```\n"
).
-spec any(list(AGF), fun((AGF) -> boolean())) -> boolean().
any(List, Predicate) ->
    case List of
        [] ->
            false;

        [First | Rest] ->
            case Predicate(First) of
                true ->
                    true;

                false ->
                    any(Rest, Predicate)
            end
    end.

-file("src/gleam/list.gleam", 1008).
-spec do_zip(list(AGH), list(AGJ), list({AGH, AGJ})) -> list({AGH, AGJ}).
do_zip(Xs, Ys, Acc) ->
    case {Xs, Ys} of
        {[X | Xs@1], [Y | Ys@1]} ->
            do_zip(Xs@1, Ys@1, [{X, Y} | Acc]);

        {_, _} ->
            reverse(Acc)
    end.

-file("src/gleam/list.gleam", 1042).
?DOC(
    " Takes two lists and returns a single list of 2-element tuples.\n"
    "\n"
    " If one of the lists is longer than the other, the remaining elements from\n"
    " the longer list are not used.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " zip([], [])\n"
    " // -> []\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " zip([1, 2], [3])\n"
    " // -> [#(1, 3)]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " zip([1], [3, 4])\n"
    " // -> [#(1, 3)]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " zip([1, 2], [3, 4])\n"
    " // -> [#(1, 3), #(2, 4)]\n"
    " ```\n"
).
-spec zip(list(AGN), list(AGP)) -> list({AGN, AGP}).
zip(List, Other) ->
    do_zip(List, Other, []).

-file("src/gleam/list.gleam", 1072).
?DOC(
    " Takes two lists and returns a single list of 2-element tuples.\n"
    "\n"
    " If one of the lists is longer than the other, an `Error` is returned.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " strict_zip([], [])\n"
    " // -> Ok([])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " strict_zip([1, 2], [3])\n"
    " // -> Error(LengthMismatch)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " strict_zip([1], [3, 4])\n"
    " // -> Error(LengthMismatch)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " strict_zip([1, 2], [3, 4])\n"
    " // -> Ok([#(1, 3), #(2, 4)])\n"
    " ```\n"
).
-spec strict_zip(list(AGS), list(AGU)) -> {ok, list({AGS, AGU})} |
    {error, length_mismatch()}.
strict_zip(List, Other) ->
    case length(List) =:= length(Other) of
        true ->
            {ok, zip(List, Other)};

        false ->
            {error, length_mismatch}
    end.

-file("src/gleam/list.gleam", 1082).
-spec do_unzip(list({AWM, AWN}), list(AWM), list(AWN)) -> {list(AWM), list(AWN)}.
do_unzip(Input, Xs, Ys) ->
    case Input of
        [] ->
            {reverse(Xs), reverse(Ys)};

        [{X, Y} | Rest] ->
            do_unzip(Rest, [X | Xs], [Y | Ys])
    end.

-file("src/gleam/list.gleam", 1103).
?DOC(
    " Takes a single list of 2-element tuples and returns two lists.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " unzip([#(1, 2), #(3, 4)])\n"
    " // -> #([1, 3], [2, 4])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " unzip([])\n"
    " // -> #([], [])\n"
    " ```\n"
).
-spec unzip(list({AHD, AHE})) -> {list(AHD), list(AHE)}.
unzip(Input) ->
    do_unzip(Input, [], []).

-file("src/gleam/list.gleam", 1107).
-spec do_intersperse(list(AHI), AHI, list(AHI)) -> list(AHI).
do_intersperse(List, Separator, Acc) ->
    case List of
        [] ->
            reverse(Acc);

        [X | Rest] ->
            do_intersperse(Rest, Separator, [X, Separator | Acc])
    end.

-file("src/gleam/list.gleam", 1130).
?DOC(
    " Inserts a given value between each existing element in a given list.\n"
    "\n"
    " This function runs in linear time and copies the list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " intersperse([1, 1, 1], 2)\n"
    " // -> [1, 2, 1, 2, 1]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " intersperse([], 2)\n"
    " // -> []\n"
    " ```\n"
).
-spec intersperse(list(AHM), AHM) -> list(AHM).
intersperse(List, Elem) ->
    case List of
        [] ->
            List;

        [_] ->
            List;

        [X | Rest] ->
            do_intersperse(Rest, Elem, [X])
    end.

-file("src/gleam/list.gleam", 1155).
?DOC(
    " Returns the element in the Nth position in the list, with 0 being the first\n"
    " position.\n"
    "\n"
    " `Error(Nil)` is returned if the list is not long enough for the given index\n"
    " or if the index is less than 0.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " at([1, 2, 3], 1)\n"
    " // -> Ok(2)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " at([1, 2, 3], 5)\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec at(list(AHP), integer()) -> {ok, AHP} | {error, nil}.
at(List, Index) ->
    case Index >= 0 of
        true ->
            _pipe = List,
            _pipe@1 = drop(_pipe, Index),
            first(_pipe@1);

        false ->
            {error, nil}
    end.

-file("src/gleam/list.gleam", 1176).
?DOC(
    " Removes any duplicate elements from a given list.\n"
    "\n"
    " This function returns in loglinear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " unique([1, 1, 1, 4, 7, 3, 3, 4])\n"
    " // -> [1, 4, 7, 3]\n"
    " ```\n"
).
-spec unique(list(AHT)) -> list(AHT).
unique(List) ->
    case List of
        [] ->
            [];

        [X | Rest] ->
            [X | unique(filter(Rest, fun(Y) -> Y /= X end))]
    end.

-file("src/gleam/list.gleam", 1186).
?DOC(
    " Merge lists `a` and `b` in ascending order\n"
    " but only up to `na` and `nb` number of items respectively.\n"
).
-spec merge_up(
    integer(),
    integer(),
    list(AHW),
    list(AHW),
    list(AHW),
    fun((AHW, AHW) -> gleam@order:order())
) -> list(AHW).
merge_up(Na, Nb, A, B, Acc, Compare) ->
    case {Na, Nb, A, B} of
        {0, 0, _, _} ->
            Acc;

        {_, 0, [Ax | Ar], _} ->
            merge_up(Na - 1, Nb, Ar, B, [Ax | Acc], Compare);

        {0, _, _, [Bx | Br]} ->
            merge_up(Na, Nb - 1, A, Br, [Bx | Acc], Compare);

        {_, _, [Ax@1 | Ar@1], [Bx@1 | Br@1]} ->
            case Compare(Ax@1, Bx@1) of
                gt ->
                    merge_up(Na, Nb - 1, A, Br@1, [Bx@1 | Acc], Compare);

                _ ->
                    merge_up(Na - 1, Nb, Ar@1, B, [Ax@1 | Acc], Compare)
            end;

        {_, _, _, _} ->
            Acc
    end.

-file("src/gleam/list.gleam", 1210).
?DOC(
    " Merge lists `a` and `b` in descending order\n"
    " but only up to `na` and `nb` number of items respectively.\n"
).
-spec merge_down(
    integer(),
    integer(),
    list(AIB),
    list(AIB),
    list(AIB),
    fun((AIB, AIB) -> gleam@order:order())
) -> list(AIB).
merge_down(Na, Nb, A, B, Acc, Compare) ->
    case {Na, Nb, A, B} of
        {0, 0, _, _} ->
            Acc;

        {_, 0, [Ax | Ar], _} ->
            merge_down(Na - 1, Nb, Ar, B, [Ax | Acc], Compare);

        {0, _, _, [Bx | Br]} ->
            merge_down(Na, Nb - 1, A, Br, [Bx | Acc], Compare);

        {_, _, [Ax@1 | Ar@1], [Bx@1 | Br@1]} ->
            case Compare(Bx@1, Ax@1) of
                lt ->
                    merge_down(Na - 1, Nb, Ar@1, B, [Ax@1 | Acc], Compare);

                _ ->
                    merge_down(Na, Nb - 1, A, Br@1, [Bx@1 | Acc], Compare)
            end;

        {_, _, _, _} ->
            Acc
    end.

-file("src/gleam/list.gleam", 1237).
?DOC(
    " Merge sort that alternates merging in ascending and descending order\n"
    " because the merge process also reverses the list.\n"
    "\n"
    " Some copying is avoided by merging only a subset of the lists\n"
    " instead of creating and merging new smaller lists.\n"
).
-spec merge_sort(
    list(AIG),
    integer(),
    fun((AIG, AIG) -> gleam@order:order()),
    boolean()
) -> list(AIG).
merge_sort(L, Ln, Compare, Down) ->
    N = Ln div 2,
    A = L,
    B = drop(L, N),
    case Ln < 3 of
        true ->
            case Down of
                true ->
                    merge_down(N, Ln - N, A, B, [], Compare);

                false ->
                    merge_up(N, Ln - N, A, B, [], Compare)
            end;

        false ->
            case Down of
                true ->
                    merge_down(
                        N,
                        Ln - N,
                        merge_sort(A, N, Compare, false),
                        merge_sort(B, Ln - N, Compare, false),
                        [],
                        Compare
                    );

                false ->
                    merge_up(
                        N,
                        Ln - N,
                        merge_sort(A, N, Compare, true),
                        merge_sort(B, Ln - N, Compare, true),
                        [],
                        Compare
                    )
            end
    end.

-file("src/gleam/list.gleam", 1287).
?DOC(
    " Sorts from smallest to largest based upon the ordering specified by a given\n"
    " function.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " import gleam/int\n"
    " sort([4, 3, 6, 5, 4, 1, 2], by: int.compare)\n"
    " // -> [1, 2, 3, 4, 4, 5, 6]\n"
    " ```\n"
).
-spec sort(list(AIJ), fun((AIJ, AIJ) -> gleam@order:order())) -> list(AIJ).
sort(List, Compare) ->
    merge_sort(List, length(List), Compare, true).

-file("src/gleam/list.gleam", 1314).
-spec tail_recursive_range(integer(), integer(), list(integer())) -> list(integer()).
tail_recursive_range(Start, Stop, Acc) ->
    case gleam@int:compare(Start, Stop) of
        eq ->
            [Stop | Acc];

        gt ->
            tail_recursive_range(Start, Stop + 1, [Stop | Acc]);

        lt ->
            tail_recursive_range(Start, Stop - 1, [Stop | Acc])
    end.

-file("src/gleam/list.gleam", 1310).
?DOC(
    " Creates a list of ints ranging from a given start and finish.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " range(0, 0)\n"
    " // -> [0]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " range(0, 5)\n"
    " // -> [0, 1, 2, 3, 4, 5]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " range(1, -5)\n"
    " // -> [1, 0, -1, -2, -3, -4, -5]\n"
    " ```\n"
).
-spec range(integer(), integer()) -> list(integer()).
range(Start, Stop) ->
    tail_recursive_range(Start, Stop, []).

-file("src/gleam/list.gleam", 1322).
-spec do_repeat(AIP, integer(), list(AIP)) -> list(AIP).
do_repeat(A, Times, Acc) ->
    case Times =< 0 of
        true ->
            Acc;

        false ->
            do_repeat(A, Times - 1, [A | Acc])
    end.

-file("src/gleam/list.gleam", 1343).
?DOC(
    " Builds a list of a given value a given number of times.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " repeat(\"a\", times: 0)\n"
    " // -> []\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " repeat(\"a\", times: 5)\n"
    " // -> [\"a\", \"a\", \"a\", \"a\", \"a\"]\n"
    " ```\n"
).
-spec repeat(AIS, integer()) -> list(AIS).
repeat(A, Times) ->
    do_repeat(A, Times, []).

-file("src/gleam/list.gleam", 1347).
-spec do_split(list(AIU), integer(), list(AIU)) -> {list(AIU), list(AIU)}.
do_split(List, N, Taken) ->
    case N =< 0 of
        true ->
            {reverse(Taken), List};

        false ->
            case List of
                [] ->
                    {reverse(Taken), []};

                [X | Xs] ->
                    do_split(Xs, N - 1, [X | Taken])
            end
    end.

-file("src/gleam/list.gleam", 1380).
?DOC(
    " Splits a list in two before the given index.\n"
    "\n"
    " If the list is not long enough to have the given index the before list will\n"
    " be the input list, and the after list will be empty.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " split([6, 7, 8, 9], 0)\n"
    " // -> #([], [6, 7, 8, 9])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " split([6, 7, 8, 9], 2)\n"
    " // -> #([6, 7], [8, 9])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " split([6, 7, 8, 9], 4)\n"
    " // -> #([6, 7, 8, 9], [])\n"
    " ```\n"
).
-spec split(list(AIZ), integer()) -> {list(AIZ), list(AIZ)}.
split(List, Index) ->
    do_split(List, Index, []).

-file("src/gleam/list.gleam", 1384).
-spec do_split_while(list(AJD), fun((AJD) -> boolean()), list(AJD)) -> {list(AJD),
    list(AJD)}.
do_split_while(List, F, Acc) ->
    case List of
        [] ->
            {reverse(Acc), []};

        [X | Xs] ->
            case F(X) of
                false ->
                    {reverse(Acc), List};

                _ ->
                    do_split_while(Xs, F, [X | Acc])
            end
    end.

-file("src/gleam/list.gleam", 1417).
?DOC(
    " Splits a list in two before the first element that a given function returns\n"
    " `False` for.\n"
    "\n"
    " If the function returns `True` for all elements the first list will be the\n"
    " input list, and the second list will be empty.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " split_while([1, 2, 3, 4, 5], fn(x) { x <= 3 })\n"
    " // -> #([1, 2, 3], [4, 5])\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " split_while([1, 2, 3, 4, 5], fn(x) { x <= 5 })\n"
    " // -> #([1, 2, 3, 4, 5], [])\n"
    " ```\n"
).
-spec split_while(list(AJI), fun((AJI) -> boolean())) -> {list(AJI), list(AJI)}.
split_while(List, Predicate) ->
    do_split_while(List, Predicate, []).

-file("src/gleam/list.gleam", 1449).
?DOC(
    " Given a list of 2-element tuples, finds the first tuple that has a given\n"
    " key as the first element and returns the second element.\n"
    "\n"
    " If no tuple is found with the given key then `Error(Nil)` is returned.\n"
    "\n"
    " This function may be useful for interacting with Erlang code where lists of\n"
    " tuples are common.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " key_find([#(\"a\", 0), #(\"b\", 1)], \"a\")\n"
    " // -> Ok(0)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " key_find([#(\"a\", 0), #(\"b\", 1)], \"b\")\n"
    " // -> Ok(1)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " key_find([#(\"a\", 0), #(\"b\", 1)], \"c\")\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec key_find(list({AJM, AJN}), AJM) -> {ok, AJN} | {error, nil}.
key_find(Keyword_list, Desired_key) ->
    find_map(
        Keyword_list,
        fun(Keyword) ->
            {Key, Value} = Keyword,
            case Key =:= Desired_key of
                true ->
                    {ok, Value};

                false ->
                    {error, nil}
            end
        end
    ).

-file("src/gleam/list.gleam", 1480).
?DOC(
    " Given a list of 2-element tuples, finds all tuples that have a given\n"
    " key as the first element and returns the second element.\n"
    "\n"
    " This function may be useful for interacting with Erlang code where lists of\n"
    " tuples are common.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " key_filter([#(\"a\", 0), #(\"b\", 1), #(\"a\", 2)], \"a\")\n"
    " // -> [0, 2]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " key_filter([#(\"a\", 0), #(\"b\", 1)], \"c\")\n"
    " // -> []\n"
    " ```\n"
).
-spec key_filter(list({AJR, AJS}), AJR) -> list(AJS).
key_filter(Keyword_list, Desired_key) ->
    filter_map(
        Keyword_list,
        fun(Keyword) ->
            {Key, Value} = Keyword,
            case Key =:= Desired_key of
                true ->
                    {ok, Value};

                false ->
                    {error, nil}
            end
        end
    ).

-file("src/gleam/list.gleam", 1493).
-spec do_pop(list(BAF), fun((BAF) -> boolean()), list(BAF)) -> {ok,
        {BAF, list(BAF)}} |
    {error, nil}.
do_pop(Haystack, Predicate, Checked) ->
    case Haystack of
        [] ->
            {error, nil};

        [X | Rest] ->
            case Predicate(X) of
                true ->
                    {ok, {X, append(reverse(Checked), Rest)}};

                false ->
                    do_pop(Rest, Predicate, [X | Checked])
            end
    end.

-file("src/gleam/list.gleam", 1525).
?DOC(
    " Removes the first element in a given list for which the predicate function returns `True`.\n"
    "\n"
    " Returns `Error(Nil)` if no such element is found.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " pop([1, 2, 3], fn(x) { x > 2 })\n"
    " // -> Ok(#(3, [1, 2]))\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " pop([1, 2, 3], fn(x) { x > 4 })\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " pop([], fn(_) { True })\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec pop(list(AJZ), fun((AJZ) -> boolean())) -> {ok, {AJZ, list(AJZ)}} |
    {error, nil}.
pop(Haystack, Is_desired) ->
    do_pop(Haystack, Is_desired, []).

-file("src/gleam/list.gleam", 1532).
-spec do_pop_map(list(BAT), fun((BAT) -> {ok, BBG} | {error, any()}), list(BAT)) -> {ok,
        {BBG, list(BAT)}} |
    {error, nil}.
do_pop_map(Haystack, Mapper, Checked) ->
    case Haystack of
        [] ->
            {error, nil};

        [X | Rest] ->
            case Mapper(X) of
                {ok, Y} ->
                    {ok, {Y, append(reverse(Checked), Rest)}};

                {error, _} ->
                    do_pop_map(Rest, Mapper, [X | Checked])
            end
    end.

-file("src/gleam/list.gleam", 1565).
?DOC(
    " Removes the first element in a given list for which the given function returns\n"
    " `Ok(new_value)`, then returns the wrapped `new_value` as well as list with the value removed.\n"
    "\n"
    " Returns `Error(Nil)` if no such element is found.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " pop_map([[], [2], [3]], first)\n"
    " // -> Ok(#(2, [[], [3]]))\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " pop_map([[], []], first)\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " pop_map([], first)\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec pop_map(list(AKI), fun((AKI) -> {ok, AKK} | {error, any()})) -> {ok,
        {AKK, list(AKI)}} |
    {error, nil}.
pop_map(Haystack, Is_desired) ->
    do_pop_map(Haystack, Is_desired, []).

-file("src/gleam/list.gleam", 1595).
?DOC(
    " Given a list of 2-element tuples, finds the first tuple that has a given\n"
    " key as the first element. This function will return the second element\n"
    " of the found tuple and list with tuple removed.\n"
    "\n"
    " If no tuple is found with the given key then `Error(Nil)` is returned.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " key_pop([#(\"a\", 0), #(\"b\", 1)], \"a\")\n"
    " // -> Ok(#(0, [#(\"b\", 1)]))\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " key_pop([#(\"a\", 0), #(\"b\", 1)], \"b\")\n"
    " // -> Ok(#(1, [#(\"a\", 0)]))\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " key_pop([#(\"a\", 0), #(\"b\", 1)], \"c\")\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec key_pop(list({AKR, AKS}), AKR) -> {ok, {AKS, list({AKR, AKS})}} |
    {error, nil}.
key_pop(Haystack, Key) ->
    pop_map(
        Haystack,
        fun(Entry) ->
            {K, V} = Entry,
            case K of
                K@1 when K@1 =:= Key ->
                    {ok, V};

                _ ->
                    {error, nil}
            end
        end
    ).

-file("src/gleam/list.gleam", 1625).
?DOC(
    " Given a list of 2-element tuples, inserts a key and value into the list.\n"
    "\n"
    " If there was already a tuple with the key then it is replaced, otherwise it\n"
    " is added to the end of the list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " key_set([#(5, 0), #(4, 1)], 4, 100)\n"
    " // -> [#(5, 0), #(4, 100)]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " key_set([#(5, 0), #(4, 1)], 1, 100)\n"
    " // -> [#(5, 0), #(4, 1), #(1, 100)]\n"
    " ```\n"
).
-spec key_set(list({AKX, AKY}), AKX, AKY) -> list({AKX, AKY}).
key_set(List, Key, Value) ->
    case List of
        [] ->
            [{Key, Value}];

        [{K, _} | Rest] when K =:= Key ->
            [{Key, Value} | Rest];

        [First | Rest@1] ->
            [First | key_set(Rest@1, Key, Value)]
    end.

-file("src/gleam/list.gleam", 1646).
?DOC(
    " Calls a function for each element in a list, discarding the return value.\n"
    "\n"
    " Useful for calling a side effect for every item of a list.\n"
    "\n"
    " ```gleam\n"
    " import gleam/io\n"
    " each([\"1\", \"2\", \"3\"], io.println)\n"
    " // -> Nil\n"
    " // 1\n"
    " // 2\n"
    " // 3\n"
    " ```\n"
).
-spec each(list(ALB), fun((ALB) -> any())) -> nil.
each(List, F) ->
    case List of
        [] ->
            nil;

        [X | Xs] ->
            F(X),
            each(Xs, F)
    end.

-file("src/gleam/list.gleam", 1672).
?DOC(
    " Calls a `Result` returning function for each element in a list, discarding\n"
    " the return value. If the function returns `Error` then the iteration is\n"
    " stopped and the error is returned.\n"
    "\n"
    " Useful for calling a side effect for every item of a list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " try_each(\n"
    "   over: [1, 2, 3],\n"
    "   with: function_that_might_fail,\n"
    " )\n"
    " // -> Ok(Nil)\n"
    " ```\n"
).
-spec try_each(list(ALE), fun((ALE) -> {ok, any()} | {error, ALH})) -> {ok, nil} |
    {error, ALH}.
try_each(List, Fun) ->
    case List of
        [] ->
            {ok, nil};

        [X | Xs] ->
            case Fun(X) of
                {ok, _} ->
                    try_each(Xs, Fun);

                {error, E} ->
                    {error, E}
            end
    end.

-file("src/gleam/list.gleam", 1686).
-spec do_partition(list(BCN), fun((BCN) -> boolean()), list(BCN), list(BCN)) -> {list(BCN),
    list(BCN)}.
do_partition(List, Categorise, Trues, Falses) ->
    case List of
        [] ->
            {reverse(Trues), reverse(Falses)};

        [X | Xs] ->
            case Categorise(X) of
                true ->
                    do_partition(Xs, Categorise, [X | Trues], Falses);

                false ->
                    do_partition(Xs, Categorise, Trues, [X | Falses])
            end
    end.

-file("src/gleam/list.gleam", 1708).
?DOC(
    " Partitions a list into a tuple/pair of lists\n"
    " by a given categorisation function.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " import gleam/int\n"
    " [1, 2, 3, 4, 5] |> partition(int.is_odd)\n"
    " // -> #([1, 3, 5], [2, 4])\n"
    " ```\n"
).
-spec partition(list(ALR), fun((ALR) -> boolean())) -> {list(ALR), list(ALR)}.
partition(List, Categorise) ->
    do_partition(List, Categorise, [], []).

-file("src/gleam/list.gleam", 1724).
?DOC(
    " Returns all the permutations of a list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " permutations([1, 2])\n"
    " // -> [[1, 2], [2, 1]]\n"
    " ```\n"
).
-spec permutations(list(ALV)) -> list(list(ALV)).
permutations(L) ->
    case L of
        [] ->
            [[]];

        _ ->
            _pipe = L,
            _pipe@5 = index_map(_pipe, fun(I, I_idx) -> _pipe@1 = L,
                    _pipe@2 = index_fold(
                        _pipe@1,
                        [],
                        fun(Acc, J, J_idx) -> case I_idx =:= J_idx of
                                true ->
                                    Acc;

                                false ->
                                    [J | Acc]
                            end end
                    ),
                    _pipe@3 = reverse(_pipe@2),
                    _pipe@4 = permutations(_pipe@3),
                    map(_pipe@4, fun(Permutation) -> [I | Permutation] end) end),
            concat(_pipe@5)
    end.

-file("src/gleam/list.gleam", 1745).
-spec do_window(list(list(ALZ)), list(ALZ), integer()) -> list(list(ALZ)).
do_window(Acc, L, N) ->
    Window = take(L, N),
    case length(Window) =:= N of
        true ->
            do_window([Window | Acc], drop(L, 1), N);

        false ->
            Acc
    end.

-file("src/gleam/list.gleam", 1768).
?DOC(
    " Returns a list of sliding windows.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " window([1,2,3,4,5], 3)\n"
    " // -> [[1, 2, 3], [2, 3, 4], [3, 4, 5]]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " window([1, 2], 4)\n"
    " // -> []\n"
    " ```\n"
).
-spec window(list(AMF), integer()) -> list(list(AMF)).
window(L, N) ->
    _pipe = do_window([], L, N),
    reverse(_pipe).

-file("src/gleam/list.gleam", 1787).
?DOC(
    " Returns a list of tuples containing two contiguous elements.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " window_by_2([1,2,3,4])\n"
    " // -> [#(1, 2), #(2, 3), #(3, 4)]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " window_by_2([1])\n"
    " // -> []\n"
    " ```\n"
).
-spec window_by_2(list(AMJ)) -> list({AMJ, AMJ}).
window_by_2(L) ->
    zip(L, drop(L, 1)).

-file("src/gleam/list.gleam", 1800).
?DOC(
    " Drops the first elements in a given list for which the predicate function returns `True`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " drop_while([1, 2, 3, 4], fn (x) { x < 3 })\n"
    " // -> [3, 4]\n"
    " ```\n"
).
-spec drop_while(list(AMM), fun((AMM) -> boolean())) -> list(AMM).
drop_while(List, Predicate) ->
    case List of
        [] ->
            [];

        [X | Xs] ->
            case Predicate(X) of
                true ->
                    drop_while(Xs, Predicate);

                false ->
                    [X | Xs]
            end
    end.

-file("src/gleam/list.gleam", 1814).
-spec do_take_while(list(AMP), fun((AMP) -> boolean()), list(AMP)) -> list(AMP).
do_take_while(List, Predicate, Acc) ->
    case List of
        [] ->
            reverse(Acc);

        [First | Rest] ->
            case Predicate(First) of
                true ->
                    do_take_while(Rest, Predicate, [First | Acc]);

                false ->
                    reverse(Acc)
            end
    end.

-file("src/gleam/list.gleam", 1838).
?DOC(
    " Takes the first elements in a given list for which the predicate function returns `True`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " take_while([1, 2, 3, 2, 4], fn (x) { x < 3 })\n"
    " // -> [1, 2]\n"
    " ```\n"
).
-spec take_while(list(AMT), fun((AMT) -> boolean())) -> list(AMT).
take_while(List, Predicate) ->
    do_take_while(List, Predicate, []).

-file("src/gleam/list.gleam", 1845).
-spec do_chunk(list(AMW), fun((AMW) -> AMY), AMY, list(AMW), list(list(AMW))) -> list(list(AMW)).
do_chunk(List, F, Previous_key, Current_chunk, Acc) ->
    case List of
        [First | Rest] ->
            Key = F(First),
            case Key =:= Previous_key of
                false ->
                    New_acc = [reverse(Current_chunk) | Acc],
                    do_chunk(Rest, F, Key, [First], New_acc);

                _ ->
                    do_chunk(Rest, F, Key, [First | Current_chunk], Acc)
            end;

        _ ->
            reverse([reverse(Current_chunk) | Acc])
    end.

-file("src/gleam/list.gleam", 1877).
?DOC(
    " Returns a list of chunks in which\n"
    " the return value of calling `f` on each element is the same.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " [1, 2, 2, 3, 4, 4, 6, 7, 7] |> chunk(by: fn(n) { n % 2 })\n"
    " // -> [[1], [2, 2], [3], [4, 4, 6], [7, 7]]\n"
    " ```\n"
).
-spec chunk(list(ANE), fun((ANE) -> any())) -> list(list(ANE)).
chunk(List, F) ->
    case List of
        [] ->
            [];

        [First | Rest] ->
            do_chunk(Rest, F, F(First), [First], [])
    end.

-file("src/gleam/list.gleam", 1884).
-spec do_sized_chunk(
    list(ANJ),
    integer(),
    integer(),
    list(ANJ),
    list(list(ANJ))
) -> list(list(ANJ)).
do_sized_chunk(List, Count, Left, Current_chunk, Acc) ->
    case List of
        [] ->
            case Current_chunk of
                [] ->
                    reverse(Acc);

                Remaining ->
                    reverse([reverse(Remaining) | Acc])
            end;

        [First | Rest] ->
            Chunk = [First | Current_chunk],
            case Left > 1 of
                false ->
                    do_sized_chunk(
                        Rest,
                        Count,
                        Count,
                        [],
                        [reverse(Chunk) | Acc]
                    );

                true ->
                    do_sized_chunk(Rest, Count, Left - 1, Chunk, Acc)
            end
    end.

-file("src/gleam/list.gleam", 1926).
?DOC(
    " Returns a list of chunks containing `count` elements each.\n"
    "\n"
    " If the last chunk does not have `count` elements, it is instead\n"
    " a partial chunk, with less than `count` elements.\n"
    "\n"
    " For any `count` less than 1 this function behaves as if it was set to 1.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " [1, 2, 3, 4, 5, 6] |> sized_chunk(into: 2)\n"
    " // -> [[1, 2], [3, 4], [5, 6]]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " [1, 2, 3, 4, 5, 6, 7, 8] |> sized_chunk(into: 3)\n"
    " // -> [[1, 2, 3], [4, 5, 6], [7, 8]]\n"
    " ```\n"
).
-spec sized_chunk(list(ANQ), integer()) -> list(list(ANQ)).
sized_chunk(List, Count) ->
    do_sized_chunk(List, Count, Count, [], []).

-file("src/gleam/list.gleam", 1950).
?DOC(
    " This function acts similar to fold, but does not take an initial state.\n"
    " Instead, it starts from the first element in the list\n"
    " and combines it with each subsequent element in turn using the given\n"
    " function. The function is called as `fun(accumulator, current_element)`.\n"
    "\n"
    " Returns `Ok` to indicate a successful run, and `Error` if called on an\n"
    " empty list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " [] |> reduce(fn(acc, x) { acc + x })\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " [1, 2, 3, 4, 5] |> reduce(fn(acc, x) { acc + x })\n"
    " // -> Ok(15)\n"
    " ```\n"
).
-spec reduce(list(ANU), fun((ANU, ANU) -> ANU)) -> {ok, ANU} | {error, nil}.
reduce(List, Fun) ->
    case List of
        [] ->
            {error, nil};

        [First | Rest] ->
            {ok, fold(Rest, First, Fun)}
    end.

-file("src/gleam/list.gleam", 1957).
-spec do_scan(list(ANY), AOA, list(AOA), fun((AOA, ANY) -> AOA)) -> list(AOA).
do_scan(List, Accumulator, Accumulated, Fun) ->
    case List of
        [] ->
            reverse(Accumulated);

        [X | Xs] ->
            Next = Fun(Accumulator, X),
            do_scan(Xs, Next, [Next | Accumulated], Fun)
    end.

-file("src/gleam/list.gleam", 1981).
?DOC(
    " Similar to `fold`, but yields the state of the accumulator at each stage.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " scan(over: [1, 2, 3], from: 100, with: fn(acc, i) { acc + i })\n"
    " // -> [101, 103, 106]\n"
    " ```\n"
).
-spec scan(list(AOD), AOF, fun((AOF, AOD) -> AOF)) -> list(AOF).
scan(List, Initial, Fun) ->
    do_scan(List, Initial, [], Fun).

-file("src/gleam/list.gleam", 2009).
?DOC(
    " Returns the last element in the given list.\n"
    "\n"
    " Returns `Error(Nil)` if the list is empty.\n"
    "\n"
    " This function runs in linear time.\n"
    " For a collection oriented around performant access at either end,\n"
    " see `gleam/queue.Queue`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " last([])\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " last([1, 2, 3, 4, 5])\n"
    " // -> Ok(5)\n"
    " ```\n"
).
-spec last(list(AOH)) -> {ok, AOH} | {error, nil}.
last(List) ->
    _pipe = List,
    reduce(_pipe, fun(_, Elem) -> Elem end).

-file("src/gleam/list.gleam", 2028).
?DOC(
    " Return unique combinations of elements in the list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " combinations([1, 2, 3], 2)\n"
    " // -> [[1, 2], [1, 3], [2, 3]]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " combinations([1, 2, 3, 4], 3)\n"
    " // -> [[1, 2, 3], [1, 2, 4], [1, 3, 4], [2, 3, 4]]\n"
    " ```\n"
).
-spec combinations(list(AOL), integer()) -> list(list(AOL)).
combinations(Items, N) ->
    case N of
        0 ->
            [[]];

        _ ->
            case Items of
                [] ->
                    [];

                [X | Xs] ->
                    First_combinations = begin
                        _pipe = map(
                            combinations(Xs, N - 1),
                            fun(Com) -> [X | Com] end
                        ),
                        reverse(_pipe)
                    end,
                    fold(
                        First_combinations,
                        combinations(Xs, N),
                        fun(Acc, C) -> [C | Acc] end
                    )
            end
    end.

-file("src/gleam/list.gleam", 2046).
-spec do_combination_pairs(list(AOP)) -> list(list({AOP, AOP})).
do_combination_pairs(Items) ->
    case Items of
        [] ->
            [];

        [X | Xs] ->
            First_combinations = map(Xs, fun(Other) -> {X, Other} end),
            [First_combinations | do_combination_pairs(Xs)]
    end.

-file("src/gleam/list.gleam", 2065).
?DOC(
    " Return unique pair combinations of elements in the list\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " combination_pairs([1, 2, 3])\n"
    " // -> [#(1, 2), #(1, 3), #(2, 3)]\n"
    " ```\n"
).
-spec combination_pairs(list(AOT)) -> list({AOT, AOT}).
combination_pairs(Items) ->
    _pipe = do_combination_pairs(Items),
    concat(_pipe).

-file("src/gleam/list.gleam", 2097).
?DOC(
    " Transpose rows and columns of the list of lists.\n"
    "\n"
    " Notice: This function is not tail recursive,\n"
    " and thus may exceed stack size if called,\n"
    " with large lists (on target JavaScript).\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " transpose([[1, 2, 3], [101, 102, 103]])\n"
    " // -> [[1, 101], [2, 102], [3, 103]]\n"
    " ```\n"
).
-spec transpose(list(list(APA))) -> list(list(APA)).
transpose(List_of_list) ->
    Take_first = fun(List) -> case List of
            [] ->
                [];

            [F] ->
                [F];

            [F@1 | _] ->
                [F@1]
        end end,
    case List_of_list of
        [] ->
            [];

        [[] | Xss] ->
            transpose(Xss);

        Rows ->
            Firsts = begin
                _pipe = Rows,
                _pipe@1 = map(_pipe, Take_first),
                concat(_pipe@1)
            end,
            Rest = transpose(map(Rows, fun(_capture) -> drop(_capture, 1) end)),
            [Firsts | Rest]
    end.

-file("src/gleam/list.gleam", 2079).
?DOC(
    " Make a list alternating the elements from the given lists\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " interleave([[1, 2], [101, 102], [201, 202]])\n"
    " // -> [1, 101, 201, 2, 102, 202]\n"
    " ```\n"
).
-spec interleave(list(list(AOW))) -> list(AOW).
interleave(List) ->
    _pipe = transpose(List),
    concat(_pipe).

-file("src/gleam/list.gleam", 2120).
-spec do_shuffle_pair_unwrap(list({float(), APF}), list(APF)) -> list(APF).
do_shuffle_pair_unwrap(List, Acc) ->
    case List of
        [] ->
            Acc;

        [Elem_pair | Enumerable] ->
            do_shuffle_pair_unwrap(
                Enumerable,
                [erlang:element(2, Elem_pair) | Acc]
            )
    end.

-file("src/gleam/list.gleam", 2128).
-spec do_shuffle_by_pair_indexes(list({float(), APJ})) -> list({float(), APJ}).
do_shuffle_by_pair_indexes(List_of_pairs) ->
    sort(
        List_of_pairs,
        fun(A_pair, B_pair) ->
            gleam@float:compare(
                erlang:element(1, A_pair),
                erlang:element(1, B_pair)
            )
        end
    ).

-file("src/gleam/list.gleam", 2147).
?DOC(
    " Takes a list, randomly sorts all items and returns the shuffled list.\n"
    "\n"
    " This function uses `float.random` to decide the order of the elements.\n"
    "\n"
    " ## Example\n"
    "\n"
    " ```gleam\n"
    " range(1, 10) |> shuffle()\n"
    " // -> [1, 6, 9, 10, 3, 8, 4, 2, 7, 5]\n"
    " ```\n"
).
-spec shuffle(list(APM)) -> list(APM).
shuffle(List) ->
    _pipe = List,
    _pipe@1 = fold(_pipe, [], fun(Acc, A) -> [{rand:uniform(), A} | Acc] end),
    _pipe@2 = do_shuffle_by_pair_indexes(_pipe@1),
    do_shuffle_pair_unwrap(_pipe@2, []).
