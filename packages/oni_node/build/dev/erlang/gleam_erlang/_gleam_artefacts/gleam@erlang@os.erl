-module(gleam@erlang@os).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/erlang/os.gleam").
-export([get_all_env/0, get_env/1, set_env/2, unset_env/1, family/0]).
-export_type([os_family/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

?MODULEDOC(" Access to the shell's environment variables\n").

-type os_family() :: windows_nt | linux | darwin | free_bsd | {other, binary()}.

-file("src/gleam/erlang/os.gleam", 18).
?DOC(
    " Returns the list of all available environment variables as a list of key,\n"
    " tuples.\n"
    "\n"
    " ## Examples\n"
    "\n"
    "    > get_all_env()\n"
    "    dict.from_list([\n"
    "      #(\"SHELL\", \"/bin/bash\"),\n"
    "      #(\"PWD\", \"/home/j3rn\"),\n"
    "      ...\n"
    "    ])\n"
).
-spec get_all_env() -> gleam@dict:dict(binary(), binary()).
get_all_env() ->
    gleam_erlang_ffi:get_all_env().

-file("src/gleam/erlang/os.gleam", 31).
?DOC(
    " Returns the value associated with the given environment variable name.\n"
    "\n"
    " ## Examples\n"
    "\n"
    "    > get_env(\"SHELL\")\n"
    "    \"/bin/bash\"\n"
    "\n"
    "    > get_env(name: \"PWD\")\n"
    "    \"/home/j3rn\"\n"
).
-spec get_env(binary()) -> {ok, binary()} | {error, nil}.
get_env(Name) ->
    gleam_erlang_ffi:get_env(Name).

-file("src/gleam/erlang/os.gleam", 46).
?DOC(
    " Associates the given value with the given environment variable name.\n"
    "\n"
    " ## Examples\n"
    "\n"
    "    > set_env(\"MYVAR\", \"MYVALUE\")\n"
    "    Nil\n"
    "    > get_env(\"MYVAR\")\n"
    "    \"MYVALUE\"\n"
    "\n"
    "    > set_env(value: \"MYVALUE\", name: \"MYVAR\")\n"
    "    Nil\n"
).
-spec set_env(binary(), binary()) -> nil.
set_env(Name, Value) ->
    gleam_erlang_ffi:set_env(Name, Value).

-file("src/gleam/erlang/os.gleam", 65).
?DOC(
    " Removes the environment variable with the given name.\n"
    "\n"
    " Returns Nil regardless of whether the variable ever existed.\n"
    "\n"
    " ## Examples\n"
    "\n"
    "    > get_env(\"MYVAR\")\n"
    "    Ok(\"MYVALUE\")\n"
    "    > unset_env(\"MYVAR\")\n"
    "    Nil\n"
    "    > get_env(\"MYVAR\")\n"
    "    Error(Nil)\n"
    "\n"
    "    > unset_env(name: \"MYVAR\")\n"
    "    Nil\n"
).
-spec unset_env(binary()) -> nil.
unset_env(Name) ->
    gleam_erlang_ffi:unset_env(Name).

-file("src/gleam/erlang/os.gleam", 95).
?DOC(
    " Returns the kernel of the host operating system.\n"
    "\n"
    " Unknown kernels are reported as `Other(String)`; e.g. `Other(\"sunos\")`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    "    > family()\n"
    "    Linux\n"
    "    > family()\n"
    "    Darwin\n"
    "    > family()\n"
    "    Other(\"sunos\")\n"
).
-spec family() -> os_family().
family() ->
    gleam_erlang_ffi:os_family().
