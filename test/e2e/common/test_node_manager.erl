%%% @doc Test Node Manager
%%%
%%% Manages test node lifecycle for E2E tests. Handles starting, stopping,
%%% and monitoring Erlang nodes configured for different EPMD modes.
%%%
%%% Supports both OTP 25+ (peer module) and OTP 21-24 (slave module fallback).
%%%
%%% @end
-module(test_node_manager).

-export([
    start_node/1,
    start_node/2,
    stop_node/1,
    stop_all_nodes/1,
    get_node_pid/1,
    wait_for_node/2,
    allocate_test_ports/1
]).

-define(DEFAULT_TIMEOUT, 30000).
-define(EPHEMERAL_PORT_MIN, 49152).
-define(EPHEMERAL_PORT_MAX, 65535).

-type node_config() :: #{
    name := atom(),
    mode := tls | static | variable,
    port := pos_integer(),
    cookie => atom(),
    cert_path => string(),
    key_path => string(),
    ca_cert_path => string(),
    group => string(),
    code_paths => [string()],
    extra_args => [string()],
    env => [{string(), string()}]
}.

-type node_ref() :: #{
    name := atom(),
    pid := pid() | undefined,
    peer := pid() | undefined,
    port := pos_integer()
}.

-export_type([node_config/0, node_ref/0]).

%% @doc Start a node with the given configuration.
%% Uses peer module on OTP 25+, falls back to slave on earlier versions.
-spec start_node(node_config()) -> {ok, node_ref()} | {error, term()}.
start_node(Config) ->
    start_node(Config, ?DEFAULT_TIMEOUT).

%% @doc Start a node with custom timeout.
-spec start_node(node_config(), timeout()) -> {ok, node_ref()} | {error, term()}.
start_node(Config, Timeout) ->
    Name = maps:get(name, Config),
    Mode = maps:get(mode, Config),
    Port = maps:get(port, Config),

    Args = build_args(Config),
    Env = build_env(Config),

    case otp_version() of
        V when V >= 25 ->
            start_with_peer(Name, Args, Env, Port, Timeout);
        _ ->
            start_with_slave(Name, Mode, Args, Env, Port, Timeout)
    end.

%% @doc Stop a running node.
-spec stop_node(node_ref() | atom()) -> ok | {error, term()}.
stop_node(#{name := Name, peer := Peer}) when Peer =/= undefined ->
    case otp_version() of
        V when V >= 25 ->
            catch peer:stop(Peer),
            wait_for_node_down(Name, 5000);
        _ ->
            stop_node(Name)
    end;
stop_node(#{name := Name}) ->
    stop_node(Name);
stop_node(Name) when is_atom(Name) ->
    case net_adm:ping(Name) of
        pong ->
            catch rpc:call(Name, erlang, halt, [0]),
            wait_for_node_down(Name, 5000);
        pang ->
            ok
    end.

%% @doc Stop all nodes in a list.
-spec stop_all_nodes([node_ref()]) -> ok.
stop_all_nodes(Nodes) ->
    lists:foreach(fun stop_node/1, Nodes),
    ok.

%% @doc Get the process ID for a running node.
-spec get_node_pid(node_ref() | atom()) -> {ok, pid()} | {error, not_running}.
get_node_pid(#{name := Name}) ->
    get_node_pid(Name);
get_node_pid(Name) when is_atom(Name) ->
    case rpc:call(Name, erlang, whereis, [init], 5000) of
        Pid when is_pid(Pid) -> {ok, Pid};
        _ -> {error, not_running}
    end.

%% @doc Wait for a node to become available.
-spec wait_for_node(atom(), timeout()) -> ok | {error, timeout}.
wait_for_node(Name, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_node_loop(Name, Deadline).

%% @doc Allocate N unique ports from the ephemeral range.
%% Returns ports that are currently not in use.
-spec allocate_test_ports(pos_integer()) -> [pos_integer()].
allocate_test_ports(N) ->
    allocate_ports(N, []).

%%% Internal functions

-spec otp_version() -> pos_integer().
otp_version() ->
    list_to_integer(erlang:system_info(otp_release)).

-spec start_with_peer(atom(), [string()], [{string(), string()}], pos_integer(), timeout()) ->
    {ok, node_ref()} | {error, term()}.
start_with_peer(Name, Args, Env, Port, Timeout) ->
    PeerOpts = #{
        name => Name,
        args => Args,
        env => Env,
        connection => standard_io,
        wait_boot => Timeout
    },
    case peer:start(PeerOpts) of
        {ok, Peer, Node} ->
            {ok, #{name => Node, peer => Peer, pid => undefined, port => Port}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_with_slave(atom(), atom(), [string()], [{string(), string()}], pos_integer(), timeout()) ->
    {ok, node_ref()} | {error, term()}.
start_with_slave(Name, _Mode, Args, Env, Port, Timeout) ->
    %% Set environment variables before starting
    lists:foreach(fun({K, V}) -> os:putenv(K, V) end, Env),

    Host = get_host(),
    ArgsStr = string:join(Args, " "),

    case slave:start(Host, Name, ArgsStr) of
        {ok, Node} ->
            case wait_for_node(Node, Timeout) of
                ok ->
                    {ok, #{name => Node, peer => undefined, pid => undefined, port => Port}};
                {error, timeout} ->
                    catch slave:stop(Node),
                    {error, {start_timeout, Node}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec get_host() -> atom().
get_host() ->
    [_, Host] = string:split(atom_to_list(node()), "@"),
    list_to_atom(Host).

-spec build_args(node_config()) -> [string()].
build_args(Config) ->
    Mode = maps:get(mode, Config),
    Port = maps:get(port, Config),
    CodePaths = maps:get(code_paths, Config, []),
    ExtraArgs = maps:get(extra_args, Config, []),

    BaseArgs = [
        "-start_epmd", "false",
        "-epmd_module", atom_to_list(mode_to_module(Mode)),
        "-erl_epmd_port", integer_to_list(Port),
        "-kernel", "inet_dist_listen_min", integer_to_list(Port),
        "-kernel", "inet_dist_listen_max", integer_to_list(Port)
    ],

    CookieArgs = case maps:get(cookie, Config, undefined) of
        undefined -> [];
        Cookie -> ["-setcookie", atom_to_list(Cookie)]
    end,

    PathArgs = lists:flatmap(fun(P) -> ["-pa", P] end, CodePaths),

    TlsArgs = case Mode of
        tls -> build_tls_args(Config);
        _ -> []
    end,

    BaseArgs ++ CookieArgs ++ PathArgs ++ TlsArgs ++ ExtraArgs.

-spec build_tls_args(node_config()) -> [string()].
build_tls_args(Config) ->
    case maps:get(ssl_dist_optfile, Config, undefined) of
        undefined -> [];
        OptFile -> ["-proto_dist", "inet_tls", "-ssl_dist_optfile", OptFile]
    end.

-spec build_env(node_config()) -> [{string(), string()}].
build_env(Config) ->
    Mode = maps:get(mode, Config),
    Port = maps:get(port, Config),

    BaseEnv = [
        {"ERL_DIST_PORT", integer_to_list(Port)}
    ],

    TlsEnv = case Mode of
        tls ->
            CertPath = maps:get(cert_path, Config, ""),
            KeyPath = maps:get(key_path, Config, ""),
            CaPath = maps:get(ca_cert_path, Config, ""),
            Group = maps:get(group, Config, ""),
            TlsPort = maps:get(tls_port, Config, 4369),
            [
                {"GSMLG_EPMD_TLS_CERTFILE", CertPath},
                {"GSMLG_EPMD_TLS_KEYFILE", KeyPath},
                {"GSMLG_EPMD_TLS_CACERTFILE", CaPath},
                {"GSMLG_EPMD_GROUP", Group},
                {"GSMLG_EPMD_TLS_PORT", integer_to_list(TlsPort)}
            ];
        _ ->
            []
    end,

    CustomEnv = maps:get(env, Config, []),

    BaseEnv ++ TlsEnv ++ CustomEnv.

-spec mode_to_module(tls | static | variable) -> atom().
mode_to_module(tls) -> gsmlg_epmd_tls;
mode_to_module(static) -> gsmlg_epmd_static;
mode_to_module(variable) -> gsmlg_epmd_client.

-spec wait_for_node_loop(atom(), integer()) -> ok | {error, timeout}.
wait_for_node_loop(Name, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            {error, timeout};
        false ->
            case net_adm:ping(Name) of
                pong -> ok;
                pang ->
                    timer:sleep(100),
                    wait_for_node_loop(Name, Deadline)
            end
    end.

-spec wait_for_node_down(atom(), timeout()) -> ok.
wait_for_node_down(Name, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_node_down_loop(Name, Deadline).

-spec wait_for_node_down_loop(atom(), integer()) -> ok.
wait_for_node_down_loop(Name, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            ok; % Give up waiting, assume it's down
        false ->
            case net_adm:ping(Name) of
                pang -> ok;
                pong ->
                    timer:sleep(100),
                    wait_for_node_down_loop(Name, Deadline)
            end
    end.

-spec allocate_ports(pos_integer(), [pos_integer()]) -> [pos_integer()].
allocate_ports(0, Acc) ->
    lists:reverse(Acc);
allocate_ports(N, Acc) ->
    Port = find_available_port(Acc),
    allocate_ports(N - 1, [Port | Acc]).

-spec find_available_port([pos_integer()]) -> pos_integer().
find_available_port(Exclude) ->
    Port = ?EPHEMERAL_PORT_MIN + rand:uniform(?EPHEMERAL_PORT_MAX - ?EPHEMERAL_PORT_MIN),
    case lists:member(Port, Exclude) orelse not port_available(Port) of
        true -> find_available_port(Exclude);
        false -> Port
    end.

-spec port_available(pos_integer()) -> boolean().
port_available(Port) ->
    case gen_tcp:listen(Port, [binary, {reuseaddr, true}]) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            true;
        {error, _} ->
            false
    end.
