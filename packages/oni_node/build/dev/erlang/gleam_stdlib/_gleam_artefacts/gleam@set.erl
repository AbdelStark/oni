-module(gleam@set).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/set.gleam").
-export([new/0, size/1, contains/2, delete/2, to_list/1, fold/3, filter/2, drop/2, take/2, intersection/2, difference/2, insert/2, from_list/1, union/2]).
-export_type([set/1]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-opaque set(EVU) :: {set, gleam@dict:dict(EVU, list(nil))}.

-file("src/gleam/set.gleam", 32).
?DOC(" Creates a new empty set.\n").
-spec new() -> set(any()).
new() ->
    {set, gleam@dict:new()}.

-file("src/gleam/set.gleam", 50).
?DOC(
    " Gets the number of members in a set.\n"
    "\n"
    " This function runs in constant time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new()\n"
    " |> insert(1)\n"
    " |> insert(2)\n"
    " |> size\n"
    " // -> 2\n"
    " ```\n"
).
-spec size(set(any())) -> integer().
size(Set) ->
    maps:size(erlang:element(2, Set)).

-file("src/gleam/set.gleam", 92).
?DOC(
    " Checks whether a set contains a given member.\n"
    "\n"
    " This function runs in logarithmic time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new()\n"
    " |> insert(2)\n"
    " |> contains(2)\n"
    " // -> True\n"
    " ```\n"
    "\n"
    " ```gleam\n"
    " new()\n"
    " |> insert(2)\n"
    " |> contains(1)\n"
    " // -> False\n"
    " ```\n"
).
-spec contains(set(EWD), EWD) -> boolean().
contains(Set, Member) ->
    _pipe = erlang:element(2, Set),
    _pipe@1 = gleam@dict:get(_pipe, Member),
    gleam@result:is_ok(_pipe@1).

-file("src/gleam/set.gleam", 113).
?DOC(
    " Removes a member from a set. If the set does not contain the member then\n"
    " the set is returned unchanged.\n"
    "\n"
    " This function runs in logarithmic time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new()\n"
    " |> insert(2)\n"
    " |> delete(2)\n"
    " |> contains(1)\n"
    " // -> False\n"
    " ```\n"
).
-spec delete(set(EWF), EWF) -> set(EWF).
delete(Set, Member) ->
    {set, gleam@dict:delete(erlang:element(2, Set), Member)}.

-file("src/gleam/set.gleam", 131).
?DOC(
    " Converts the set into a list of the contained members.\n"
    "\n"
    " The list has no specific ordering, any unintentional ordering may change in\n"
    " future versions of Gleam or Erlang.\n"
    "\n"
    " This function runs in linear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new() |> insert(2) |> to_list\n"
    " // -> [2]\n"
    " ```\n"
).
-spec to_list(set(EWI)) -> list(EWI).
to_list(Set) ->
    gleam@dict:keys(erlang:element(2, Set)).

-file("src/gleam/set.gleam", 170).
?DOC(
    " Combines all entries into a single value by calling a given function on each\n"
    " one.\n"
    "\n"
    " Sets are not ordered so the values are not returned in any specific order.\n"
    " Do not write code that relies on the order entries are used by this\n"
    " function as it may change in later versions of Gleam or Erlang.\n"
    "\n"
    " # Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 3, 9])\n"
    " |> fold(0, fn(accumulator, member) { accumulator + member })\n"
    " // -> 13\n"
    " ```\n"
).
-spec fold(set(EWO), EWQ, fun((EWQ, EWO) -> EWQ)) -> EWQ.
fold(Set, Initial, Reducer) ->
    gleam@dict:fold(
        erlang:element(2, Set),
        Initial,
        fun(A, K, _) -> Reducer(A, K) end
    ).

-file("src/gleam/set.gleam", 193).
?DOC(
    " Creates a new set from an existing set, minus any members that a given\n"
    " function returns `False` for.\n"
    "\n"
    " This function runs in loglinear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " import gleam/int\n"
    " from_list([1, 4, 6, 3, 675, 44, 67])\n"
    " |> filter(for: int.is_even)\n"
    " |> to_list\n"
    " // -> [4, 6, 44]\n"
    " ```\n"
).
-spec filter(set(EWR), fun((EWR) -> boolean())) -> set(EWR).
filter(Set, Predicate) ->
    {set,
        gleam@dict:filter(erlang:element(2, Set), fun(M, _) -> Predicate(M) end)}.

-file("src/gleam/set.gleam", 200).
-spec drop(set(EWU), list(EWU)) -> set(EWU).
drop(Set, Disallowed) ->
    gleam@list:fold(Disallowed, Set, fun delete/2).

-file("src/gleam/set.gleam", 221).
?DOC(
    " Creates a new map from a given map, only including any members which are in\n"
    " a given list.\n"
    "\n"
    " This function runs in loglinear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " from_list([1, 2, 3])\n"
    " |> take([1, 3, 5])\n"
    " |> to_list\n"
    " // -> [1, 3]\n"
    " ```\n"
).
-spec take(set(EWY), list(EWY)) -> set(EWY).
take(Set, Desired) ->
    {set, gleam@dict:take(erlang:element(2, Set), Desired)}.

-file("src/gleam/set.gleam", 228).
-spec order(set(EXC), set(EXC)) -> {set(EXC), set(EXC)}.
order(First, Second) ->
    case maps:size(erlang:element(2, First)) > maps:size(
        erlang:element(2, Second)
    ) of
        true ->
            {First, Second};

        false ->
            {Second, First}
    end.

-file("src/gleam/set.gleam", 265).
?DOC(
    " Creates a new set that contains members that are present in both given sets.\n"
    "\n"
    " This function runs in loglinear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " intersection(from_list([1, 2]), from_list([2, 3])) |> to_list\n"
    " // -> [2]\n"
    " ```\n"
).
-spec intersection(set(EXL), set(EXL)) -> set(EXL).
intersection(First, Second) ->
    {Larger, Smaller} = order(First, Second),
    take(Larger, to_list(Smaller)).

-file("src/gleam/set.gleam", 283).
?DOC(
    " Creates a new set that contains members that are present in the first set\n"
    " but not the second.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " difference(from_list([1, 2]), from_list([2, 3, 4])) |> to_list\n"
    " // -> [1]\n"
    " ```\n"
).
-spec difference(set(EXP), set(EXP)) -> set(EXP).
difference(First, Second) ->
    drop(First, to_list(Second)).

-file("src/gleam/set.gleam", 68).
?DOC(
    " Inserts an member into the set.\n"
    "\n"
    " This function runs in logarithmic time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " new()\n"
    " |> insert(1)\n"
    " |> insert(2)\n"
    " |> size\n"
    " // -> 2\n"
    " ```\n"
).
-spec insert(set(EWA), EWA) -> set(EWA).
insert(Set, Member) ->
    {set, gleam@dict:insert(erlang:element(2, Set), Member, [])}.

-file("src/gleam/set.gleam", 147).
?DOC(
    " Creates a new set of the members in a given list.\n"
    "\n"
    " This function runs in loglinear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " import gleam/list\n"
    " [1, 1, 2, 4, 3, 2] |> from_list |> to_list |> list.sort\n"
    " // -> [1, 3, 3, 4]\n"
    " ```\n"
).
-spec from_list(list(EWL)) -> set(EWL).
from_list(Members) ->
    Map = gleam@list:fold(
        Members,
        gleam@dict:new(),
        fun(M, K) -> gleam@dict:insert(M, K, []) end
    ),
    {set, Map}.

-file("src/gleam/set.gleam", 249).
?DOC(
    " Creates a new set that contains all members of both given sets.\n"
    "\n"
    " This function runs in loglinear time.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " union(from_list([1, 2]), from_list([2, 3])) |> to_list\n"
    " // -> [1, 2, 3]\n"
    " ```\n"
).
-spec union(set(EXH), set(EXH)) -> set(EXH).
union(First, Second) ->
    {Larger, Smaller} = order(First, Second),
    fold(Smaller, Larger, fun insert/2).
