%%% @doc Main EPMD module with TLS-based trust groups and mDNS discovery
%%%
%%% This module implements the EPMD callback behavior and coordinates:
%%% - Certificate-based authentication and group membership
%%% - TLS server for incoming connections
%%% - mDNS service discovery and advertisement
%%% - Dynamic cookie exchange
%%% - Automatic mesh network formation within trust groups
%%%
%%% Usage: Set in vm.args with `-epmd_module gsmlg_epmd_tls`
%%% @end
-module(gsmlg_epmd_tls).

-behaviour(gen_server).

%% EPMD callbacks
-export([start_link/0,
         register_node/3,
         address_please/3,
         port_please/2,
         listen_port_please/2,
         names/1]).

%% API
-export([register_discovered_node/1,
         list_discovered_nodes/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2]).

-include_lib("gsmlg_epmd/src/gsmlg_epmd.hrl").

-define(SERVER, ?MODULE).

-ifdef(OTP_VERSION).
-if(?OTP_VERSION < 23).
-define(ERL_DIST_VER, 5).  % OTP-22 or older
-else.
-define(ERL_DIST_VER, 6).  % OTP-23 or newer
-endif.
-else.
-define(ERL_DIST_VER, 5).  % OTP-22 or older
-endif.

-record(state, {
    dist_port :: inet:port_number(),
    tls_port :: inet:port_number() | undefined,
    nodes = #{} :: #{atom() => map()}
}).

%%====================================================================
%% EPMD Callbacks
%%====================================================================

%% @doc Start the EPMD replacement
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register this node with the EPMD replacement
-spec register_node(Name, Port, Family) -> {ok, CreationId} when
      Name       :: atom(),
      Port       :: inet:port_number(),
      Family     :: atom(),
      CreationId :: 1..3.
register_node(_Name, Port, _Family) ->
    gen_server:call(?SERVER, {register_node, Port}, infinity),
    {ok, rand:uniform(3)}.

%% @doc Request port of a node
-spec port_please(Name, Host) -> {port, Port, Version} | noport when
      Name    :: atom(),
      Host    :: inet:hostname() | inet:ip_address(),
      Port    :: inet:port_number(),
      Version :: 5 | 6.
port_please(Name, Host) ->
    case gen_server:call(?SERVER, {port_please, Name, Host}, infinity) of
        {ok, Port} ->
            {port, Port, ?ERL_DIST_VER};
        {error, noport} ->
            %% Fallback to environment variables for compatibility
            case os:getenv("EPMDLESS_REMSH_PORT") of
                false ->
                    case os:getenv("ERL_DIST_PORT") of
                        false ->
                            noport;
                        PortString ->
                            {port, list_to_integer(PortString), ?ERL_DIST_VER}
                    end;
                RemotePort ->
                    {port, list_to_integer(RemotePort), ?ERL_DIST_VER}
            end
    end.

%% @doc Resolve the Host to an IP address
-spec address_please(Name, Host, AddressFamily) -> Success | {error, term()} when
      Name :: atom(),
      Host :: string() | inet:ip_address(),
      AddressFamily :: inet | inet6 | local,
      Port :: non_neg_integer(),
      Version :: non_neg_integer(),
      Success :: {ok, inet:ip_address(), Port, Version}.
address_please(Name, Host, AddressFamily) ->
    case inet:getaddr(Host, AddressFamily) of
        {ok, Address} ->
            case port_please(Name, Address) of
                {port, Port, Version} ->
                    {ok, Address, Port, Version};
                noport ->
                    {error, noport}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Returns the port the local node should listen on
listen_port_please(Name, Host) ->
    gen_server:call(?SERVER, {listen_port, Name, Host}, infinity).

%% @doc List nodes (not used in this implementation)
names(_Hostname) ->
    {error, address}.

%%====================================================================
%% API
%%====================================================================

%% @doc Register a node discovered via mDNS or TLS connection
-spec register_discovered_node(map()) -> ok.
register_discovered_node(NodeInfo) ->
    gen_server:cast(?SERVER, {register_discovered_node, NodeInfo}).

%% @doc List all discovered nodes
-spec list_discovered_nodes() -> #{atom() => map()}.
list_discovered_nodes() ->
    gen_server:call(?SERVER, list_discovered_nodes).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),

    %% Get distribution port from environment
    Port = case os:getenv("ERL_DIST_PORT") of
        false -> 0;
        PortString -> list_to_integer(PortString)
    end,

    ?LOG_INFO("gsmlg_epmd_tls starting with dist_port=~p", [Port]),

    {ok, #state{dist_port = Port}}.

handle_call({register_node, Port}, _From, State) ->
    ?LOG_INFO("Registering node with dist_port=~p", [Port]),

    %% Update distribution port
    NewState = State#state{dist_port = Port},

    %% Start TLS server and mDNS services if not already started
    case start_services(Port) of
        {ok, TLSPort} ->
            {reply, ok, NewState#state{tls_port = TLSPort}};
        {error, Reason} ->
            ?LOG_ERROR("Failed to start services: ~p", [Reason]),
            {reply, ok, NewState}  %% Don't fail node startup
    end;

handle_call({port_please, Name, _Host}, _From, State) ->
    %% Look up node in discovered nodes
    Reply = case maps:find(Name, State#state.nodes) of
        {ok, #{dist_port := Port}} ->
            {ok, Port};
        error ->
            {error, noport}
    end,
    {reply, Reply, State};

handle_call({listen_port, _Name, _Host}, _From, State) ->
    {reply, {ok, State#state.dist_port}, State};

handle_call(list_discovered_nodes, _From, State) ->
    {reply, State#state.nodes, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({register_discovered_node, NodeInfo}, State) ->
    #{node := Node, dist_port := DistPort} = NodeInfo,

    ?LOG_INFO("Registering discovered node: ~p (port ~p)", [Node, DistPort]),

    %% Add to nodes map
    NewNodes = maps:put(Node, NodeInfo, State#state.nodes),

    {noreply, State#state{nodes = NewNodes}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
%% Start TLS server and mDNS discovery
start_services(DistPort) ->
    %% Start TLS server
    case supervisor:start_child(gsmlg_epmd_sup, tls_server_spec(DistPort)) of
        {ok, _Pid} ->
            %% Get the actual TLS port
            case gsmlg_epmd_tls_server:get_listen_port() of
                {ok, TLSPort} ->
                    ?LOG_INFO("TLS server started on port ~p", [TLSPort]),

                    %% Start mDNS discovery
                    case supervisor:start_child(gsmlg_epmd_sup, mdns_spec(TLSPort, DistPort)) of
                        {ok, _} ->
                            ?LOG_INFO("mDNS discovery started", []),
                            {ok, TLSPort};
                        {error, Reason} ->
                            ?LOG_WARNING("Failed to start mDNS: ~p", [Reason]),
                            {ok, TLSPort}  %% Continue without mDNS
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, {already_started, _}} ->
            %% Already started, get port
            case gsmlg_epmd_tls_server:get_listen_port() of
                {ok, TLSPort} ->
                    {ok, TLSPort};
                Error ->
                    Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
tls_server_spec(DistPort) ->
    #{
        id => gsmlg_epmd_tls_server,
        start => {gsmlg_epmd_tls_server, start_link, [DistPort]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [gsmlg_epmd_tls_server]
    }.

%% @private
mdns_spec(TLSPort, DistPort) ->
    #{
        id => gsmlg_epmd_mdns,
        start => {gsmlg_epmd_mdns, start_link, [TLSPort, DistPort]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [gsmlg_epmd_mdns]
    }.
