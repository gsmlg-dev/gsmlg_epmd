%%% @doc EUnit tests for test_node_manager module.
-module(test_node_manager_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test port allocation
allocate_ports_test_() ->
    [
        {"allocate single port", fun test_allocate_single_port/0},
        {"allocate multiple ports", fun test_allocate_multiple_ports/0},
        {"allocated ports are unique", fun test_ports_unique/0},
        {"allocated ports are in ephemeral range", fun test_ports_in_range/0}
    ].

test_allocate_single_port() ->
    [Port] = test_node_manager:allocate_test_ports(1),
    ?assert(is_integer(Port)),
    ?assert(Port >= 49152),
    ?assert(Port =< 65535).

test_allocate_multiple_ports() ->
    Ports = test_node_manager:allocate_test_ports(5),
    ?assertEqual(5, length(Ports)),
    lists:foreach(
        fun(Port) ->
            ?assert(is_integer(Port)),
            ?assert(Port >= 49152),
            ?assert(Port =< 65535)
        end,
        Ports
    ).

test_ports_unique() ->
    Ports = test_node_manager:allocate_test_ports(10),
    UniquePorts = lists:usort(Ports),
    ?assertEqual(length(Ports), length(UniquePorts)).

test_ports_in_range() ->
    Ports = test_node_manager:allocate_test_ports(20),
    lists:foreach(
        fun(Port) ->
            ?assert(Port >= 49152 andalso Port =< 65535)
        end,
        Ports
    ).

%% Note: Node start/stop tests are integration tests that require
%% actual node spawning and are better suited for Common Test suites.
%% These EUnit tests focus on the helper functions.

%% Test configuration building (internal function testing via exported API)
config_test_() ->
    [
        {"node config requires name", fun test_config_requires_name/0},
        {"node config requires mode", fun test_config_requires_mode/0},
        {"node config requires port", fun test_config_requires_port/0}
    ].

test_config_requires_name() ->
    Config = #{mode => static, port => 50000},
    %% This should fail because name is required
    ?assertError(_, test_node_manager:start_node(Config)).

test_config_requires_mode() ->
    Config = #{name => test_node, port => 50000},
    %% This should fail because mode is required
    ?assertError(_, test_node_manager:start_node(Config)).

test_config_requires_port() ->
    Config = #{name => test_node, mode => static},
    %% This should fail because port is required
    ?assertError(_, test_node_manager:start_node(Config)).
