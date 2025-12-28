%% db_backend_ffi.erl - Erlang FFI for persistent database backend
%%
%% This module provides the native implementation for db_backend.gleam,
%% wrapping Erlang's dets module for persistent key-value storage.
%%
%% All functions return {ok, Result} or {error, ErrorType} tuples
%% that map to Gleam Result types.

-module(db_backend_ffi).

-export([
    dets_open/3,
    dets_close/1,
    dets_lookup/2,
    dets_insert/3,
    dets_delete/2,
    dets_member/2,
    dets_sync/1,
    dets_all_keys/1,
    dets_info_size/1
]).

%% Open a dets table with the given options
%% Options is a Gleam record: DbOptions(create, auto_repair, max_keys, ram_file)
-spec dets_open(atom(), binary(), tuple()) -> {ok, atom()} | {error, tuple()}.
dets_open(Name, Path, Options) ->
    %% Convert binary path to charlist (Erlang string)
    PathStr = binary_to_list(Path),

    %% Extract options from Gleam record
    %% DbOptions(create, auto_repair, max_keys, ram_file)
    {db_options, Create, AutoRepair, MaxKeys, RamFile} = Options,

    %% Build dets options list
    BaseOpts = [
        {file, PathStr},
        {type, set},
        {keypos, 1}
    ],

    %% Add optional settings
    Opts1 = case Create of
        true -> [{access, read_write} | BaseOpts];
        false -> [{access, read} | BaseOpts]
    end,

    Opts2 = case AutoRepair of
        true -> [{repair, true} | Opts1];
        false -> [{repair, false} | Opts1]
    end,

    Opts3 = case MaxKeys of
        {some, Max} -> [{max_no_slots, Max} | Opts2];
        none -> Opts2
    end,

    Opts4 = case RamFile of
        true -> [{ram_file, true} | Opts3];
        false -> Opts3
    end,

    case dets:open_file(Name, Opts4) of
        {ok, Ref} ->
            {ok, Ref};
        {error, {file_error, _, enoent}} ->
            {error, db_not_found};
        {error, {file_error, _, Reason}} ->
            {error, {io_error, list_to_binary(io_lib:format("~p", [Reason]))}};
        {error, {bad_object_header, _}} ->
            {error, corrupted};
        {error, Reason} ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Close a dets table
-spec dets_close(atom()) -> {ok, nil} | {error, tuple()}.
dets_close(Name) ->
    case dets:close(Name) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Look up a key in dets
-spec dets_lookup(atom(), binary()) -> {ok, binary()} | {error, tuple()}.
dets_lookup(Name, Key) ->
    case dets:lookup(Name, Key) of
        [] ->
            {error, key_not_found};
        [{Key, Value}] ->
            {ok, Value};
        {error, Reason} ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Insert a key-value pair
-spec dets_insert(atom(), binary(), binary()) -> {ok, nil} | {error, tuple()}.
dets_insert(Name, Key, Value) ->
    case dets:insert(Name, {Key, Value}) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Delete a key
-spec dets_delete(atom(), binary()) -> {ok, nil} | {error, tuple()}.
dets_delete(Name, Key) ->
    case dets:delete(Name, Key) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Check if a key exists
-spec dets_member(atom(), binary()) -> {ok, boolean()} | {error, tuple()}.
dets_member(Name, Key) ->
    case dets:member(Name, Key) of
        true ->
            {ok, true};
        false ->
            {ok, false};
        {error, Reason} ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Sync table to disk
-spec dets_sync(atom()) -> {ok, nil} | {error, tuple()}.
dets_sync(Name) ->
    case dets:sync(Name) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Get all keys from the table
-spec dets_all_keys(atom()) -> {ok, list(binary())} | {error, tuple()}.
dets_all_keys(Name) ->
    try
        Keys = dets:foldl(fun({K, _V}, Acc) -> [K | Acc] end, [], Name),
        {ok, Keys}
    catch
        _:Reason ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Get the number of entries in the table
-spec dets_info_size(atom()) -> {ok, integer()} | {error, tuple()}.
dets_info_size(Name) ->
    case dets:info(Name, size) of
        undefined ->
            {error, closed};
        Size when is_integer(Size) ->
            {ok, Size};
        {error, Reason} ->
            {error, {other, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.
