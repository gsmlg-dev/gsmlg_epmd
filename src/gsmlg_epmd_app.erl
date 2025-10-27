%%% @doc Application callback for gsmlg_epmd
-module(gsmlg_epmd_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% Application callbacks
%%====================================================================

start(_StartType, _StartArgs) ->
    gsmlg_epmd_sup:start_link().

stop(_State) ->
    ok.
