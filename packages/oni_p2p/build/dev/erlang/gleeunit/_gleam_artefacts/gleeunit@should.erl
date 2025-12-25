-module(gleeunit@should).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleeunit/should.gleam").
-export([equal/2, not_equal/2, be_ok/1, be_error/1, be_true/1, be_false/1, fail/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

?MODULEDOC(
    " A module for testing your Gleam code. The functions found here are\n"
    " compatible with the Erlang eunit test framework.\n"
    "\n"
    " More information on running eunit can be found in [the rebar3\n"
    " documentation](https://rebar3.org/docs/testing/eunit/).\n"
).

-file("src/gleeunit/should.gleam", 10).
-spec equal(GXT, GXT) -> nil.
equal(A, B) ->
    gleeunit_ffi:should_equal(A, B).

-file("src/gleeunit/should.gleam", 24).
-spec not_equal(GXU, GXU) -> nil.
not_equal(A, B) ->
    gleeunit_ffi:should_not_equal(A, B).

-file("src/gleeunit/should.gleam", 38).
-spec be_ok({ok, GXV} | {error, any()}) -> GXV.
be_ok(A) ->
    gleeunit_ffi:should_be_ok(A).

-file("src/gleeunit/should.gleam", 46).
-spec be_error({ok, any()} | {error, GYA}) -> GYA.
be_error(A) ->
    gleeunit_ffi:should_be_error(A).

-file("src/gleeunit/should.gleam", 53).
-spec be_true(boolean()) -> nil.
be_true(Actual) ->
    _pipe = Actual,
    gleeunit_ffi:should_equal(_pipe, true).

-file("src/gleeunit/should.gleam", 58).
-spec be_false(boolean()) -> nil.
be_false(Actual) ->
    _pipe = Actual,
    gleeunit_ffi:should_equal(_pipe, false).

-file("src/gleeunit/should.gleam", 63).
-spec fail() -> nil.
fail() ->
    be_true(false).
