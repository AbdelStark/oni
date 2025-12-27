%%% oni_addr_manager - Peer address management
%%%
%%% Maintains a database of known peer addresses for peer discovery.

-module(oni_addr_manager).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    add_addr/2,
    get_addrs/1,
    mark_good/1,
    mark_attempted/1,
    get_random_addr/0,
    handle_addr/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(addr_entry, {
    key :: binary(),
    ip :: tuple(),
    port :: non_neg_integer(),
    services :: non_neg_integer(),
    last_success :: non_neg_integer(),
    last_attempt :: non_neg_integer(),
    attempts :: non_neg_integer()
}).

-record(state, {
    addrs :: ets:tid(),
    tried :: ets:tid()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Add an address to the database
-spec add_addr(tuple(), non_neg_integer()) -> ok.
add_addr(IpAddr, Port) ->
    gen_server:cast(?MODULE, {add_addr, IpAddr, Port, 0}).

%% Get addresses for relay
-spec get_addrs(non_neg_integer()) -> [tuple()].
get_addrs(Max) ->
    gen_server:call(?MODULE, {get_addrs, Max}).

%% Mark an address as successfully connected
-spec mark_good(binary()) -> ok.
mark_good(Key) ->
    gen_server:cast(?MODULE, {mark_good, Key}).

%% Mark an address as attempted
-spec mark_attempted(binary()) -> ok.
mark_attempted(Key) ->
    gen_server:cast(?MODULE, {mark_attempted, Key}).

%% Get a random address for connection
-spec get_random_addr() -> {ok, tuple(), non_neg_integer()} | {error, no_addrs}.
get_random_addr() ->
    gen_server:call(?MODULE, get_random_addr).

%% Handle incoming addr message
handle_addr(Payload) ->
    gen_server:cast(?MODULE, {handle_addr, Payload}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(_Config) ->
    Addrs = ets:new(addrs, [set, {keypos, 2}]),
    Tried = ets:new(tried, [set]),

    State = #state{
        addrs = Addrs,
        tried = Tried
    },

    io:format("[oni_addr_manager] Initialized~n"),
    {ok, State}.

handle_call({get_addrs, Max}, _From, State) ->
    Entries = ets:tab2list(State#state.addrs),
    Addrs = lists:sublist(
        [{E#addr_entry.ip, E#addr_entry.port} || E <- Entries],
        Max
    ),
    {reply, Addrs, State};

handle_call(get_random_addr, _From, State) ->
    case ets:first(State#state.addrs) of
        '$end_of_table' ->
            {reply, {error, no_addrs}, State};
        Key ->
            [Entry] = ets:lookup(State#state.addrs, Key),
            {reply, {ok, Entry#addr_entry.ip, Entry#addr_entry.port}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({add_addr, IpAddr, Port, Services}, State) ->
    Key = addr_key(IpAddr, Port),
    Entry = #addr_entry{
        key = Key,
        ip = IpAddr,
        port = Port,
        services = Services,
        last_success = 0,
        last_attempt = 0,
        attempts = 0
    },
    ets:insert(State#state.addrs, Entry),
    {noreply, State};

handle_cast({mark_good, Key}, State) ->
    case ets:lookup(State#state.addrs, Key) of
        [Entry] ->
            Updated = Entry#addr_entry{
                last_success = erlang:system_time(second),
                attempts = 0
            },
            ets:insert(State#state.addrs, Updated);
        [] ->
            ok
    end,
    {noreply, State};

handle_cast({mark_attempted, Key}, State) ->
    case ets:lookup(State#state.addrs, Key) of
        [Entry] ->
            Updated = Entry#addr_entry{
                last_attempt = erlang:system_time(second),
                attempts = Entry#addr_entry.attempts + 1
            },
            ets:insert(State#state.addrs, Updated);
        [] ->
            ok
    end,
    {noreply, State};

handle_cast({handle_addr, Payload}, State) ->
    %% Parse addr message and add entries
    parse_and_add_addrs(Payload, State),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

addr_key(IpAddr, Port) ->
    IpBin = case IpAddr of
        {A, B, C, D} -> <<A:8, B:8, C:8, D:8>>;
        Tuple when tuple_size(Tuple) =:= 8 ->
            list_to_binary([<<X:16>> || X <- tuple_to_list(Tuple)])
    end,
    <<IpBin/binary, Port:16>>.

parse_and_add_addrs(<<Count:8, Rest/binary>>, State) when Count =< 1000 ->
    parse_addr_entries(Rest, Count, State);
parse_and_add_addrs(_, _) ->
    ok.

parse_addr_entries(_, 0, _) ->
    ok;
parse_addr_entries(<<_Time:32/little, _Services:64/little,
                     Ip:16/binary, Port:16/big, Rest/binary>>, N, State) when N > 0 ->
    case parse_ip(Ip) of
        {ok, IpAddr} ->
            Key = addr_key(IpAddr, Port),
            Entry = #addr_entry{
                key = Key,
                ip = IpAddr,
                port = Port,
                services = 0,
                last_success = 0,
                last_attempt = 0,
                attempts = 0
            },
            ets:insert(State#state.addrs, Entry);
        {error, _} ->
            ok
    end,
    parse_addr_entries(Rest, N - 1, State);
parse_addr_entries(_, _, _) ->
    ok.

parse_ip(<<0:80, 16#FF:8, 16#FF:8, A:8, B:8, C:8, D:8>>) ->
    {ok, {A, B, C, D}};
parse_ip(_) ->
    {error, unsupported}.
