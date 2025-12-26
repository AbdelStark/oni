-module(gleam@erlang).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/erlang.gleam").
-export([format/1, term_to_binary/1, get_line/1, system_time/1, erlang_timestamp/0, rescue/1, binary_to_term/1, unsafe_binary_to_term/1, start_arguments/0, ensure_all_started/1, make_reference/0, priv_directory/1]).
-export_type([safe/0, get_line_error/0, time_unit/0, crash/0, ensure_all_started_error/0, reference_/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type safe() :: safe.

-type get_line_error() :: eof | no_data.

-type time_unit() :: second | millisecond | microsecond | nanosecond.

-type crash() :: {exited, gleam@dynamic:dynamic_()} |
    {thrown, gleam@dynamic:dynamic_()} |
    {errored, gleam@dynamic:dynamic_()}.

-type ensure_all_started_error() :: {unknown_application,
        gleam@erlang@atom:atom_()} |
    {application_failed_to_start,
        gleam@erlang@atom:atom_(),
        gleam@dynamic:dynamic_()}.

-type reference_() :: any().

-file("src/gleam/erlang.gleam", 10).
?DOC(" Return a string representation of any term\n").
-spec format(any()) -> binary().
format(Term) ->
    unicode:characters_to_binary(io_lib:format(<<"~p"/utf8>>, [Term])).

-file("src/gleam/erlang.gleam", 15).
-spec term_to_binary(any()) -> bitstring().
term_to_binary(A) ->
    erlang:term_to_binary(A).

-file("src/gleam/erlang.gleam", 54).
?DOC(
    " Reads a line from standard input with the given prompt.\n"
    "\n"
    " # Example\n"
    "\n"
    "    > get_line(\"Language: \")\n"
    "    // -> Language: <- gleam\n"
    "    Ok(\"gleam\\n\")\n"
).
-spec get_line(binary()) -> {ok, binary()} | {error, get_line_error()}.
get_line(Prompt) ->
    gleam_erlang_ffi:get_line(Prompt).

-file("src/gleam/erlang.gleam", 67).
?DOC(
    " Returns the current OS system time.\n"
    "\n"
    " <https://erlang.org/doc/apps/erts/time_correction.html#OS_System_Time>\n"
).
-spec system_time(time_unit()) -> integer().
system_time(A) ->
    os:system_time(A).

-file("src/gleam/erlang.gleam", 73).
?DOC(
    " Returns the current OS system time as a tuple of Ints\n"
    "\n"
    " http://erlang.org/doc/man/os.html#timestamp-0\n"
).
-spec erlang_timestamp() -> {integer(), integer(), integer()}.
erlang_timestamp() ->
    os:timestamp().

-file("src/gleam/erlang.gleam", 83).
?DOC(
    " Gleam doesn't offer any way to raise exceptions, but they may still occur\n"
    " due to bugs when working with unsafe code, such as when calling Erlang\n"
    " function.\n"
    "\n"
    " This function will catch any error thrown and convert it into a result\n"
    " rather than crashing the process.\n"
).
-spec rescue(fun(() -> FGY)) -> {ok, FGY} | {error, crash()}.
rescue(A) ->
    gleam_erlang_ffi:rescue(A).

-file("src/gleam/erlang.gleam", 24).
-spec binary_to_term(bitstring()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, nil}.
binary_to_term(Binary) ->
    case gleam_erlang_ffi:rescue(
        fun() -> erlang:binary_to_term(Binary, [safe]) end
    ) of
        {ok, Term} ->
            {ok, Term};

        {error, _} ->
            {error, nil}
    end.

-file("src/gleam/erlang.gleam", 31).
-spec unsafe_binary_to_term(bitstring()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, nil}.
unsafe_binary_to_term(Binary) ->
    case gleam_erlang_ffi:rescue(fun() -> erlang:binary_to_term(Binary, []) end) of
        {ok, Term} ->
            {ok, Term};

        {error, _} ->
            {error, nil}
    end.

-file("src/gleam/erlang.gleam", 98).
?DOC(
    " Get the arguments given to the program when it was started.\n"
    "\n"
    " This is sometimes called `argv` in other languages.\n"
).
-spec start_arguments() -> list(binary()).
start_arguments() ->
    _pipe = init:get_plain_arguments(),
    gleam@list:map(_pipe, fun unicode:characters_to_binary/1).

-file("src/gleam/erlang.gleam", 121).
?DOC(
    " Starts an OTP application's process tree in the background, as well as\n"
    " the trees of any applications that the given application depends upon. An\n"
    " OTP application typically maps onto a Gleam or Hex package.\n"
    "\n"
    " Returns a list of the applications that were started. Calling this function\n"
    " for application that have already been started is a no-op so you do not need\n"
    " to check the application state beforehand.\n"
    "\n"
    " In Gleam we prefer to not use these implicit background process trees, but\n"
    " you will likely still need to start the trees of OTP applications written in\n"
    " other BEAM languages such as Erlang or Elixir, including those included by\n"
    " default with Erlang/OTP.\n"
    "\n"
    " For more information see the OTP documentation.\n"
    " - <https://www.erlang.org/doc/man/application.html#ensure_all_started-1>\n"
    " - <https://www.erlang.org/doc/man/application.html#start-1>\n"
).
-spec ensure_all_started(gleam@erlang@atom:atom_()) -> {ok,
        list(gleam@erlang@atom:atom_())} |
    {error, ensure_all_started_error()}.
ensure_all_started(Application) ->
    gleam_erlang_ffi:ensure_all_started(Application).

-file("src/gleam/erlang.gleam", 144).
?DOC(" Create a new unique reference.\n").
-spec make_reference() -> reference_().
make_reference() ->
    erlang:make_ref().

-file("src/gleam/erlang.gleam", 159).
?DOC(
    " Returns the path of a package's `priv` directory, where extra non-Gleam\n"
    " or Erlang files are typically kept.\n"
    "\n"
    " Returns an error if no package was found with the given name.\n"
    "\n"
    " # Example\n"
    "\n"
    " ```gleam\n"
    " > erlang.priv_directory(\"my_app\")\n"
    " // -> Ok(\"/some/location/my_app/priv\")\n"
    " ```\n"
).
-spec priv_directory(binary()) -> {ok, binary()} | {error, nil}.
priv_directory(Name) ->
    gleam_erlang_ffi:priv_directory(Name).
