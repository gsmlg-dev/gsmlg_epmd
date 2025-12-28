-module(gsmlg_epmd_cookie_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Fixtures
%%====================================================================

cookie_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_generate_cookie/1,
      fun test_cookie_uniqueness/1,
      fun test_cookie_length/1,
      fun test_store_and_retrieve_cookie/1,
      fun test_format_hello_message/1,
      fun test_parse_hello_message/1
     ]}.

%%====================================================================
%% Setup/Cleanup
%%====================================================================

setup() ->
    %% Start cookie gen_server for tests, or use existing one
    case gsmlg_epmd_cookie:start_link() of
        {ok, Pid} ->
            #{pid => Pid, started_by_test => true};
        {error, {already_started, Pid}} ->
            #{pid => Pid, started_by_test => false}
    end.

cleanup(#{pid := _Pid, started_by_test := true}) ->
    %% Only stop if we started it
    gen_server:stop(gsmlg_epmd_cookie),
    ok;
cleanup(#{started_by_test := false}) ->
    %% Don't stop server we didn't start
    ok.

%%====================================================================
%% Tests
%%====================================================================

test_generate_cookie(_Config) ->
    {"Generate cookie test", fun() ->
        Cookie = gsmlg_epmd_cookie:generate_cookie(),
        %% Cookie should be binary
        ?assert(is_binary(Cookie)),
        %% Cookie should be 32 bytes (256 bits)
        ?assertEqual(32, byte_size(Cookie))
    end}.

test_cookie_uniqueness(_Config) ->
    {"Cookie uniqueness test", fun() ->
        %% Generate multiple cookies
        Cookies = [gsmlg_epmd_cookie:generate_cookie() || _ <- lists:seq(1, 100)],
        %% All should be unique
        UniqueCount = length(lists:usort(Cookies)),
        ?assertEqual(100, UniqueCount)
    end}.

test_cookie_length(_Config) ->
    {"Cookie length test", fun() ->
        %% Generate 1000 cookies and verify all are 32 bytes
        Cookies = [gsmlg_epmd_cookie:generate_cookie() || _ <- lists:seq(1, 1000)],
        AllCorrectLength = lists:all(fun(Cookie) ->
            byte_size(Cookie) =:= 32
        end, Cookies),
        ?assert(AllCorrectLength)
    end}.

test_store_and_retrieve_cookie(_Config) ->
    {"Store and retrieve cookie test", fun() ->
        Node = 'test@localhost',
        Cookie = gsmlg_epmd_cookie:generate_cookie(),
        %% Store cookie
        ok = gsmlg_epmd_cookie:store_cookie(Node, Cookie),
        %% Retrieve cookie
        {ok, Retrieved} = gsmlg_epmd_cookie:get_cookie(Node),
        %% Should match
        ?assertEqual(Cookie, Retrieved)
    end}.

test_format_hello_message(_Config) ->
    {"Format hello message test", fun() ->
        Node = 'testnode@localhost',
        Cookie = gsmlg_epmd_cookie:generate_cookie(),
        DistPort = 8001,
        Hello = gsmlg_epmd_cookie:format_hello(Node, Cookie, DistPort),
        %% Should be binary
        ?assert(is_binary(Hello)),
        %% Should start with version byte
        <<Version:8, _Rest/binary>> = Hello,
        ?assertEqual(1, Version),  %% Protocol version 1
        %% Should be parseable
        {ok, Parsed} = gsmlg_epmd_cookie:parse_hello(Hello),
        ?assertMatch(#{
            node := Node,
            cookie := Cookie,
            dist_port := DistPort
        }, Parsed)
    end}.

test_parse_hello_message(_Config) ->
    {"Parse hello message test", fun() ->
        %% Create a valid hello message
        Node = 'node@host',
        Cookie = crypto:strong_rand_bytes(32),
        DistPort = 8080,
        Hello = gsmlg_epmd_cookie:format_hello(Node, Cookie, DistPort),
        %% Parse it
        {ok, Parsed} = gsmlg_epmd_cookie:parse_hello(Hello),
        %% Verify fields
        ?assertEqual(Node, maps:get(node, Parsed)),
        ?assertEqual(Cookie, maps:get(cookie, Parsed)),
        ?assertEqual(DistPort, maps:get(dist_port, Parsed))
    end}.

%%====================================================================
%% Additional Tests for Error Cases
%%====================================================================

error_test_() ->
    [
     {"Parse invalid hello message", fun test_parse_invalid_hello/0},
     {"Get non-existent cookie", fun test_get_nonexistent_cookie/0}
    ].

test_parse_invalid_hello() ->
    %% Invalid version
    InvalidVersion = <<99, 0, 0, 0>>,
    ?assertMatch({error, _}, gsmlg_epmd_cookie:parse_hello(InvalidVersion)),

    %% Too short
    TooShort = <<1>>,
    ?assertMatch({error, _}, gsmlg_epmd_cookie:parse_hello(TooShort)),

    %% Empty binary
    ?assertMatch({error, _}, gsmlg_epmd_cookie:parse_hello(<<>>)).

test_get_nonexistent_cookie() ->
    %% Use existing server or start one
    Started = case gsmlg_epmd_cookie:start_link() of
        {ok, _Pid} -> true;
        {error, {already_started, _}} -> false
    end,

    try
        %% Try to get cookie for non-existent node
        Result = gsmlg_epmd_cookie:get_cookie('nonexistent@localhost'),
        ?assertEqual({error, not_found}, Result)
    after
        %% Only stop if we started it
        case Started of
            true -> gen_server:stop(gsmlg_epmd_cookie);
            false -> ok
        end
    end.
