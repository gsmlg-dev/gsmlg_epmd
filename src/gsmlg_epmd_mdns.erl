%%% @doc mDNS service discovery for EPMD nodes
%%%
%%% This module integrates with the mdns library to provide:
%%% 1. Service advertisement: Advertise local node as _epmd._tcp.local
%%% 2. Service discovery: Discover other nodes via mDNS
%%% 3. Auto-connection: Trigger TLS connections to discovered nodes
%%%
%%% The service name format is: _epmd._tcp.local
%%% TXT records contain: group, port, and version information
%%% @end
-module(gsmlg_epmd_mdns).

-behaviour(gen_server).

%% API
-export([start_link/2,
         stop/0,
         get_discovered_nodes/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2]).

-include_lib("gsmlg_epmd/src/gsmlg_epmd.hrl").

-define(SERVER, ?MODULE).
-define(SERVICE_TYPE, "_epmd._tcp").
-define(MDNS_DOMAIN, ".local").

-record(state, {
    tls_port :: inet:port_number(),
    dist_port :: inet:port_number(),
    group :: string() | undefined,
    discovered = #{} :: #{string() => map()},
    auto_connect :: boolean()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start mDNS service discovery
-spec start_link(inet:port_number(), inet:port_number()) ->
    {ok, pid()} | {error, term()}.
start_link(TLSPort, DistPort) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [TLSPort, DistPort], []).

%% @doc Stop mDNS service
-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER).

%% @doc Get list of discovered nodes
-spec get_discovered_nodes() -> #{string() => map()}.
get_discovered_nodes() ->
    gen_server:call(?SERVER, get_discovered_nodes).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([TLSPort, DistPort]) ->
    process_flag(trap_exit, true),

    %% Get configuration
    AutoConnect = get_config(auto_connect, "GSMLG_EPMD_AUTO_CONNECT", true),
    MDNSEnabled = get_config(mdns_enabled, "GSMLG_EPMD_MDNS_ENABLE", true),

    case MDNSEnabled of
        true ->
            %% Get group for advertisement
            Group = case gsmlg_epmd_cert:get_group() of
                {ok, G} -> G;
                undefined -> "default"
            end,

            %% Subscribe to mDNS advertisements
            mdns:subscribe(advertisement),

            %% Advertise ourselves
            case advertise_service(TLSPort, Group) of
                ok ->
                    ?LOG_INFO("mDNS service advertised: port=~p, group=~s",
                             [TLSPort, Group]),
                    State = #state{
                        tls_port = TLSPort,
                        dist_port = DistPort,
                        group = Group,
                        auto_connect = AutoConnect
                    },
                    {ok, State};
                {error, Reason} ->
                    ?LOG_ERROR("Failed to advertise mDNS service: ~p", [Reason]),
                    {stop, {advertisement_failed, Reason}}
            end;
        false ->
            ?LOG_INFO("mDNS discovery disabled", []),
            State = #state{
                tls_port = TLSPort,
                dist_port = DistPort,
                auto_connect = false
            },
            {ok, State}
    end.

handle_call(get_discovered_nodes, _From, State) ->
    {reply, State#state.discovered, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Handle mDNS advertisements (from gproc pub/sub)
handle_info({gproc_ps_event, advertisement, Advertisement}, State) ->
    case parse_advertisement(Advertisement) of
        {ok, NodeInfo} ->
            handle_discovered_node(NodeInfo, State);
        {error, Reason} ->
            ?LOG_WARNING("Failed to parse mDNS advertisement: ~p", [Reason]),
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Stop advertising
    mdns:unsubscribe(advertisement),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
advertise_service(Port, Group) ->
    %% Get node name
    NodeName = atom_to_list(node()),

    %% Create service advertisement
    %% The mdns library expects environment variables for configuration
    os:putenv("MDNS_SERVICE", ?SERVICE_TYPE),
    os:putenv("MDNS_ENVIRONMENT", Group),

    %% The mdns library will automatically advertise based on the node's
    %% distribution port. We use environment to encode the TLS port.
    application:set_env(mdns, service, ?SERVICE_TYPE),
    application:set_env(mdns, environment, Group),
    application:set_env(mdns, can_advertise, true),

    %% Start mdns application if not started
    case application:ensure_all_started(mdns) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
parse_advertisement(#{host := Host, port := Port, env := Env, node := Node} = Ad) ->
    %% Extract information from advertisement
    NodeInfo = #{
        host => Host,
        port => Port,
        group => Env,
        node => Node,
        discovered_at => erlang:system_time(second)
    },
    {ok, NodeInfo};
parse_advertisement(_) ->
    {error, invalid_advertisement_format}.

%% @private
handle_discovered_node(#{node := RemoteNode} = NodeInfo, State) ->
    %% Don't process our own advertisement
    case RemoteNode of
        _ when RemoteNode =:= node() ->
            {noreply, State};
        _ ->
            %% Check if we've already discovered this node
            Key = atom_to_list(RemoteNode),
            case maps:is_key(Key, State#state.discovered) of
                true ->
                    %% Already discovered
                    {noreply, State};
                false ->
                    %% New discovery
                    ?LOG_INFO("Discovered new node via mDNS: ~p", [NodeInfo]),

                    %% Check group match
                    case should_connect(NodeInfo, State) of
                        true ->
                            %% Attempt TLS connection
                            spawn(fun() -> connect_to_node(NodeInfo, State) end),
                            NewDiscovered = maps:put(Key, NodeInfo, State#state.discovered),
                            {noreply, State#state{discovered = NewDiscovered}};
                        false ->
                            ?LOG_INFO("Skipping connection to ~p (group mismatch or auto_connect disabled)",
                                     [RemoteNode]),
                            {noreply, State}
                    end
            end
    end.

%% @private
should_connect(#{group := PeerGroup}, #state{group = LocalGroup, auto_connect = AutoConnect}) ->
    AutoConnect andalso (LocalGroup =:= undefined orelse LocalGroup =:= PeerGroup).

%% @private
connect_to_node(#{host := Host, port := Port, node := Node} = NodeInfo, State) ->
    %% Convert host to string if needed
    HostStr = case Host of
        H when is_list(H) -> H;
        H when is_binary(H) -> binary_to_list(H);
        H when is_atom(H) -> atom_to_list(H)
    end,

    ?LOG_INFO("Attempting TLS connection to ~s:~p", [HostStr, Port]),

    %% Get TLS client options
    case gsmlg_epmd_cert:get_client_opts(HostStr) of
        {ok, TLSOpts} ->
            Opts = [{active, false}, {mode, binary}, {packet, 0}] ++ TLSOpts,

            case ssl:connect(HostStr, Port, Opts, 10000) of
                {ok, Socket} ->
                    ?LOG_INFO("TLS connection established with ~p", [Node]),

                    %% Exchange cookies
                    case gsmlg_epmd_cookie:exchange_cookies(Socket, State#state.dist_port) of
                        {ok, RemoteInfo} ->
                            ?LOG_INFO("Cookie exchange successful with ~p", [Node]),

                            %% Notify main EPMD module
                            case whereis(gsmlg_epmd_tls) of
                                Pid when is_pid(Pid) ->
                                    gsmlg_epmd_tls:register_discovered_node(RemoteInfo);
                                _ ->
                                    ok
                            end,

                            ssl:close(Socket);
                        {error, Reason} ->
                            ?LOG_ERROR("Cookie exchange failed with ~p: ~p", [Node, Reason]),
                            ssl:close(Socket)
                    end;
                {error, Reason} ->
                    ?LOG_ERROR("Failed to connect to ~s:~p - ~p", [HostStr, Port, Reason])
            end;
        {error, Reason} ->
            ?LOG_ERROR("Failed to get TLS client options: ~p", [Reason])
    end.

%% @private
get_config(Key, EnvVar, Default) ->
    case application:get_env(gsmlg_epmd, Key) of
        {ok, Value} ->
            Value;
        undefined ->
            case os:getenv(EnvVar) of
                false ->
                    Default;
                "true" ->
                    true;
                "false" ->
                    false;
                Value ->
                    Value
            end
    end.
