%%% oni_listener - TCP listener for inbound peer connections
%%%
%%% Listens for incoming P2P connections and spawns handlers.

-module(oni_listener).
-behaviour(gen_server).

-export([start_link/1]).
-export([get_info/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    listen_socket :: gen_tcp:socket() | undefined,
    port :: non_neg_integer(),
    accept_count :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% Get listener info
-spec get_info() -> map().
get_info() ->
    gen_server:call(?MODULE, get_info).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Config) ->
    Port = maps:get(p2p_port, Config, 8333),

    Options = [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 128}
    ],

    case gen_tcp:listen(Port, Options) of
        {ok, ListenSocket} ->
            io:format("[oni_listener] Listening on port ~p~n", [Port]),
            State = #state{
                listen_socket = ListenSocket,
                port = Port,
                accept_count = 0
            },
            %% Start accepting connections
            self() ! accept,
            {ok, State};
        {error, eaddrinuse} ->
            io:format("[oni_listener] Port ~p already in use, starting without listener~n", [Port]),
            {ok, #state{port = Port, accept_count = 0}};
        {error, Reason} ->
            io:format("[oni_listener] Failed to listen on port ~p: ~p~n", [Port, Reason]),
            {ok, #state{port = Port, accept_count = 0}}
    end.

handle_call(get_info, _From, State) ->
    Info = #{
        port => State#state.port,
        listening => State#state.listen_socket =/= undefined,
        accept_count => State#state.accept_count
    },
    {reply, Info, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(accept, State = #state{listen_socket = undefined}) ->
    %% No socket, don't accept
    {noreply, State};

handle_info(accept, State = #state{listen_socket = ListenSocket}) ->
    %% Accept in a separate process to not block the gen_server
    Self = self(),
    spawn_link(fun() ->
        case gen_tcp:accept(ListenSocket, 30000) of
            {ok, Socket} ->
                Self ! {accepted, Socket};
            {error, timeout} ->
                Self ! accept_timeout;
            {error, closed} ->
                Self ! listener_closed;
            {error, Reason} ->
                Self ! {accept_error, Reason}
        end
    end),
    {noreply, State};

handle_info({accepted, Socket}, State) ->
    %% Get peer address
    case inet:peername(Socket) of
        {ok, {IpAddr, Port}} ->
            io:format("[oni_listener] Accepted connection from ~p:~p~n", [IpAddr, Port]),
            %% Start a peer handler for this inbound connection
            case oni_conn_sup:start_peer(IpAddr, Port) of
                {ok, _Pid} ->
                    %% Transfer socket ownership to the peer
                    gen_tcp:controlling_process(Socket, _Pid);
                {error, _} ->
                    gen_tcp:close(Socket)
            end;
        {error, _} ->
            gen_tcp:close(Socket)
    end,
    %% Continue accepting
    self() ! accept,
    NewState = State#state{accept_count = State#state.accept_count + 1},
    {noreply, NewState};

handle_info(accept_timeout, State) ->
    %% Timeout, try again
    self() ! accept,
    {noreply, State};

handle_info(listener_closed, State) ->
    io:format("[oni_listener] Listener socket closed~n"),
    {noreply, State#state{listen_socket = undefined}};

handle_info({accept_error, Reason}, State) ->
    io:format("[oni_listener] Accept error: ~p~n", [Reason]),
    %% Try again after a delay
    erlang:send_after(1000, self(), accept),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.listen_socket of
        undefined -> ok;
        Socket -> gen_tcp:close(Socket)
    end,
    ok.
