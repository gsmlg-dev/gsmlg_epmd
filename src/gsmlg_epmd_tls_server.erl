%%% @doc TLS server for accepting incoming node connections
%%%
%%% This module implements a TLS server that:
%%% 1. Listens on a configured port for incoming TLS connections
%%% 2. Performs mutual TLS authentication with peer certificates
%%% 3. Validates group membership from certificate OU field
%%% 4. Exchanges cookies securely after authentication
%%% 5. Notifies the main EPMD module about discovered nodes
%%% @end
-module(gsmlg_epmd_tls_server).

-behaviour(gen_server).

%% API
-export([start_link/1,
         get_listen_port/0,
         notify_node_discovered/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2]).

-include_lib("gsmlg_epmd/src/gsmlg_epmd.hrl").

-define(SERVER, ?MODULE).
-define(ACCEPT_TIMEOUT, 60000).

-record(state, {
    listen_socket :: ssl:sslsocket() | undefined,
    port :: inet:port_number(),
    dist_port :: inet:port_number(),
    acceptor_pid :: pid() | undefined
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the TLS server
-spec start_link(inet:port_number()) -> {ok, pid()} | {error, term()}.
start_link(DistPort) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [DistPort], []).

%% @doc Get the port the TLS server is listening on
-spec get_listen_port() -> {ok, inet:port_number()} | {error, term()}.
get_listen_port() ->
    gen_server:call(?SERVER, get_listen_port).

%% @doc Notify about a newly discovered node (called by acceptor process)
-spec notify_node_discovered(map()) -> ok.
notify_node_discovered(NodeInfo) ->
    gen_server:cast(?SERVER, {node_discovered, NodeInfo}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([DistPort]) ->
    process_flag(trap_exit, true),

    case gsmlg_epmd_cert:load_config() of
        {ok, Config} ->
            Port = maps:get(port, Config),
            case start_listener(Port) of
                {ok, ListenSocket} ->
                    {ok, {_Addr, ActualPort}} = ssl:sockname(ListenSocket),
                    State = #state{
                        listen_socket = ListenSocket,
                        port = ActualPort,
                        dist_port = DistPort
                    },
                    %% Start acceptor process
                    self() ! start_acceptor,
                    ?LOG_INFO("TLS server listening on port ~p", [ActualPort]),
                    {ok, State};
                {error, Reason} ->
                    ?LOG_ERROR("Failed to start TLS listener: ~p", [Reason]),
                    {stop, {listener_failed, Reason}}
            end;
        {error, Reason} ->
            ?LOG_ERROR("Failed to load TLS config: ~p", [Reason]),
            {stop, {config_failed, Reason}}
    end.

handle_call(get_listen_port, _From, State) ->
    {reply, {ok, State#state.port}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({node_discovered, NodeInfo}, State) ->
    %% Notify the main EPMD module about discovered node
    case whereis(gsmlg_epmd_tls) of
        Pid when is_pid(Pid) ->
            gsmlg_epmd_tls:register_discovered_node(NodeInfo);
        _ ->
            ?LOG_WARNING("gsmlg_epmd_tls not running, cannot register node: ~p",
                        [maps:get(node, NodeInfo, unknown)])
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(start_acceptor, State) ->
    Pid = spawn_link(fun() -> acceptor_loop(State#state.listen_socket, State#state.dist_port) end),
    {noreply, State#state{acceptor_pid = Pid}};

handle_info({'EXIT', Pid, Reason}, State) when Pid =:= State#state.acceptor_pid ->
    ?LOG_WARNING("Acceptor process died: ~p, restarting", [Reason]),
    %% Restart acceptor
    self() ! start_acceptor,
    {noreply, State#state{acceptor_pid = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.listen_socket of
        undefined ->
            ok;
        Socket ->
            ssl:close(Socket)
    end,
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
%% Start TLS listener
start_listener(Port) ->
    case gsmlg_epmd_cert:get_server_opts() of
        {ok, TLSOpts} ->
            Opts = [{active, false},
                    {reuseaddr, true},
                    {mode, binary},
                    {packet, 0}] ++ TLSOpts,
            ssl:listen(Port, Opts);
        Error ->
            Error
    end.

%% @private
%% Acceptor loop - accepts incoming connections
acceptor_loop(ListenSocket, DistPort) ->
    case ssl:transport_accept(ListenSocket, ?ACCEPT_TIMEOUT) of
        {ok, Socket} ->
            %% Spawn handler for this connection
            spawn(fun() -> handle_connection(Socket, DistPort) end),
            %% Continue accepting
            acceptor_loop(ListenSocket, DistPort);
        {error, timeout} ->
            %% Normal timeout, continue accepting
            acceptor_loop(ListenSocket, DistPort);
        {error, Reason} ->
            ?LOG_ERROR("Accept failed: ~p", [Reason]),
            timer:sleep(1000),
            acceptor_loop(ListenSocket, DistPort)
    end.

%% @private
%% Handle individual TLS connection
handle_connection(Socket, DistPort) ->
    case ssl:handshake(Socket, 10000) of
        {ok, TLSSocket} ->
            ?LOG_INFO("TLS handshake successful", []),

            %% Get peer certificate info
            case ssl:peercert(TLSSocket) of
                {ok, PeerCert} ->
                    case gsmlg_epmd_cert:extract_group(PeerCert) of
                        {ok, PeerGroup} ->
                            ?LOG_INFO("Peer group: ~s", [PeerGroup]),

                            %% Exchange cookies
                            case gsmlg_epmd_cookie:exchange_cookies(TLSSocket, DistPort) of
                                {ok, NodeInfo} ->
                                    ?LOG_INFO("Cookie exchange successful with ~p",
                                            [maps:get(node, NodeInfo)]),

                                    %% Notify about discovered node
                                    notify_node_discovered(NodeInfo),

                                    ssl:close(TLSSocket);
                                {error, Reason} ->
                                    ?LOG_ERROR("Cookie exchange failed: ~p", [Reason]),
                                    ssl:close(TLSSocket)
                            end;
                        {error, Reason} ->
                            ?LOG_ERROR("Failed to extract group: ~p", [Reason]),
                            ssl:close(TLSSocket)
                    end;
                {error, no_peercert} ->
                    ?LOG_ERROR("No peer certificate", []),
                    ssl:close(TLSSocket)
            end;
        {error, Reason} ->
            ?LOG_ERROR("TLS handshake failed: ~p", [Reason]),
            ssl:close(Socket)
    end.
