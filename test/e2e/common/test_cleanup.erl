%%% @doc Test Cleanup Utilities
%%%
%%% Provides cleanup functions for E2E tests to ensure proper resource
%%% management. Handles cleanup of temporary certificates, orphaned nodes,
%%% and other test artifacts.
%%%
%%% @end
-module(test_cleanup).

-export([
    cleanup_temp_certs/1,
    kill_orphaned_nodes/0,
    kill_orphaned_nodes/1,
    cleanup_all/1,
    create_temp_dir/1,
    get_temp_dir/1
]).

-define(TEST_NODE_PREFIX, "gsmlg_epmd_test").
-define(TEMP_DIR_PREFIX, "/tmp/gsmlg_epmd_test_").

%% @doc Clean up temporary certificate directories.
-spec cleanup_temp_certs(string()) -> ok.
cleanup_temp_certs(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            %% Use rm -rf to recursively delete
            Cmd = "rm -rf " ++ escape_path(Dir),
            os:cmd(Cmd),
            ok;
        false ->
            ok
    end.

%% @doc Kill all orphaned test nodes matching the test prefix.
-spec kill_orphaned_nodes() -> {ok, integer()} | {error, term()}.
kill_orphaned_nodes() ->
    kill_orphaned_nodes(?TEST_NODE_PREFIX).

%% @doc Kill orphaned nodes matching a specific pattern.
-spec kill_orphaned_nodes(string()) -> {ok, integer()} | {error, term()}.
kill_orphaned_nodes(Pattern) ->
    %% Find and kill beam processes matching the pattern
    Cmd = io_lib:format(
        "pgrep -f 'beam.*~s' 2>/dev/null | xargs -r kill -9 2>/dev/null; echo $?",
        [Pattern]
    ),
    Result = os:cmd(lists:flatten(Cmd)),
    %% Count killed processes
    CountCmd = io_lib:format(
        "pgrep -f 'beam.*~s' 2>/dev/null | wc -l",
        [Pattern]
    ),
    CountResult = string:trim(os:cmd(lists:flatten(CountCmd))),
    case CountResult of
        "0" ->
            {ok, 0};
        N ->
            try
                Count = list_to_integer(N),
                %% Still processes running, try harder
                lists:foreach(
                    fun(_) ->
                        os:cmd(lists:flatten(Cmd)),
                        timer:sleep(100)
                    end,
                    lists:seq(1, 3)
                ),
                {ok, Count}
            catch
                _:_ ->
                    {error, {parse_error, Result}}
            end
    end.

%% @doc Perform complete cleanup for a test suite.
-spec cleanup_all(map()) -> ok.
cleanup_all(Config) ->
    %% Stop all nodes
    Nodes = maps:get(nodes, Config, []),
    lists:foreach(
        fun(NodeRef) ->
            catch test_node_manager:stop_node(NodeRef)
        end,
        Nodes
    ),

    %% Wait a bit for nodes to stop
    timer:sleep(500),

    %% Kill any orphaned processes
    kill_orphaned_nodes(),

    %% Clean up temp directory
    TempDir = maps:get(temp_dir, Config, undefined),
    case TempDir of
        undefined -> ok;
        Dir -> cleanup_temp_certs(Dir)
    end,

    ok.

%% @doc Create a temporary directory for a test suite.
%% Returns the path to the created directory.
-spec create_temp_dir(string()) -> {ok, string()} | {error, term()}.
create_temp_dir(SuiteName) ->
    Timestamp = erlang:system_time(millisecond),
    DirName = io_lib:format("~s~s_~p", [?TEMP_DIR_PREFIX, SuiteName, Timestamp]),
    Dir = lists:flatten(DirName),
    case filelib:ensure_dir(filename:join(Dir, "dummy")) of
        ok ->
            {ok, Dir};
        {error, Reason} ->
            {error, {create_dir_failed, Reason}}
    end.

%% @doc Get the temporary directory for a suite, creating if needed.
-spec get_temp_dir(string()) -> string().
get_temp_dir(SuiteName) ->
    case create_temp_dir(SuiteName) of
        {ok, Dir} -> Dir;
        {error, _} ->
            %% Fallback to simple naming
            lists:flatten(io_lib:format("~s~s", [?TEMP_DIR_PREFIX, SuiteName]))
    end.

%%% Internal functions

-spec escape_path(string()) -> string().
escape_path(Path) ->
    %% Escape special characters for shell
    lists:flatten(
        lists:map(
            fun($') -> "\\'";
               ($") -> "\\\"";
               ($ ) -> "\\ ";
               (C) -> C
            end,
            Path
        )
    ).
