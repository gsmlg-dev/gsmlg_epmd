%%% @doc Cookie exchange protocol for TLS-authenticated EPMD nodes
%%%
%%% This module handles the generation, exchange, and storage of Erlang cookies
%%% between nodes after successful TLS mutual authentication. This allows nodes
%%% to dynamically exchange cookies securely instead of using pre-shared cookies.
%%%
%%% Protocol:
%%% 1. After TLS handshake, nodes exchange hello messages
%%% 2. Each message contains: node name, generated cookie, distribution port, group
%%% 3. Cookies are stored for future distribution connections
%%% @end
-module(gsmlg_epmd_cookie).

-behaviour(gen_server).

%% API
-export([start_link/0,
         generate_cookie/0,
         exchange_cookies/2,
         get_cookie/1,
         store_cookie/2,
         list_cookies/0,
         format_hello/3,
         parse_hello/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2]).

-define(SERVER, ?MODULE).
-define(COOKIE_LENGTH, 32).  %% 256 bits
-define(PROTOCOL_VERSION, 1).

-record(state, {
    local_cookie :: binary(),
    remote_cookies = #{} :: #{node() => binary()}
}).

-type hello_msg() :: #{
    type := hello,
    version := integer(),
    node := node(),
    cookie := binary(),
    dist_port := inet:port_number(),
    group := string()
}.

%%====================================================================
%% API
%%====================================================================

%% @doc Start the cookie manager
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Generate a cryptographically secure random cookie
-spec generate_cookie() -> binary().
generate_cookie() ->
    crypto:strong_rand_bytes(?COOKIE_LENGTH).

%% @doc Exchange cookies with a remote node over TLS socket
-spec exchange_cookies(ssl:sslsocket(), inet:port_number()) ->
    {ok, NodeInfo :: map()} | {error, term()}.
exchange_cookies(Socket, DistPort) ->
    %% Send our hello message
    case send_hello(Socket, DistPort) of
        ok ->
            %% Receive remote hello
            case recv_hello(Socket) of
                {ok, RemoteHello} ->
                    %% Store remote node's cookie
                    #{node := RemoteNode, cookie := RemoteCookie} = RemoteHello,
                    ok = store_cookie(RemoteNode, RemoteCookie),
                    {ok, RemoteHello};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Get the stored cookie for a remote node
-spec get_cookie(node()) -> {ok, binary()} | {error, not_found}.
get_cookie(Node) ->
    gen_server:call(?SERVER, {get_cookie, Node}).

%% @doc Store a cookie for a remote node
-spec store_cookie(node(), binary()) -> ok.
store_cookie(Node, Cookie) ->
    gen_server:call(?SERVER, {store_cookie, Node, Cookie}).

%% @doc List all stored cookies
-spec list_cookies() -> #{node() => binary()}.
list_cookies() ->
    gen_server:call(?SERVER, list_cookies).

%% @doc Format a hello message as binary (for testing and alternative protocol)
%% Binary format: Version(1) | DistPort(2) | NodeLen(2) | NodeName(NodeLen) | Cookie(32)
-spec format_hello(node(), binary(), inet:port_number()) -> binary().
format_hello(Node, Cookie, DistPort) when byte_size(Cookie) =:= ?COOKIE_LENGTH ->
    NodeBin = atom_to_binary(Node, utf8),
    NodeLen = byte_size(NodeBin),
    <<?PROTOCOL_VERSION:8, DistPort:16, NodeLen:16, NodeBin/binary, Cookie/binary>>.

%% @doc Parse a binary hello message (for testing and alternative protocol)
-spec parse_hello(binary()) -> {ok, map()} | {error, term()}.
parse_hello(<<?PROTOCOL_VERSION:8, DistPort:16, NodeLen:16, Rest/binary>>) ->
    case Rest of
        <<NodeBin:NodeLen/binary, Cookie:?COOKIE_LENGTH/binary>> ->
            try
                Node = binary_to_atom(NodeBin, utf8),
                {ok, #{
                    version => ?PROTOCOL_VERSION,
                    node => Node,
                    dist_port => DistPort,
                    cookie => Cookie
                }}
            catch
                _:_ ->
                    {error, invalid_node_name}
            end;
        _ ->
            {error, invalid_hello_format}
    end;
parse_hello(<<Version:8, _/binary>>) when Version =/= ?PROTOCOL_VERSION ->
    {error, {unsupported_version, Version}};
parse_hello(_) ->
    {error, invalid_protocol_format}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Generate our local cookie on startup
    LocalCookie = generate_cookie(),
    {ok, #state{local_cookie = LocalCookie}}.

handle_call({get_cookie, Node}, _From, State) ->
    Reply = case maps:find(Node, State#state.remote_cookies) of
        {ok, Cookie} -> {ok, Cookie};
        error -> {error, not_found}
    end,
    {reply, Reply, State};

handle_call({store_cookie, Node, Cookie}, _From, State) ->
    NewCookies = maps:put(Node, Cookie, State#state.remote_cookies),
    {reply, ok, State#state{remote_cookies = NewCookies}};

handle_call(list_cookies, _From, State) ->
    {reply, State#state.remote_cookies, State};

handle_call({get_local_cookie}, _From, State) ->
    {reply, State#state.local_cookie, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
%% Send hello message to remote node
send_hello(Socket, DistPort) ->
    case gen_server:call(?SERVER, {get_local_cookie}) of
        LocalCookie ->
            case gsmlg_epmd_cert:get_group() of
                {ok, Group} ->
                    Hello = #{
                        type => hello,
                        version => ?PROTOCOL_VERSION,
                        node => node(),
                        cookie => LocalCookie,
                        dist_port => DistPort,
                        group => Group
                    },
                    Bin = term_to_binary(Hello),
                    Size = byte_size(Bin),
                    Packet = <<Size:32, Bin/binary>>,
                    ssl:send(Socket, Packet);
                undefined ->
                    Hello = #{
                        type => hello,
                        version => ?PROTOCOL_VERSION,
                        node => node(),
                        cookie => LocalCookie,
                        dist_port => DistPort,
                        group => "default"
                    },
                    Bin = term_to_binary(Hello),
                    Size = byte_size(Bin),
                    Packet = <<Size:32, Bin/binary>>,
                    ssl:send(Socket, Packet)
            end
    end.

%% @private
%% Receive hello message from remote node
recv_hello(Socket) ->
    case ssl:recv(Socket, 4, 5000) of
        {ok, <<Size:32>>} ->
            case ssl:recv(Socket, Size, 5000) of
                {ok, Bin} ->
                    try binary_to_term(Bin) of
                        #{type := hello, version := ?PROTOCOL_VERSION} = Hello ->
                            validate_hello(Hello);
                        #{type := hello, version := Version} ->
                            {error, {unsupported_version, Version}};
                        _ ->
                            {error, invalid_hello}
                    catch
                        _:_ ->
                            {error, invalid_hello_format}
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @private
%% Validate hello message structure
validate_hello(#{node := Node,
                 cookie := Cookie,
                 dist_port := Port,
                 group := Group} = Hello)
  when is_atom(Node), is_binary(Cookie), is_integer(Port), is_list(Group) ->
    {ok, Hello};
validate_hello(_) ->
    {error, invalid_hello_structure}.
