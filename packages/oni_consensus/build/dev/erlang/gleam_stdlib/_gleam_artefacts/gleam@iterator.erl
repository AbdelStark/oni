-module(gleam@iterator).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/iterator.gleam").
-export([unfold/2, repeatedly/1, repeat/1, from_list/1, transform/3, fold/3, run/1, to_list/1, step/1, take/2, drop/2, map/2, map2/3, append/2, flatten/1, concat/1, flat_map/2, filter/2, cycle/1, find/2, index/1, iterate/2, take_while/2, drop_while/2, scan/3, zip/2, chunk/2, sized_chunk/2, intersperse/2, any/2, all/2, group/2, reduce/2, last/1, empty/0, once/1, range/2, single/1, interleave/2, fold_until/3, try_fold/3, first/1, at/2, length/1, each/2, yield/2]).
-export_type([action/1, iterator/1, step/2, chunk/2, sized_chunk/1]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type action(BSR) :: stop | {continue, BSR, fun(() -> action(BSR))}.

-opaque iterator(BSS) :: {iterator, fun(() -> action(BSS))}.

-type step(BST, BSU) :: {next, BST, BSU} | done.

-type chunk(BSV, BSW) :: {another_by,
        list(BSV),
        BSW,
        BSV,
        fun(() -> action(BSV))} |
    {last_by, list(BSV)}.

-type sized_chunk(BSX) :: {another, list(BSX), fun(() -> action(BSX))} |
    {last, list(BSX)} |
    no_more.

-file("src/gleam/iterator.gleam", 38).
-spec stop() -> action(any()).
stop() ->
    stop.

-file("src/gleam/iterator.gleam", 43).
-spec do_unfold(BTA, fun((BTA) -> step(BTB, BTA))) -> fun(() -> action(BTB)).
do_unfold(Initial, F) ->
    fun() -> case F(Initial) of
            {next, X, Acc} ->
                {continue, X, do_unfold(Acc, F)};

            done ->
                stop
        end end.

-file("src/gleam/iterator.gleam", 76).
?DOC(
    " Creates an iterator from a given function and accumulator.\n"
    "\n"
    " The function is called on the accumulator and returns either `Done`,\n"
    " indicating the iterator has no more elements, or `Next` which contains a\n"
    " new element and accumulator. The element is yielded by the iterator and the\n"
    " new accumulator is used with the function to compute the next element in\n"
    " the sequence.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " unfold(from: 5, with: fn(n) {\n"
    "  case n {\n"
    "    0 -> Done\n"
    "    n -> Next(element: n, accumulator: n - 1)\n"
    "  }\n"
    " })\n"
    " |> to_list\n"
    " // -> [5, 4, 3, 2, 1]\n"
    " ```\n"
).
-spec unfold(BTF, fun((BTF) -> step(BTG, BTF))) -> iterator(BTG).
unfold(Initial, F) ->
    _pipe = Initial,
    _pipe@1 = do_unfold(_pipe, F),
    {iterator, _pipe@1}.

-file("src/gleam/iterator.gleam", 89).
?DOC(
    " Creates an iterator that yields values created by calling a given function\n"
    " repeatedly.\n"
).
-spec repeatedly(fun(() -> BTK)) -> iterator(BTK).
repeatedly(F) ->
    unfold(nil, fun(_) -> {next, F(), nil} end).

-file("src/gleam/iterator.gleam", 104).
?DOC(
    " Creates an iterator that returns the same value infinitely.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " repeat(10)\n"
    " |> take(4)\n"
    " |> to_list\n"
    " // -> [10, 10, 10, 10]\n"
    " ```\n"
).
-spec repeat(BTM) -> iterator(BTM).
repeat(X) ->
    repeatedly(fun() -> X end).

-file("src/gleam/iterator.gleam", 118).
?DOC(
    " Creates an iterator that yields each element from the given list.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4])\n"
    " |> to_list\n"
    " // -> [1, 2, 3, 4]\n"
    " ```\n"
).
-spec from_list(list(BTO)) -> iterator(BTO).
from_list(List) ->
    Yield = fun(Acc) -> case Acc of
            [] ->
                done;

            [Head | Tail] ->
                {next, Head, Tail}
        end end,
    unfold(List, Yield).

-file("src/gleam/iterator.gleam", 129).
-spec do_transform(
    fun(() -> action(BTR)),
    BTT,
    fun((BTT, BTR) -> step(BTU, BTT))
) -> fun(() -> action(BTU)).
do_transform(Continuation, State, F) ->
    fun() -> case Continuation() of
            stop ->
                stop;

            {continue, El, Next} ->
                case F(State, El) of
                    done ->
                        stop;

                    {next, Yield, Next_state} ->
                        {continue, Yield, do_transform(Next, Next_state, F)}
                end
        end end.

-file("src/gleam/iterator.gleam", 164).
?DOC(
    " Creates an iterator from an existing iterator\n"
    " and a stateful function that may short-circuit.\n"
    "\n"
    " `f` takes arguments `acc` for current state and `el` for current element from underlying iterator,\n"
    " and returns either `Next` with yielded element and new state value, or `Done` to halt the iterator.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " Approximate implementation of `index` in terms of `transform`:\n"
    "\n"
    " ```gleam\n"
    " from_list([\"a\", \"b\", \"c\"])\n"
    " |> transform(0, fn(i, el) { Next(#(i, el), i + 1) })\n"
    " |> to_list\n"
    " // -> [#(0, \"a\"), #(1, \"b\"), #(2, \"c\")]\n"
    " ```\n"
).
-spec transform(iterator(BTY), BUA, fun((BUA, BTY) -> step(BUB, BUA))) -> iterator(BUB).
transform(Iterator, Initial, F) ->
    _pipe = do_transform(erlang:element(2, Iterator), Initial, F),
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 173).
-spec do_fold(fun(() -> action(BUF)), fun((BUH, BUF) -> BUH), BUH) -> BUH.
do_fold(Continuation, F, Accumulator) ->
    case Continuation() of
        {continue, Elem, Next} ->
            do_fold(Next, F, F(Accumulator, Elem));

        stop ->
            Accumulator
    end.

-file("src/gleam/iterator.gleam", 201).
?DOC(
    " Reduces an iterator of elements into a single value by calling a given\n"
    " function on each element in turn.\n"
    "\n"
    " If called on an iterator of infinite length then this function will never\n"
    " return.\n"
    "\n"
    " If you do not care about the end value and only wish to evaluate the\n"
    " iterator for side effects consider using the `run` function instead.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4])\n"
    " |> fold(from: 0, with: fn(acc, element) { element + acc })\n"
    " // -> 10\n"
    " ```\n"
).
-spec fold(iterator(BUI), BUK, fun((BUK, BUI) -> BUK)) -> BUK.
fold(Iterator, Initial, F) ->
    _pipe = erlang:element(2, Iterator),
    do_fold(_pipe, F, Initial).

-file("src/gleam/iterator.gleam", 215).
?DOC(
    " Evaluates all elements emitted by the given iterator. This function is useful for when\n"
    " you wish to trigger any side effects that would occur when evaluating\n"
    " the iterator.\n"
).
-spec run(iterator(any())) -> nil.
run(Iterator) ->
    fold(Iterator, nil, fun(_, _) -> nil end).

-file("src/gleam/iterator.gleam", 233).
?DOC(
    " Evaluates an iterator and returns all the elements as a list.\n"
    "\n"
    " If called on an iterator of infinite length then this function will never\n"
    " return.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3])\n"
    " |> map(fn(x) { x * 2 })\n"
    " |> to_list\n"
    " // -> [2, 4, 6]\n"
    " ```\n"
).
-spec to_list(iterator(BUN)) -> list(BUN).
to_list(Iterator) ->
    _pipe = Iterator,
    _pipe@1 = fold(_pipe, [], fun(Acc, E) -> [E | Acc] end),
    gleam@list:reverse(_pipe@1).

-file("src/gleam/iterator.gleam", 261).
?DOC(
    " Eagerly accesses the first value of an iterator, returning a `Next`\n"
    " that contains the first value and the rest of the iterator.\n"
    "\n"
    " If called on an empty iterator, `Done` is returned.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " let assert Next(first, rest) = from_list([1, 2, 3, 4]) |> step\n"
    "\n"
    " first\n"
    " // -> 1\n"
    "\n"
    " rest |> to_list\n"
    " // -> [2, 3, 4]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " empty() |> step\n"
    " // -> Done\n"
    " ```\n"
).
-spec step(iterator(BUQ)) -> step(BUQ, iterator(BUQ)).
step(Iterator) ->
    case (erlang:element(2, Iterator))() of
        stop ->
            done;

        {continue, E, A} ->
            {next, E, {iterator, A}}
    end.

-file("src/gleam/iterator.gleam", 268).
-spec do_take(fun(() -> action(BUV)), integer()) -> fun(() -> action(BUV)).
do_take(Continuation, Desired) ->
    fun() -> case Desired > 0 of
            false ->
                stop;

            true ->
                case Continuation() of
                    stop ->
                        stop;

                    {continue, E, Next} ->
                        {continue, E, do_take(Next, Desired - 1)}
                end
        end end.

-file("src/gleam/iterator.gleam", 301).
?DOC(
    " Creates an iterator that only yields the first `desired` elements.\n"
    "\n"
    " If the iterator does not have enough elements all of them are yielded.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4, 5])\n"
    " |> take(up_to: 3)\n"
    " |> to_list\n"
    " // -> [1, 2, 3]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2])\n"
    " |> take(up_to: 3)\n"
    " |> to_list\n"
    " // -> [1, 2]\n"
    " ```\n"
).
-spec take(iterator(BUY), integer()) -> iterator(BUY).
take(Iterator, Desired) ->
    _pipe = erlang:element(2, Iterator),
    _pipe@1 = do_take(_pipe, Desired),
    {iterator, _pipe@1}.

-file("src/gleam/iterator.gleam", 307).
-spec do_drop(fun(() -> action(BVB)), integer()) -> action(BVB).
do_drop(Continuation, Desired) ->
    case Continuation() of
        stop ->
            stop;

        {continue, E, Next} ->
            case Desired > 0 of
                true ->
                    do_drop(Next, Desired - 1);

                false ->
                    {continue, E, Next}
            end
    end.

-file("src/gleam/iterator.gleam", 343).
?DOC(
    " Evaluates and discards the first N elements in an iterator, returning a new\n"
    " iterator.\n"
    "\n"
    " If the iterator does not have enough elements an empty iterator is\n"
    " returned.\n"
    "\n"
    " This function does not evaluate the elements of the iterator, the\n"
    " computation is performed when the iterator is later run.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4, 5])\n"
    " |> drop(up_to: 3)\n"
    " |> to_list\n"
    " // -> [4, 5]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2])\n"
    " |> drop(up_to: 3)\n"
    " |> to_list\n"
    " // -> []\n"
    " ```\n"
).
-spec drop(iterator(BVE), integer()) -> iterator(BVE).
drop(Iterator, Desired) ->
    _pipe = fun() -> do_drop(erlang:element(2, Iterator), Desired) end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 348).
-spec do_map(fun(() -> action(BVH)), fun((BVH) -> BVJ)) -> fun(() -> action(BVJ)).
do_map(Continuation, F) ->
    fun() -> case Continuation() of
            stop ->
                stop;

            {continue, E, Continuation@1} ->
                {continue, F(E), do_map(Continuation@1, F)}
        end end.

-file("src/gleam/iterator.gleam", 374).
?DOC(
    " Creates an iterator from an existing iterator and a transformation function.\n"
    "\n"
    " Each element in the new iterator will be the result of calling the given\n"
    " function on the elements in the given iterator.\n"
    "\n"
    " This function does not evaluate the elements of the iterator, the\n"
    " computation is performed when the iterator is later run.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3])\n"
    " |> map(fn(x) { x * 2 })\n"
    " |> to_list\n"
    " // -> [2, 4, 6]\n"
    " ```\n"
).
-spec map(iterator(BVL), fun((BVL) -> BVN)) -> iterator(BVN).
map(Iterator, F) ->
    _pipe = erlang:element(2, Iterator),
    _pipe@1 = do_map(_pipe, F),
    {iterator, _pipe@1}.

-file("src/gleam/iterator.gleam", 380).
-spec do_map2(
    fun(() -> action(BVP)),
    fun(() -> action(BVR)),
    fun((BVP, BVR) -> BVT)
) -> fun(() -> action(BVT)).
do_map2(Continuation1, Continuation2, Fun) ->
    fun() -> case Continuation1() of
            stop ->
                stop;

            {continue, A, Next_a} ->
                case Continuation2() of
                    stop ->
                        stop;

                    {continue, B, Next_b} ->
                        {continue, Fun(A, B), do_map2(Next_a, Next_b, Fun)}
                end
        end end.

-file("src/gleam/iterator.gleam", 421).
?DOC(
    " Combines two interators into a single one using the given function.\n"
    "\n"
    " If an iterator is longer than the other the extra elements are dropped.\n"
    "\n"
    " This function does not evaluate the elements of the two iterators, the\n"
    " computation is performed when the resulting iterator is later run.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " let first = from_list([1, 2, 3])\n"
    " let second = from_list([4, 5, 6])\n"
    " map2(first, second, fn(x, y) { x + y }) |> to_list\n"
    " // -> [5, 7, 9]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " let first = from_list([1, 2])\n"
    " let second = from_list([\"a\", \"b\", \"c\"])\n"
    " map2(first, second, fn(i, x) { #(i, x) }) |> to_list\n"
    " // -> [#(1, \"a\"), #(2, \"b\")]\n"
    " ```\n"
).
-spec map2(iterator(BVV), iterator(BVX), fun((BVV, BVX) -> BVZ)) -> iterator(BVZ).
map2(Iterator1, Iterator2, Fun) ->
    _pipe = do_map2(
        erlang:element(2, Iterator1),
        erlang:element(2, Iterator2),
        Fun
    ),
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 430).
-spec do_append(fun(() -> action(BWB)), fun(() -> action(BWB))) -> action(BWB).
do_append(First, Second) ->
    case First() of
        {continue, E, First@1} ->
            {continue, E, fun() -> do_append(First@1, Second) end};

        stop ->
            Second()
    end.

-file("src/gleam/iterator.gleam", 451).
?DOC(
    " Appends two iterators, producing a new iterator.\n"
    "\n"
    " This function does not evaluate the elements of the iterators, the\n"
    " computation is performed when the resulting iterator is later run.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2])\n"
    " |> append(from_list([3, 4]))\n"
    " |> to_list\n"
    " // -> [1, 2, 3, 4]\n"
    " ```\n"
).
-spec append(iterator(BWF), iterator(BWF)) -> iterator(BWF).
append(First, Second) ->
    _pipe = fun() ->
        do_append(erlang:element(2, First), erlang:element(2, Second))
    end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 459).
-spec do_flatten(fun(() -> action(iterator(BWJ)))) -> action(BWJ).
do_flatten(Flattened) ->
    case Flattened() of
        stop ->
            stop;

        {continue, It, Next_iterator} ->
            do_append(
                erlang:element(2, It),
                fun() -> do_flatten(Next_iterator) end
            )
    end.

-file("src/gleam/iterator.gleam", 482).
?DOC(
    " Flattens an iterator of iterators, creating a new iterator.\n"
    "\n"
    " This function does not evaluate the elements of the iterator, the\n"
    " computation is performed when the iterator is later run.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([[1, 2], [3, 4]])\n"
    " |> map(from_list)\n"
    " |> flatten\n"
    " |> to_list\n"
    " // -> [1, 2, 3, 4]\n"
    " ```\n"
).
-spec flatten(iterator(iterator(BWN))) -> iterator(BWN).
flatten(Iterator) ->
    _pipe = fun() -> do_flatten(erlang:element(2, Iterator)) end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 502).
?DOC(
    " Joins a list of iterators into a single iterator.\n"
    "\n"
    " This function does not evaluate the elements of the iterator, the\n"
    " computation is performed when the iterator is later run.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " [[1, 2], [3, 4]]\n"
    " |> map(from_list)\n"
    " |> concat\n"
    " |> to_list\n"
    " // -> [1, 2, 3, 4]\n"
    " ```\n"
).
-spec concat(list(iterator(BWR))) -> iterator(BWR).
concat(Iterators) ->
    flatten(from_list(Iterators)).

-file("src/gleam/iterator.gleam", 524).
?DOC(
    " Creates an iterator from an existing iterator and a transformation function.\n"
    "\n"
    " Each element in the new iterator will be the result of calling the given\n"
    " function on the elements in the given iterator and then flattening the\n"
    " results.\n"
    "\n"
    " This function does not evaluate the elements of the iterator, the\n"
    " computation is performed when the iterator is later run.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2])\n"
    " |> flat_map(fn(x) { from_list([x, x + 1]) })\n"
    " |> to_list\n"
    " // -> [1, 2, 2, 3]\n"
    " ```\n"
).
-spec flat_map(iterator(BWV), fun((BWV) -> iterator(BWX))) -> iterator(BWX).
flat_map(Iterator, F) ->
    _pipe = Iterator,
    _pipe@1 = map(_pipe, F),
    flatten(_pipe@1).

-file("src/gleam/iterator.gleam", 533).
-spec do_filter(fun(() -> action(BXA)), fun((BXA) -> boolean())) -> action(BXA).
do_filter(Continuation, Predicate) ->
    case Continuation() of
        stop ->
            stop;

        {continue, E, Iterator} ->
            case Predicate(E) of
                true ->
                    {continue, E, fun() -> do_filter(Iterator, Predicate) end};

                false ->
                    do_filter(Iterator, Predicate)
            end
    end.

-file("src/gleam/iterator.gleam", 565).
?DOC(
    " Creates an iterator from an existing iterator and a predicate function.\n"
    "\n"
    " The new iterator will contain elements from the first iterator for which\n"
    " the given function returns `True`.\n"
    "\n"
    " This function does not evaluate the elements of the iterator, the\n"
    " computation is performed when the iterator is later run.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " import gleam/int\n"
    " from_list([1, 2, 3, 4])\n"
    " |> filter(int.is_even)\n"
    " |> to_list\n"
    " // -> [2, 4]\n"
    " ```\n"
).
-spec filter(iterator(BXD), fun((BXD) -> boolean())) -> iterator(BXD).
filter(Iterator, Predicate) ->
    _pipe = fun() -> do_filter(erlang:element(2, Iterator), Predicate) end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 585).
?DOC(
    " Creates an iterator that repeats a given iterator infinitely.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2])\n"
    " |> cycle\n"
    " |> take(6)\n"
    " |> to_list\n"
    " // -> [1, 2, 1, 2, 1, 2]\n"
    " ```\n"
).
-spec cycle(iterator(BXG)) -> iterator(BXG).
cycle(Iterator) ->
    _pipe = repeat(Iterator),
    flatten(_pipe).

-file("src/gleam/iterator.gleam", 631).
-spec do_find(fun(() -> action(BXK)), fun((BXK) -> boolean())) -> {ok, BXK} |
    {error, nil}.
do_find(Continuation, F) ->
    case Continuation() of
        stop ->
            {error, nil};

        {continue, E, Next} ->
            case F(E) of
                true ->
                    {ok, E};

                false ->
                    do_find(Next, F)
            end
    end.

-file("src/gleam/iterator.gleam", 668).
?DOC(
    " Finds the first element in a given iterator for which the given function returns\n"
    " `True`.\n"
    "\n"
    " Returns `Error(Nil)` if the function does not return `True` for any of the\n"
    " elements.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " find(from_list([1, 2, 3]), fn(x) { x > 2 })\n"
    " // -> Ok(3)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " find(from_list([1, 2, 3]), fn(x) { x > 4 })\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " find(empty(), fn(_) { True })\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec find(iterator(BXO), fun((BXO) -> boolean())) -> {ok, BXO} | {error, nil}.
find(Haystack, Is_desired) ->
    _pipe = erlang:element(2, Haystack),
    do_find(_pipe, Is_desired).

-file("src/gleam/iterator.gleam", 676).
-spec do_index(fun(() -> action(BXS)), integer()) -> fun(() -> action({BXS,
    integer()})).
do_index(Continuation, Next) ->
    fun() -> case Continuation() of
            stop ->
                stop;

            {continue, E, Continuation@1} ->
                {continue, {E, Next}, do_index(Continuation@1, Next + 1)}
        end end.

-file("src/gleam/iterator.gleam", 698).
?DOC(
    " Wraps values yielded from an iterator with indices, starting from 0.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([\"a\", \"b\", \"c\"]) |> index |> to_list\n"
    " // -> [#(\"a\", 0), #(\"b\", 1), #(\"c\", 2)]\n"
    " ```\n"
).
-spec index(iterator(BXV)) -> iterator({BXV, integer()}).
index(Iterator) ->
    _pipe = erlang:element(2, Iterator),
    _pipe@1 = do_index(_pipe, 0),
    {iterator, _pipe@1}.

-file("src/gleam/iterator.gleam", 713).
?DOC(
    " Creates an iterator that inifinitely applies a function to a value.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " iterate(1, fn(n) { n * 3 }) |> take(5) |> to_list\n"
    " // -> [1, 3, 9, 27, 81]\n"
    " ```\n"
).
-spec iterate(BXY, fun((BXY) -> BXY)) -> iterator(BXY).
iterate(Initial, F) ->
    unfold(Initial, fun(Element) -> {next, Element, F(Element)} end).

-file("src/gleam/iterator.gleam", 720).
-spec do_take_while(fun(() -> action(BYA)), fun((BYA) -> boolean())) -> fun(() -> action(BYA)).
do_take_while(Continuation, Predicate) ->
    fun() -> case Continuation() of
            stop ->
                stop;

            {continue, E, Next} ->
                case Predicate(E) of
                    false ->
                        stop;

                    true ->
                        {continue, E, do_take_while(Next, Predicate)}
                end
        end end.

-file("src/gleam/iterator.gleam", 747).
?DOC(
    " Creates an iterator that yields elements while the predicate returns `True`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 2, 4])\n"
    " |> take_while(satisfying: fn(x) { x < 3 })\n"
    " |> to_list\n"
    " // -> [1, 2]\n"
    " ```\n"
).
-spec take_while(iterator(BYD), fun((BYD) -> boolean())) -> iterator(BYD).
take_while(Iterator, Predicate) ->
    _pipe = erlang:element(2, Iterator),
    _pipe@1 = do_take_while(_pipe, Predicate),
    {iterator, _pipe@1}.

-file("src/gleam/iterator.gleam", 756).
-spec do_drop_while(fun(() -> action(BYG)), fun((BYG) -> boolean())) -> action(BYG).
do_drop_while(Continuation, Predicate) ->
    case Continuation() of
        stop ->
            stop;

        {continue, E, Next} ->
            case Predicate(E) of
                false ->
                    {continue, E, Next};

                true ->
                    do_drop_while(Next, Predicate)
            end
    end.

-file("src/gleam/iterator.gleam", 782).
?DOC(
    " Creates an iterator that drops elements while the predicate returns `True`,\n"
    " and then yields the remaining elements.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4, 2, 5])\n"
    " |> drop_while(satisfying: fn(x) { x < 4 })\n"
    " |> to_list\n"
    " // -> [4, 2, 5]\n"
    " ```\n"
).
-spec drop_while(iterator(BYJ), fun((BYJ) -> boolean())) -> iterator(BYJ).
drop_while(Iterator, Predicate) ->
    _pipe = fun() -> do_drop_while(erlang:element(2, Iterator), Predicate) end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 790).
-spec do_scan(fun(() -> action(BYM)), fun((BYO, BYM) -> BYO), BYO) -> fun(() -> action(BYO)).
do_scan(Continuation, F, Accumulator) ->
    fun() -> case Continuation() of
            stop ->
                stop;

            {continue, El, Next} ->
                Accumulated = F(Accumulator, El),
                {continue, Accumulated, do_scan(Next, F, Accumulated)}
        end end.

-file("src/gleam/iterator.gleam", 820).
?DOC(
    " Creates an iterator from an existing iterator and a stateful function.\n"
    "\n"
    " Specifically, this behaves like `fold`, but yields intermediate results.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " // Generate a sequence of partial sums\n"
    " from_list([1, 2, 3, 4, 5])\n"
    " |> scan(from: 0, with: fn(acc, el) { acc + el })\n"
    " |> to_list\n"
    " // -> [1, 3, 6, 10, 15]\n"
    " ```\n"
).
-spec scan(iterator(BYQ), BYS, fun((BYS, BYQ) -> BYS)) -> iterator(BYS).
scan(Iterator, Initial, F) ->
    _pipe = erlang:element(2, Iterator),
    _pipe@1 = do_scan(_pipe, F, Initial),
    {iterator, _pipe@1}.

-file("src/gleam/iterator.gleam", 830).
-spec do_zip(fun(() -> action(BYU)), fun(() -> action(BYW))) -> fun(() -> action({BYU,
    BYW})).
do_zip(Left, Right) ->
    fun() -> case Left() of
            stop ->
                stop;

            {continue, El_left, Next_left} ->
                case Right() of
                    stop ->
                        stop;

                    {continue, El_right, Next_right} ->
                        {continue,
                            {El_left, El_right},
                            do_zip(Next_left, Next_right)}
                end
        end end.

-file("src/gleam/iterator.gleam", 859).
?DOC(
    " Zips two iterators together, emitting values from both\n"
    " until the shorter one runs out.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([\"a\", \"b\", \"c\"])\n"
    " |> zip(range(20, 30))\n"
    " |> to_list\n"
    " // -> [#(\"a\", 20), #(\"b\", 21), #(\"c\", 22)]\n"
    " ```\n"
).
-spec zip(iterator(BYZ), iterator(BZB)) -> iterator({BYZ, BZB}).
zip(Left, Right) ->
    _pipe = do_zip(erlang:element(2, Left), erlang:element(2, Right)),
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 870).
-spec next_chunk(fun(() -> action(BZE)), fun((BZE) -> BZG), BZG, list(BZE)) -> chunk(BZE, BZG).
next_chunk(Continuation, F, Previous_key, Current_chunk) ->
    case Continuation() of
        stop ->
            {last_by, gleam@list:reverse(Current_chunk)};

        {continue, E, Next} ->
            Key = F(E),
            case Key =:= Previous_key of
                true ->
                    next_chunk(Next, F, Key, [E | Current_chunk]);

                false ->
                    {another_by,
                        gleam@list:reverse(Current_chunk),
                        Key,
                        E,
                        Next}
            end
    end.

-file("src/gleam/iterator.gleam", 888).
-spec do_chunk(fun(() -> action(BZK)), fun((BZK) -> BZM), BZM, BZK) -> action(list(BZK)).
do_chunk(Continuation, F, Previous_key, Previous_element) ->
    case next_chunk(Continuation, F, Previous_key, [Previous_element]) of
        {last_by, Chunk} ->
            {continue, Chunk, fun stop/0};

        {another_by, Chunk@1, Key, El, Next} ->
            {continue, Chunk@1, fun() -> do_chunk(Next, F, Key, El) end}
    end.

-file("src/gleam/iterator.gleam", 913).
?DOC(
    " Creates an iterator that emits chunks of elements\n"
    " for which `f` returns the same value.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 2, 3, 4, 4, 6, 7, 7])\n"
    " |> chunk(by: fn(n) { n % 2 })\n"
    " |> to_list\n"
    " // -> [[1], [2, 2], [3], [4, 4, 6], [7, 7]]\n"
    " ```\n"
).
-spec chunk(iterator(BZP), fun((BZP) -> any())) -> iterator(list(BZP)).
chunk(Iterator, F) ->
    _pipe = fun() -> case (erlang:element(2, Iterator))() of
            stop ->
                stop;

            {continue, E, Next} ->
                do_chunk(Next, F, F(E), E)
        end end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 933).
-spec next_sized_chunk(fun(() -> action(BZU)), integer(), list(BZU)) -> sized_chunk(BZU).
next_sized_chunk(Continuation, Left, Current_chunk) ->
    case Continuation() of
        stop ->
            case Current_chunk of
                [] ->
                    no_more;

                Remaining ->
                    {last, gleam@list:reverse(Remaining)}
            end;

        {continue, E, Next} ->
            Chunk = [E | Current_chunk],
            case Left > 1 of
                false ->
                    {another, gleam@list:reverse(Chunk), Next};

                true ->
                    next_sized_chunk(Next, Left - 1, Chunk)
            end
    end.

-file("src/gleam/iterator.gleam", 954).
-spec do_sized_chunk(fun(() -> action(BZY)), integer()) -> fun(() -> action(list(BZY))).
do_sized_chunk(Continuation, Count) ->
    fun() -> case next_sized_chunk(Continuation, Count, []) of
            no_more ->
                stop;

            {last, Chunk} ->
                {continue, Chunk, fun stop/0};

            {another, Chunk@1, Next_element} ->
                {continue, Chunk@1, do_sized_chunk(Next_element, Count)}
        end end.

-file("src/gleam/iterator.gleam", 991).
?DOC(
    " Creates an iterator that emits chunks of given size.\n"
    "\n"
    " If the last chunk does not have `count` elements, it is yielded\n"
    " as a partial chunk, with less than `count` elements.\n"
    "\n"
    " For any `count` less than 1 this function behaves as if it was set to 1.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4, 5, 6])\n"
    " |> sized_chunk(into: 2)\n"
    " |> to_list\n"
    " // -> [[1, 2], [3, 4], [5, 6]]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4, 5, 6, 7, 8])\n"
    " |> sized_chunk(into: 3)\n"
    " |> to_list\n"
    " // -> [[1, 2, 3], [4, 5, 6], [7, 8]]\n"
    " ```\n"
).
-spec sized_chunk(iterator(CAC), integer()) -> iterator(list(CAC)).
sized_chunk(Iterator, Count) ->
    _pipe = erlang:element(2, Iterator),
    _pipe@1 = do_sized_chunk(_pipe, Count),
    {iterator, _pipe@1}.

-file("src/gleam/iterator.gleam", 1000).
-spec do_intersperse(fun(() -> action(CAG)), CAG) -> action(CAG).
do_intersperse(Continuation, Separator) ->
    case Continuation() of
        stop ->
            stop;

        {continue, E, Next} ->
            Next_interspersed = fun() -> do_intersperse(Next, Separator) end,
            {continue, Separator, fun() -> {continue, E, Next_interspersed} end}
    end.

-file("src/gleam/iterator.gleam", 1039).
?DOC(
    " Creates an iterator that yields the given `elem` element\n"
    " between elements emitted by the underlying iterator.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " empty()\n"
    " |> intersperse(with: 0)\n"
    " |> to_list\n"
    " // -> []\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1])\n"
    " |> intersperse(with: 0)\n"
    " |> to_list\n"
    " // -> [1]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4, 5])\n"
    " |> intersperse(with: 0)\n"
    " |> to_list\n"
    " // -> [1, 0, 2, 0, 3, 0, 4, 0, 5]\n"
    " ```\n"
).
-spec intersperse(iterator(CAJ), CAJ) -> iterator(CAJ).
intersperse(Iterator, Elem) ->
    _pipe = fun() -> case (erlang:element(2, Iterator))() of
            stop ->
                stop;

            {continue, E, Next} ->
                {continue, E, fun() -> do_intersperse(Next, Elem) end}
        end end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 1052).
-spec do_any(fun(() -> action(CAM)), fun((CAM) -> boolean())) -> boolean().
do_any(Continuation, Predicate) ->
    case Continuation() of
        stop ->
            false;

        {continue, E, Next} ->
            case Predicate(E) of
                true ->
                    true;

                false ->
                    do_any(Next, Predicate)
            end
    end.

-file("src/gleam/iterator.gleam", 1093).
?DOC(
    " Returns `True` if any element emitted by the iterator satisfies the given predicate,\n"
    " `False` otherwise.\n"
    "\n"
    " This function short-circuits once it finds a satisfying element.\n"
    "\n"
    " An empty iterator results in `False`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " empty()\n"
    " |> any(fn(n) { n % 2 == 0 })\n"
    " // -> False\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 5, 7, 9])\n"
    " |> any(fn(n) { n % 2 == 0 })\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 3, 5, 7, 9])\n"
    " |> any(fn(n) { n % 2 == 0 })\n"
    " // -> False\n"
    " ```\n"
).
-spec any(iterator(CAO), fun((CAO) -> boolean())) -> boolean().
any(Iterator, Predicate) ->
    _pipe = erlang:element(2, Iterator),
    do_any(_pipe, Predicate).

-file("src/gleam/iterator.gleam", 1101).
-spec do_all(fun(() -> action(CAQ)), fun((CAQ) -> boolean())) -> boolean().
do_all(Continuation, Predicate) ->
    case Continuation() of
        stop ->
            true;

        {continue, E, Next} ->
            case Predicate(E) of
                true ->
                    do_all(Next, Predicate);

                false ->
                    false
            end
    end.

-file("src/gleam/iterator.gleam", 1142).
?DOC(
    " Returns `True` if all elements emitted by the iterator satisfy the given predicate,\n"
    " `False` otherwise.\n"
    "\n"
    " This function short-circuits once it finds a non-satisfying element.\n"
    "\n"
    " An empty iterator results in `True`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " empty()\n"
    " |> all(fn(n) { n % 2 == 0 })\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([2, 4, 6, 8])\n"
    " |> all(fn(n) { n % 2 == 0 })\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([2, 4, 5, 8])\n"
    " |> all(fn(n) { n % 2 == 0 })\n"
    " // -> False\n"
    " ```\n"
).
-spec all(iterator(CAS), fun((CAS) -> boolean())) -> boolean().
all(Iterator, Predicate) ->
    _pipe = erlang:element(2, Iterator),
    do_all(_pipe, Predicate).

-file("src/gleam/iterator.gleam", 1150).
-spec update_group_with(CAU) -> fun((gleam@option:option(list(CAU))) -> list(CAU)).
update_group_with(El) ->
    fun(Maybe_group) -> case Maybe_group of
            {some, Group} ->
                [El | Group];

            none ->
                [El]
        end end.

-file("src/gleam/iterator.gleam", 1161).
-spec group_updater(fun((CAY) -> CAZ)) -> fun((gleam@dict:dict(CAZ, list(CAY)), CAY) -> gleam@dict:dict(CAZ, list(CAY))).
group_updater(F) ->
    fun(Groups, Elem) -> _pipe = Groups,
        gleam@dict:update(_pipe, F(Elem), update_group_with(Elem)) end.

-file("src/gleam/iterator.gleam", 1183).
?DOC(
    " Returns a `Dict(k, List(element))` of elements from the given iterator\n"
    " grouped with the given key function.\n"
    "\n"
    " The order within each group is preserved from the iterator.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4, 5, 6])\n"
    " |> group(by: fn(n) { n % 3 })\n"
    " // -> dict.from_list([#(0, [3, 6]), #(1, [1, 4]), #(2, [2, 5])])\n"
    " ```\n"
).
-spec group(iterator(CBG), fun((CBG) -> CBI)) -> gleam@dict:dict(CBI, list(CBG)).
group(Iterator, Key) ->
    _pipe = Iterator,
    _pipe@1 = fold(_pipe, gleam@dict:new(), group_updater(Key)),
    gleam@dict:map_values(
        _pipe@1,
        fun(_, Group) -> gleam@list:reverse(Group) end
    ).

-file("src/gleam/iterator.gleam", 1213).
?DOC(
    " This function acts similar to fold, but does not take an initial state.\n"
    " Instead, it starts from the first yielded element\n"
    " and combines it with each subsequent element in turn using the given function.\n"
    " The function is called as `f(accumulator, current_element)`.\n"
    "\n"
    " Returns `Ok` to indicate a successful run, and `Error` if called on an empty iterator.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([])\n"
    " |> reduce(fn(acc, x) { acc + x })\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4, 5])\n"
    " |> reduce(fn(acc, x) { acc + x })\n"
    " // -> Ok(15)\n"
    " ```\n"
).
-spec reduce(iterator(CBM), fun((CBM, CBM) -> CBM)) -> {ok, CBM} | {error, nil}.
reduce(Iterator, F) ->
    case (erlang:element(2, Iterator))() of
        stop ->
            {error, nil};

        {continue, E, Next} ->
            _pipe = do_fold(Next, F, E),
            {ok, _pipe}
    end.

-file("src/gleam/iterator.gleam", 1243).
?DOC(
    " Returns the last element in the given iterator.\n"
    "\n"
    " Returns `Error(Nil)` if the iterator is empty.\n"
    "\n"
    " This function runs in linear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " empty() |> last\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " range(1, 10) |> last\n"
    " // -> Ok(9)\n"
    " ```\n"
).
-spec last(iterator(CBQ)) -> {ok, CBQ} | {error, nil}.
last(Iterator) ->
    _pipe = Iterator,
    reduce(_pipe, fun(_, Elem) -> Elem end).

-file("src/gleam/iterator.gleam", 1257).
?DOC(
    " Creates an iterator that yields no elements.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " empty() |> to_list\n"
    " // -> []\n"
    " ```\n"
).
-spec empty() -> iterator(any()).
empty() ->
    {iterator, fun stop/0}.

-file("src/gleam/iterator.gleam", 1270).
?DOC(
    " Creates an iterator that yields exactly one element provided by calling the given function.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " once(fn() { 1 }) |> to_list\n"
    " // -> [1]\n"
    " ```\n"
).
-spec once(fun(() -> CBW)) -> iterator(CBW).
once(F) ->
    _pipe = fun() -> {continue, F(), fun stop/0} end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 610).
?DOC(
    " Creates an iterator of ints, starting at a given start int and stepping by\n"
    " one to a given end int.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " range(from: 1, to: 5) |> to_list\n"
    " // -> [1, 2, 3, 4, 5]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " range(from: 1, to: -2) |> to_list\n"
    " // -> [1, 0, -1, -2]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " range(from: 0, to: 0) |> to_list\n"
    " // -> [0]\n"
    " ```\n"
).
-spec range(integer(), integer()) -> iterator(integer()).
range(Start, Stop) ->
    case gleam@int:compare(Start, Stop) of
        eq ->
            once(fun() -> Start end);

        gt ->
            unfold(Start, fun(Current) -> case Current < Stop of
                        false ->
                            {next, Current, Current - 1};

                        true ->
                            done
                    end end);

        lt ->
            unfold(Start, fun(Current@1) -> case Current@1 > Stop of
                        false ->
                            {next, Current@1, Current@1 + 1};

                        true ->
                            done
                    end end)
    end.

-file("src/gleam/iterator.gleam", 1284).
?DOC(
    " Creates an iterator that yields the given element exactly once.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " single(1) |> to_list\n"
    " // -> [1]\n"
    " ```\n"
).
-spec single(CBY) -> iterator(CBY).
single(Elem) ->
    once(fun() -> Elem end).

-file("src/gleam/iterator.gleam", 1288).
-spec do_interleave(fun(() -> action(CCA)), fun(() -> action(CCA))) -> action(CCA).
do_interleave(Current, Next) ->
    case Current() of
        stop ->
            Next();

        {continue, E, Next_other} ->
            {continue, E, fun() -> do_interleave(Next, Next_other) end}
    end.

-file("src/gleam/iterator.gleam", 1318).
?DOC(
    " Creates an iterator that alternates between the two given iterators\n"
    " until both have run out.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4])\n"
    " |> interleave(from_list([11, 12, 13, 14]))\n"
    " |> to_list\n"
    " // -> [1, 11, 2, 12, 3, 13, 4, 14]\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4])\n"
    " |> interleave(from_list([100]))\n"
    " |> to_list\n"
    " // -> [1, 100, 2, 3, 4]\n"
    " ```\n"
).
-spec interleave(iterator(CCE), iterator(CCE)) -> iterator(CCE).
interleave(Left, Right) ->
    _pipe = fun() ->
        do_interleave(erlang:element(2, Left), erlang:element(2, Right))
    end,
    {iterator, _pipe}.

-file("src/gleam/iterator.gleam", 1326).
-spec do_fold_until(
    fun(() -> action(CCI)),
    fun((CCK, CCI) -> gleam@list:continue_or_stop(CCK)),
    CCK
) -> CCK.
do_fold_until(Continuation, F, Accumulator) ->
    case Continuation() of
        stop ->
            Accumulator;

        {continue, Elem, Next} ->
            case F(Accumulator, Elem) of
                {continue, Accumulator@1} ->
                    do_fold_until(Next, F, Accumulator@1);

                {stop, Accumulator@2} ->
                    Accumulator@2
            end
    end.

-file("src/gleam/iterator.gleam", 1365).
?DOC(
    " Like `fold`, `fold_until` reduces an iterator of elements into a single value by calling a given\n"
    " function on each element in turn, but uses `list.ContinueOrStop` to determine\n"
    " whether or not to keep iterating.\n"
    "\n"
    " If called on an iterator of infinite length then this function will only ever\n"
    " return if the function returns `list.Stop`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " import gleam/list\n"
    "\n"
    " let f = fn(acc, e) {\n"
    "   case e {\n"
    "     _ if e < 4 -> list.Continue(e + acc)\n"
    "     _ -> list.Stop(acc)\n"
    "   }\n"
    " }\n"
    "\n"
    " from_list([1, 2, 3, 4])\n"
    " |> fold_until(from: acc, with: f)\n"
    " // -> 6\n"
    " ```\n"
).
-spec fold_until(
    iterator(CCM),
    CCO,
    fun((CCO, CCM) -> gleam@list:continue_or_stop(CCO))
) -> CCO.
fold_until(Iterator, Initial, F) ->
    _pipe = erlang:element(2, Iterator),
    do_fold_until(_pipe, F, Initial).

-file("src/gleam/iterator.gleam", 1374).
-spec do_try_fold(
    fun(() -> action(CCQ)),
    fun((CCS, CCQ) -> {ok, CCS} | {error, CCT}),
    CCS
) -> {ok, CCS} | {error, CCT}.
do_try_fold(Continuation, F, Accumulator) ->
    case Continuation() of
        stop ->
            {ok, Accumulator};

        {continue, Elem, Next} ->
            gleam@result:'try'(
                F(Accumulator, Elem),
                fun(Accumulator@1) -> do_try_fold(Next, F, Accumulator@1) end
            )
    end.

-file("src/gleam/iterator.gleam", 1407).
?DOC(
    " A variant of fold that might fail.\n"
    "\n"
    " The folding function should return `Result(accumulator, error)`.\n"
    " If the returned value is `Ok(accumulator)` try_fold will try the next value in the iterator.\n"
    " If the returned value is `Error(error)` try_fold will stop and return that error.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4])\n"
    " |> try_fold(0, fn(acc, i) {\n"
    "   case i < 3 {\n"
    "     True -> Ok(acc + i)\n"
    "     False -> Error(Nil)\n"
    "   }\n"
    " })\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec try_fold(iterator(CCY), CDA, fun((CDA, CCY) -> {ok, CDA} | {error, CDB})) -> {ok,
        CDA} |
    {error, CDB}.
try_fold(Iterator, Initial, F) ->
    _pipe = erlang:element(2, Iterator),
    do_try_fold(_pipe, F, Initial).

-file("src/gleam/iterator.gleam", 1430).
?DOC(
    " Returns the first element yielded by the given iterator, if it exists,\n"
    " or `Error(Nil)` otherwise.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3]) |> first\n"
    " // -> Ok(1)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " empty() |> first\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec first(iterator(CDG)) -> {ok, CDG} | {error, nil}.
first(Iterator) ->
    case (erlang:element(2, Iterator))() of
        stop ->
            {error, nil};

        {continue, E, _} ->
            {ok, E}
    end.

-file("src/gleam/iterator.gleam", 1460).
?DOC(
    " Returns nth element yielded by the given iterator, where `0` means the first element.\n"
    "\n"
    " If there are not enough elements in the iterator, `Error(Nil)` is returned.\n"
    "\n"
    " For any `index` less than `0` this function behaves as if it was set to `0`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4]) |> at(2)\n"
    " // -> Ok(3)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4]) |> at(4)\n"
    " // -> Error(Nil)\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " empty() |> at(0)\n"
    " // -> Error(Nil)\n"
    " ```\n"
).
-spec at(iterator(CDK), integer()) -> {ok, CDK} | {error, nil}.
at(Iterator, Index) ->
    _pipe = Iterator,
    _pipe@1 = drop(_pipe, Index),
    first(_pipe@1).

-file("src/gleam/iterator.gleam", 1466).
-spec do_length(fun(() -> action(any())), integer()) -> integer().
do_length(Continuation, Length) ->
    case Continuation() of
        stop ->
            Length;

        {continue, _, Next} ->
            do_length(Next, Length + 1)
    end.

-file("src/gleam/iterator.gleam", 1490).
?DOC(
    " Counts the number of elements in the given iterator.\n"
    "\n"
    " This function has to traverse the entire iterator to count its elements,\n"
    " so it runs in linear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " empty() |> length\n"
    " // -> 0\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3, 4]) |> length\n"
    " // -> 4\n"
    " ```\n"
).
-spec length(iterator(any())) -> integer().
length(Iterator) ->
    _pipe = erlang:element(2, Iterator),
    do_length(_pipe, 0).

-file("src/gleam/iterator.gleam", 1512).
?DOC(
    " Traverse an iterator, calling a function on each element.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " empty() |> each(io.println)\n"
    " // -> Nil\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " from_list([\"Tom\", \"Malory\", \"Louis\"]) |> each(io.println)\n"
    " // -> Nil\n"
    " // Tom\n"
    " // Malory\n"
    " // Louis\n"
    " ```\n"
).
-spec each(iterator(CDS), fun((CDS) -> any())) -> nil.
each(Iterator, F) ->
    _pipe = Iterator,
    _pipe@1 = map(_pipe, F),
    run(_pipe@1).

-file("src/gleam/iterator.gleam", 1536).
?DOC(
    " Add a new element to the start of an iterator.\n"
    "\n"
    " This function is for use with `use` expressions, to replicate the behaviour\n"
    " of the `yield` keyword found in other languages.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " let iterator = {\n"
    "   use <- yield(1)\n"
    "   use <- yield(2)\n"
    "   use <- yield(3)\n"
    "   empty()\n"
    " }\n"
    " iterator |> to_list\n"
    " // -> [1, 2, 3]\n"
    " ```\n"
).
-spec yield(CDV, fun(() -> iterator(CDV))) -> iterator(CDV).
yield(Element, Next) ->
    {iterator, fun() -> {continue, Element, erlang:element(2, Next())} end}.
