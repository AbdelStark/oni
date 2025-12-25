-module(gleam@uri).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/uri.gleam").
-export([parse/1, parse_query/1, percent_encode/1, query_to_string/1, percent_decode/1, path_segments/1, to_string/1, origin/1, merge/2]).
-export_type([uri/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

?MODULEDOC(
    " Utilities for working with URIs\n"
    "\n"
    " This module provides functions for working with URIs (for example, parsing\n"
    " URIs or encoding query strings). The functions in this module are implemented\n"
    " according to [RFC 3986](https://tools.ietf.org/html/rfc3986).\n"
    "\n"
    " Query encoding (Form encoding) is defined in the\n"
    " [W3C specification](https://www.w3.org/TR/html52/sec-forms.html#urlencoded-form-data).\n"
).

-type uri() :: {uri,
        gleam@option:option(binary()),
        gleam@option:option(binary()),
        gleam@option:option(binary()),
        gleam@option:option(integer()),
        binary(),
        gleam@option:option(binary()),
        gleam@option:option(binary())}.

-file("src/gleam/uri.gleam", 59).
?DOC(
    " Parses a compliant URI string into the `Uri` Type.\n"
    " If the string is not a valid URI string then an error is returned.\n"
    "\n"
    " The opposite operation is `uri.to_string`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " parse(\"https://example.com:1234/a/b?query=true#fragment\")\n"
    " // -> Ok(\n"
    " //   Uri(\n"
    " //     scheme: Some(\"https\"),\n"
    " //     userinfo: None,\n"
    " //     host: Some(\"example.com\"),\n"
    " //     port: Some(1234),\n"
    " //     path: \"/a/b\",\n"
    " //     query: Some(\"query=true\"),\n"
    " //     fragment: Some(\"fragment\")\n"
    " //   )\n"
    " // )\n"
    " ```\n"
).
-spec parse(binary()) -> {ok, uri()} | {error, nil}.
parse(Uri_string) ->
    gleam_stdlib:uri_parse(Uri_string).

-file("src/gleam/uri.gleam", 211).
?DOC(
    " Parses an urlencoded query string into a list of key value pairs.\n"
    " Returns an error for invalid encoding.\n"
    "\n"
    " The opposite operation is `uri.query_to_string`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " parse_query(\"a=1&b=2\")\n"
    " // -> Ok([#(\"a\", \"1\"), #(\"b\", \"2\")])\n"
    " ```\n"
).
-spec parse_query(binary()) -> {ok, list({binary(), binary()})} | {error, nil}.
parse_query(Query) ->
    gleam_stdlib:parse_query(Query).

-file("src/gleam/uri.gleam", 255).
?DOC(
    " Encodes a string into a percent encoded representation.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " percent_encode(\"100% great\")\n"
    " // -> \"100%25%20great\"\n"
    " ```\n"
).
-spec percent_encode(binary()) -> binary().
percent_encode(Value) ->
    gleam_stdlib:percent_encode(Value).

-file("src/gleam/uri.gleam", 238).
-spec query_pair({binary(), binary()}) -> gleam@string_builder:string_builder().
query_pair(Pair) ->
    gleam@string_builder:from_strings(
        [percent_encode(erlang:element(1, Pair)),
            <<"="/utf8>>,
            percent_encode(erlang:element(2, Pair))]
    ).

-file("src/gleam/uri.gleam", 230).
?DOC(
    " Encodes a list of key value pairs as a URI query string.\n"
    "\n"
    " The opposite operation is `uri.parse_query`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " query_to_string([#(\"a\", \"1\"), #(\"b\", \"2\")])\n"
    " // -> \"a=1&b=2\"\n"
    " ```\n"
).
-spec query_to_string(list({binary(), binary()})) -> binary().
query_to_string(Query) ->
    _pipe = Query,
    _pipe@1 = gleam@list:map(_pipe, fun query_pair/1),
    _pipe@2 = gleam@list:intersperse(
        _pipe@1,
        gleam@string_builder:from_string(<<"&"/utf8>>)
    ),
    _pipe@3 = gleam@string_builder:concat(_pipe@2),
    gleam@string_builder:to_string(_pipe@3).

-file("src/gleam/uri.gleam", 272).
?DOC(
    " Decodes a percent encoded string.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " percent_decode(\"100%25+great\")\n"
    " // -> Ok(\"100% great\")\n"
    " ```\n"
).
-spec percent_decode(binary()) -> {ok, binary()} | {error, nil}.
percent_decode(Value) ->
    gleam_stdlib:percent_decode(Value).

-file("src/gleam/uri.gleam", 280).
-spec do_remove_dot_segments(list(binary()), list(binary())) -> list(binary()).
do_remove_dot_segments(Input, Accumulator) ->
    case Input of
        [] ->
            gleam@list:reverse(Accumulator);

        [Segment | Rest] ->
            Accumulator@5 = case {Segment, Accumulator} of
                {<<""/utf8>>, Accumulator@1} ->
                    Accumulator@1;

                {<<"."/utf8>>, Accumulator@2} ->
                    Accumulator@2;

                {<<".."/utf8>>, []} ->
                    [];

                {<<".."/utf8>>, [_ | Accumulator@3]} ->
                    Accumulator@3;

                {Segment@1, Accumulator@4} ->
                    [Segment@1 | Accumulator@4]
            end,
            do_remove_dot_segments(Rest, Accumulator@5)
    end.

-file("src/gleam/uri.gleam", 299).
-spec remove_dot_segments(list(binary())) -> list(binary()).
remove_dot_segments(Input) ->
    do_remove_dot_segments(Input, []).

-file("src/gleam/uri.gleam", 315).
?DOC(
    " Splits the path section of a URI into it's constituent segments.\n"
    "\n"
    " Removes empty segments and resolves dot-segments as specified in\n"
    " [section 5.2](https://www.ietf.org/rfc/rfc3986.html#section-5.2) of the RFC.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " path_segments(\"/users/1\")\n"
    " // -> [\"users\" ,\"1\"]\n"
    " ```\n"
).
-spec path_segments(binary()) -> list(binary()).
path_segments(Path) ->
    remove_dot_segments(gleam@string:split(Path, <<"/"/utf8>>)).

-file("src/gleam/uri.gleam", 331).
?DOC(
    " Encodes a `Uri` value as a URI string.\n"
    "\n"
    " The opposite operation is `uri.parse`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " let uri = Uri(Some(\"http\"), None, Some(\"example.com\"), ...)\n"
    " to_string(uri)\n"
    " // -> \"http://example.com\"\n"
    " ```\n"
).
-spec to_string(uri()) -> binary().
to_string(Uri) ->
    Parts = case erlang:element(8, Uri) of
        {some, Fragment} ->
            [<<"#"/utf8>>, Fragment];

        _ ->
            []
    end,
    Parts@1 = case erlang:element(7, Uri) of
        {some, Query} ->
            [<<"?"/utf8>>, Query | Parts];

        _ ->
            Parts
    end,
    Parts@2 = [erlang:element(6, Uri) | Parts@1],
    Parts@3 = case {erlang:element(4, Uri),
        gleam@string:starts_with(erlang:element(6, Uri), <<"/"/utf8>>)} of
        {{some, Host}, false} when Host =/= <<""/utf8>> ->
            [<<"/"/utf8>> | Parts@2];

        {_, _} ->
            Parts@2
    end,
    Parts@4 = case {erlang:element(4, Uri), erlang:element(5, Uri)} of
        {{some, _}, {some, Port}} ->
            [<<":"/utf8>>, gleam@int:to_string(Port) | Parts@3];

        {_, _} ->
            Parts@3
    end,
    Parts@5 = case {erlang:element(2, Uri),
        erlang:element(3, Uri),
        erlang:element(4, Uri)} of
        {{some, S}, {some, U}, {some, H}} ->
            [S, <<"://"/utf8>>, U, <<"@"/utf8>>, H | Parts@4];

        {{some, S@1}, none, {some, H@1}} ->
            [S@1, <<"://"/utf8>>, H@1 | Parts@4];

        {{some, S@2}, {some, _}, none} ->
            [S@2, <<":"/utf8>> | Parts@4];

        {{some, S@2}, none, none} ->
            [S@2, <<":"/utf8>> | Parts@4];

        {none, none, {some, H@2}} ->
            [<<"//"/utf8>>, H@2 | Parts@4];

        {_, _, _} ->
            Parts@4
    end,
    gleam@string:concat(Parts@5).

-file("src/gleam/uri.gleam", 375).
?DOC(
    " Fetches the origin of a URI.\n"
    "\n"
    " Returns the origin of a uri as defined in\n"
    " [RFC 6454](https://tools.ietf.org/html/rfc6454)\n"
    "\n"
    " The supported URI schemes are `http` and `https`.\n"
    " URLs without a scheme will return `Error`.\n"
    "\n"
    " ## Examples\n"
    "\n"
    " ```gleam\n"
    " let assert Ok(uri) = parse(\"http://example.com/path?foo#bar\")\n"
    " origin(uri)\n"
    " // -> Ok(\"http://example.com\")\n"
    " ```\n"
).
-spec origin(uri()) -> {ok, binary()} | {error, nil}.
origin(Uri) ->
    {uri, Scheme, _, Host, Port, _, _, _} = Uri,
    case Scheme of
        {some, <<"https"/utf8>>} when Port =:= {some, 443} ->
            Origin = {uri, Scheme, none, Host, none, <<""/utf8>>, none, none},
            {ok, to_string(Origin)};

        {some, <<"http"/utf8>>} when Port =:= {some, 80} ->
            Origin@1 = {uri, Scheme, none, Host, none, <<""/utf8>>, none, none},
            {ok, to_string(Origin@1)};

        {some, S} when (S =:= <<"http"/utf8>>) orelse (S =:= <<"https"/utf8>>) ->
            Origin@2 = {uri, Scheme, none, Host, Port, <<""/utf8>>, none, none},
            {ok, to_string(Origin@2)};

        _ ->
            {error, nil}
    end.

-file("src/gleam/uri.gleam", 394).
-spec drop_last(list(FBM)) -> list(FBM).
drop_last(Elements) ->
    gleam@list:take(Elements, gleam@list:length(Elements) - 1).

-file("src/gleam/uri.gleam", 398).
-spec join_segments(list(binary())) -> binary().
join_segments(Segments) ->
    gleam@string:join([<<""/utf8>> | Segments], <<"/"/utf8>>).

-file("src/gleam/uri.gleam", 408).
?DOC(
    " Resolves a URI with respect to the given base URI.\n"
    "\n"
    " The base URI must be an absolute URI or this function will return an error.\n"
    " The algorithm for merging uris is described in\n"
    " [RFC 3986](https://tools.ietf.org/html/rfc3986#section-5.2).\n"
).
-spec merge(uri(), uri()) -> {ok, uri()} | {error, nil}.
merge(Base, Relative) ->
    case Base of
        {uri, {some, _}, _, {some, _}, _, _, _, _} ->
            case Relative of
                {uri, _, _, {some, _}, _, _, _, _} ->
                    Path = begin
                        _pipe = gleam@string:split(
                            erlang:element(6, Relative),
                            <<"/"/utf8>>
                        ),
                        _pipe@1 = remove_dot_segments(_pipe),
                        join_segments(_pipe@1)
                    end,
                    Resolved = {uri,
                        gleam@option:'or'(
                            erlang:element(2, Relative),
                            erlang:element(2, Base)
                        ),
                        none,
                        erlang:element(4, Relative),
                        gleam@option:'or'(
                            erlang:element(5, Relative),
                            erlang:element(5, Base)
                        ),
                        Path,
                        erlang:element(7, Relative),
                        erlang:element(8, Relative)},
                    {ok, Resolved};

                _ ->
                    {New_path, New_query} = case erlang:element(6, Relative) of
                        <<""/utf8>> ->
                            {erlang:element(6, Base),
                                gleam@option:'or'(
                                    erlang:element(7, Relative),
                                    erlang:element(7, Base)
                                )};

                        _ ->
                            Path_segments = case gleam@string:starts_with(
                                erlang:element(6, Relative),
                                <<"/"/utf8>>
                            ) of
                                true ->
                                    gleam@string:split(
                                        erlang:element(6, Relative),
                                        <<"/"/utf8>>
                                    );

                                false ->
                                    _pipe@2 = gleam@string:split(
                                        erlang:element(6, Base),
                                        <<"/"/utf8>>
                                    ),
                                    _pipe@3 = drop_last(_pipe@2),
                                    gleam@list:append(
                                        _pipe@3,
                                        gleam@string:split(
                                            erlang:element(6, Relative),
                                            <<"/"/utf8>>
                                        )
                                    )
                            end,
                            Path@1 = begin
                                _pipe@4 = Path_segments,
                                _pipe@5 = remove_dot_segments(_pipe@4),
                                join_segments(_pipe@5)
                            end,
                            {Path@1, erlang:element(7, Relative)}
                    end,
                    Resolved@1 = {uri,
                        erlang:element(2, Base),
                        none,
                        erlang:element(4, Base),
                        erlang:element(5, Base),
                        New_path,
                        New_query,
                        erlang:element(8, Relative)},
                    {ok, Resolved@1}
            end;

        _ ->
            {error, nil}
    end.
