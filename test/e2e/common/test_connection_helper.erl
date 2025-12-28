%%% @doc Test Connection Helper
%%%
%%% Provides assertion and verification utilities for testing node connections.
%%% Includes functions to verify successful connections, rejected connections,
%%% and connection timeouts.
%%%
%%% @end
-module(test_connection_helper).

-export([
    assert_connected/2,
    assert_connected/3,
    assert_rejected/2,
    assert_rejected/3,
    wait_for_connection/2,
    wait_for_connection/3,
    get_connected_nodes/1,
    verify_mesh/1,
    verify_isolation/2
]).

-define(DEFAULT_TIMEOUT, 10000).
-define(POLL_INTERVAL, 100).

%% @doc Assert that two nodes are connected (bidirectional).
-spec assert_connected(atom(), atom()) -> ok | {error, term()}.
assert_connected(Node1, Node2) ->
    assert_connected(Node1, Node2, ?DEFAULT_TIMEOUT).

%% @doc Assert that two nodes are connected with custom timeout.
-spec assert_connected(atom(), atom(), timeout()) -> ok | {error, term()}.
assert_connected(Node1, Node2, Timeout) ->
    case wait_for_connection(Node1, Node2, Timeout) of
        ok ->
            %% Verify bidirectional connection
            case is_node_connected(Node2, Node1) of
                true -> ok;
                false -> {error, {not_bidirectional, Node1, Node2}}
            end;
        Error ->
            Error
    end.

%% @doc Assert that a connection is rejected.
-spec assert_rejected(atom(), atom()) -> ok | {error, term()}.
assert_rejected(Node1, Node2) ->
    assert_rejected(Node1, Node2, undefined).

%% @doc Assert that a connection is rejected with expected reason.
-spec assert_rejected(atom(), atom(), term()) -> ok | {error, term()}.
assert_rejected(Node1, Node2, ExpectedReason) ->
    %% First verify nodes are not connected
    case is_node_connected(Node1, Node2) of
        true ->
            {error, {unexpectedly_connected, Node1, Node2}};
        false ->
            %% Try to connect and expect failure
            case attempt_connection(Node1, Node2) of
                {error, Reason} when ExpectedReason =:= undefined ->
                    ok;
                {error, ExpectedReason} ->
                    ok;
                {error, ActualReason} ->
                    {error, {wrong_rejection_reason, ExpectedReason, ActualReason}};
                ok ->
                    {error, {connection_succeeded_unexpectedly, Node1, Node2}}
            end
    end.

%% @doc Wait for a connection between two nodes.
-spec wait_for_connection(atom(), atom()) -> ok | {error, timeout}.
wait_for_connection(Node1, Node2) ->
    wait_for_connection(Node1, Node2, ?DEFAULT_TIMEOUT).

%% @doc Wait for a connection with custom timeout.
-spec wait_for_connection(atom(), atom(), timeout()) -> ok | {error, timeout}.
wait_for_connection(Node1, Node2, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_connection_loop(Node1, Node2, Deadline).

%% @doc Get list of connected nodes from a specific node's perspective.
-spec get_connected_nodes(atom()) -> {ok, [atom()]} | {error, term()}.
get_connected_nodes(Node) ->
    case rpc:call(Node, erlang, nodes, [], 5000) of
        {badrpc, Reason} ->
            {error, {rpc_failed, Reason}};
        Nodes when is_list(Nodes) ->
            {ok, Nodes}
    end.

%% @doc Verify that all nodes in list form a fully connected mesh.
-spec verify_mesh([atom()]) -> ok | {error, term()}.
verify_mesh(Nodes) ->
    verify_mesh(Nodes, Nodes).

%% @doc Verify that nodes in Group1 are isolated from nodes in Group2.
%% No node in Group1 should be connected to any node in Group2.
-spec verify_isolation([atom()], [atom()]) -> ok | {error, term()}.
verify_isolation(Group1, Group2) ->
    Violations = lists:foldl(
        fun(N1, Acc) ->
            lists:foldl(
                fun(N2, InnerAcc) ->
                    case is_node_connected(N1, N2) of
                        true -> [{N1, N2} | InnerAcc];
                        false -> InnerAcc
                    end
                end,
                Acc,
                Group2
            )
        end,
        [],
        Group1
    ),
    case Violations of
        [] -> ok;
        _ -> {error, {isolation_violated, Violations}}
    end.

%%% Internal functions

-spec wait_for_connection_loop(atom(), atom(), integer()) -> ok | {error, timeout}.
wait_for_connection_loop(Node1, Node2, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            {error, timeout};
        false ->
            case is_node_connected(Node1, Node2) of
                true -> ok;
                false ->
                    timer:sleep(?POLL_INTERVAL),
                    wait_for_connection_loop(Node1, Node2, Deadline)
            end
    end.

-spec is_node_connected(atom(), atom()) -> boolean().
is_node_connected(FromNode, ToNode) ->
    case rpc:call(FromNode, erlang, nodes, [], 5000) of
        {badrpc, _} ->
            false;
        Nodes when is_list(Nodes) ->
            lists:member(ToNode, Nodes)
    end.

-spec attempt_connection(atom(), atom()) -> ok | {error, term()}.
attempt_connection(FromNode, ToNode) ->
    case rpc:call(FromNode, net_adm, ping, [ToNode], 5000) of
        pong ->
            ok;
        pang ->
            {error, connection_refused};
        {badrpc, Reason} ->
            {error, {rpc_failed, Reason}}
    end.

-spec verify_mesh([atom()], [atom()]) -> ok | {error, term()}.
verify_mesh([], _AllNodes) ->
    ok;
verify_mesh([Node | Rest], AllNodes) ->
    ExpectedPeers = lists:delete(Node, AllNodes),
    case get_connected_nodes(Node) of
        {ok, ConnectedNodes} ->
            Missing = ExpectedPeers -- ConnectedNodes,
            case Missing of
                [] ->
                    verify_mesh(Rest, AllNodes);
                _ ->
                    {error, {mesh_incomplete, Node, Missing}}
            end;
        {error, Reason} ->
            {error, {cannot_verify_mesh, Node, Reason}}
    end.
