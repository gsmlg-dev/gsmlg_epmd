-module(gsmlg_epmd_cert_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Fixtures
%%====================================================================

cert_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Config) ->
         [
          {"Extract group from certificate", fun() -> test_extract_group(Config) end},
          {"Load config from environment", fun() -> test_load_config_env(Config) end},
          {"Get server TLS options", fun() -> test_get_server_opts(Config) end},
          {"Get client TLS options", fun() -> test_get_client_opts(Config) end},
          {"Validate peer certificate with matching group", fun() -> test_validate_peer_matching_group(Config) end},
          {"Reject peer certificate with different group", fun() -> test_validate_peer_different_group(Config) end}
         ]
     end}.

%%====================================================================
%% Setup/Cleanup
%%====================================================================

setup() ->
    %% Generate test certificates
    Config = test_helpers:setup_test_certs("production"),
    Node1Config = test_helpers:create_test_cert(Config, "node1"),
    Node2Config = test_helpers:create_test_cert(Config, "node2"),

    %% Also create staging group cert
    StagingConfig = test_helpers:setup_test_certs("staging"),
    Node3Config = test_helpers:create_test_cert(StagingConfig, "node3"),

    #{
        base_config => Config,
        staging_config => StagingConfig,
        node1 => Node1Config,
        node2 => Node2Config,
        node3 => Node3Config
    }.

cleanup(#{base_config := Config, staging_config := StagingConfig}) ->
    test_helpers:cleanup_test_certs(Config),
    test_helpers:cleanup_test_certs(StagingConfig),
    ok.

%%====================================================================
%% Tests
%%====================================================================

test_extract_group(#{node1 := Node1Config}) ->
    #{cert := CertFile} = Node1Config,

    %% Read certificate
    {ok, CertPem} = file:read_file(CertFile),
    [{'Certificate', CertDer, not_encrypted}] = public_key:pem_decode(CertPem),
    Cert = public_key:pkix_decode_cert(CertDer, otp),

    %% Extract group
    {ok, Group} = gsmlg_epmd_cert:extract_group(Cert),

    %% Verify group matches
    ?assertEqual("production", Group).

test_load_config_env(#{node1 := Node1Config}) ->
    #{key := KeyFile, cert := CertFile, ca_cert := CACertFile} = Node1Config,

    %% Set environment variables
    test_helpers:with_test_env([
        {"GSMLG_EPMD_TLS_CERTFILE", CertFile},
        {"GSMLG_EPMD_TLS_KEYFILE", KeyFile},
        {"GSMLG_EPMD_TLS_CACERTFILE", CACertFile},
        {"GSMLG_EPMD_TLS_PORT", "4369"},
        {"GSMLG_EPMD_GROUP", "production"}
    ], fun() ->
        {ok, Config} = gsmlg_epmd_cert:load_config(),

        ?assertMatch(#{
            certfile := CertFile,
            keyfile := KeyFile,
            cacertfile := CACertFile,
            port := 4369,
            group := "production"
        }, Config)
    end).

test_get_server_opts(#{node1 := Node1Config}) ->
    #{key := KeyFile, cert := CertFile, ca_cert := CACertFile} = Node1Config,

    test_helpers:with_test_env([
        {"GSMLG_EPMD_TLS_CERTFILE", CertFile},
        {"GSMLG_EPMD_TLS_KEYFILE", KeyFile},
        {"GSMLG_EPMD_TLS_CACERTFILE", CACertFile}
    ], fun() ->
        {ok, Opts} = gsmlg_epmd_cert:get_server_opts(),

        %% Verify required options present
        ?assert(proplists:is_defined(certfile, Opts)),
        ?assert(proplists:is_defined(keyfile, Opts)),
        ?assert(proplists:is_defined(cacertfile, Opts)),
        ?assertEqual(verify_peer, proplists:get_value(verify, Opts)),
        ?assertEqual(true, proplists:get_value(fail_if_no_peer_cert, Opts))
    end).

test_get_client_opts(#{node1 := Node1Config}) ->
    #{key := KeyFile, cert := CertFile, ca_cert := CACertFile} = Node1Config,

    test_helpers:with_test_env([
        {"GSMLG_EPMD_TLS_CERTFILE", CertFile},
        {"GSMLG_EPMD_TLS_KEYFILE", KeyFile},
        {"GSMLG_EPMD_TLS_CACERTFILE", CACertFile}
    ], fun() ->
        {ok, Opts} = gsmlg_epmd_cert:get_client_opts("node2"),

        %% Verify required options present
        ?assert(proplists:is_defined(certfile, Opts)),
        ?assert(proplists:is_defined(keyfile, Opts)),
        ?assert(proplists:is_defined(cacertfile, Opts)),
        ?assertEqual(verify_peer, proplists:get_value(verify, Opts))
    end).

test_validate_peer_matching_group(#{node1 := Node1Config, node2 := Node2Config}) ->
    %% Both nodes in production group
    #{cert := Cert1} = Node1Config,
    #{cert := Cert2} = Node2Config,

    %% Setup environment for node1
    #{key := Key1, ca_cert := CA1} = Node1Config,
    test_helpers:with_test_env([
        {"GSMLG_EPMD_TLS_CERTFILE", Cert1},
        {"GSMLG_EPMD_TLS_KEYFILE", Key1},
        {"GSMLG_EPMD_TLS_CACERTFILE", CA1},
        {"GSMLG_EPMD_GROUP", "production"}
    ], fun() ->
        %% Read peer certificate (node2)
        {ok, Cert2Pem} = file:read_file(Cert2),
        [{'Certificate', Cert2Der, not_encrypted}] = public_key:pem_decode(Cert2Pem),
        PeerCert = public_key:pkix_decode_cert(Cert2Der, otp),

        %% Validate peer certificate - should succeed (same group)
        UserState = #{},
        Result = gsmlg_epmd_cert:validate_peer_cert(PeerCert, valid_peer, UserState),

        ?assertMatch({valid, #{peer_group := "production"}}, Result)
    end).

test_validate_peer_different_group(#{node1 := Node1Config, node3 := Node3Config}) ->
    %% Node1 in production, node3 in staging
    #{cert := Cert1, key := Key1, ca_cert := CA1} = Node1Config,
    #{cert := Cert3} = Node3Config,

    %% Setup environment for node1 (production group)
    test_helpers:with_test_env([
        {"GSMLG_EPMD_TLS_CERTFILE", Cert1},
        {"GSMLG_EPMD_TLS_KEYFILE", Key1},
        {"GSMLG_EPMD_TLS_CACERTFILE", CA1},
        {"GSMLG_EPMD_GROUP", "production"}
    ], fun() ->
        %% Read peer certificate (node3 - staging)
        {ok, Cert3Pem} = file:read_file(Cert3),
        [{'Certificate', Cert3Der, not_encrypted}] = public_key:pem_decode(Cert3Pem),
        PeerCert = public_key:pkix_decode_cert(Cert3Der, otp),

        %% Validate peer certificate - should fail (different group)
        UserState = #{},
        Result = gsmlg_epmd_cert:validate_peer_cert(PeerCert, valid_peer, UserState),

        ?assertMatch({fail, {group_mismatch, "production", "staging"}}, Result)
    end).
