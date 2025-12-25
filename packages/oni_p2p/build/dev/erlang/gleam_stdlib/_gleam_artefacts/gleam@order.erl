-module(gleam@order).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/order.gleam").
-export([negate/1, to_int/1, compare/2, max/2, min/2, reverse/1]).
-export_type([order/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type order() :: lt | eq | gt.

-file("src/gleam/order.gleam", 35).
?DOC(
    " Inverts an order, so less-than becomes greater-than and greater-than\n"
    " becomes less-than.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " negate(Lt)\n"
    " // -> Gt\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " negate(Eq)\n"
    " // -> Eq\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " negate(Lt)\n"
    " // -> Gt\n"
    " ```\n"
).
-spec negate(order()) -> order().
negate(Order) ->
    case Order of
        lt ->
            gt;

        eq ->
            eq;

        gt ->
            lt
    end.

-file("src/gleam/order.gleam", 62).
?DOC(
    " Produces a numeric representation of the order.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " to_int(Lt)\n"
    " // -> -1\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " to_int(Eq)\n"
    " // -> 0\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " to_int(Gt)\n"
    " // -> 1\n"
    " ```\n"
).
-spec to_int(order()) -> integer().
to_int(Order) ->
    case Order of
        lt ->
            -1;

        eq ->
            0;

        gt ->
            1
    end.

-file("src/gleam/order.gleam", 79).
?DOC(
    " Compares two `Order` values to one another, producing a new `Order`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " compare(Eq, with: Lt)\n"
    " // -> Gt\n"
    " ```\n"
).
-spec compare(order(), order()) -> order().
compare(A, B) ->
    case {A, B} of
        {X, Y} when X =:= Y ->
            eq;

        {lt, _} ->
            lt;

        {eq, gt} ->
            lt;

        {_, _} ->
            gt
    end.

-file("src/gleam/order.gleam", 96).
?DOC(
    " Returns the largest of two orders given that `Gt > Eq > Lt`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " max(Eq, Lt)\n"
    " // -> Eq\n"
    " ```\n"
).
-spec max(order(), order()) -> order().
max(A, B) ->
    case {A, B} of
        {gt, _} ->
            gt;

        {eq, lt} ->
            eq;

        {_, _} ->
            B
    end.

-file("src/gleam/order.gleam", 113).
?DOC(
    " Returns the smallest of two orders given that `Gt > Eq > Lt`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " min(Eq, Lt)\n"
    " // -> Lt\n"
    " ```\n"
).
-spec min(order(), order()) -> order().
min(A, B) ->
    case {A, B} of
        {lt, _} ->
            lt;

        {eq, gt} ->
            eq;

        {_, _} ->
            B
    end.

-file("src/gleam/order.gleam", 133).
?DOC(
    " Inverts an ordering function, so less-than becomes greater-than and greater-than\n"
    " becomes less-than.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " import gleam/int\n"
    " import gleam/list\n"
    " list.sort([1, 5, 4], by: reverse(int.compare))\n"
    " // -> [5, 4, 1]\n"
    " ```\n"
).
-spec reverse(fun((I, I) -> order())) -> fun((I, I) -> order()).
reverse(Orderer) ->
    fun(A, B) -> Orderer(B, A) end.
