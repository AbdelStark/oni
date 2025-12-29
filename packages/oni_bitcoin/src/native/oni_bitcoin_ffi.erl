%%% oni_bitcoin_ffi - FFI helpers for oni_bitcoin Gleam module
%%%
%%% Provides atom comparison functions for decoding Erlang results
%%% in Gleam's dynamic type system.

-module(oni_bitcoin_ffi).
-export([
    is_ok_atom/1,
    is_true_atom/1,
    is_false_atom/1,
    is_nif_not_loaded/1
]).

%% @doc Check if the value is the atom 'ok'
-spec is_ok_atom(term()) -> boolean().
is_ok_atom(ok) -> true;
is_ok_atom(_) -> false.

%% @doc Check if the value is the atom 'true'
-spec is_true_atom(term()) -> boolean().
is_true_atom(true) -> true;
is_true_atom(_) -> false.

%% @doc Check if the value is the atom 'false'
-spec is_false_atom(term()) -> boolean().
is_false_atom(false) -> true;
is_false_atom(_) -> false.

%% @doc Check if the value is the atom 'nif_not_loaded'
-spec is_nif_not_loaded(term()) -> boolean().
is_nif_not_loaded(nif_not_loaded) -> true;
is_nif_not_loaded(_) -> false.
