%%% @doc Supervisor for gsmlg_epmd services
%%%
%%% Manages the lifecycle of:
%%% - gsmlg_epmd_cookie: Cookie management gen_server
%%% - gsmlg_epmd_tls: Main EPMD callback gen_server
%%% - gsmlg_epmd_tls_server: TLS server (dynamically started)
%%% - gsmlg_epmd_mdns: mDNS discovery (dynamically started)
%%% @end
-module(gsmlg_epmd_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

%% @doc Start the supervisor
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },

    %% Child specifications
    %% Note: TLS server and mDNS are started dynamically by gsmlg_epmd_tls
    ChildSpecs = [
        %% Cookie manager - stores and exchanges cookies
        #{
            id => gsmlg_epmd_cookie,
            start => {gsmlg_epmd_cookie, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [gsmlg_epmd_cookie]
        },

        %% Main EPMD module - implements EPMD callbacks
        #{
            id => gsmlg_epmd_tls,
            start => {gsmlg_epmd_tls, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [gsmlg_epmd_tls]
        }
    ],

    {ok, {SupFlags, ChildSpecs}}.
