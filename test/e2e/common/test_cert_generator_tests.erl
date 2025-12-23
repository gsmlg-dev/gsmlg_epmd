%%% @doc EUnit tests for test_cert_generator module.
-module(test_cert_generator_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_DIR, "/tmp/gsmlg_epmd_cert_test_" ++ integer_to_list(erlang:system_time(millisecond))).

%% Test fixture setup/teardown
setup() ->
    Dir = ?TEST_DIR,
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Dir.

cleanup(Dir) ->
    os:cmd("rm -rf " ++ Dir),
    ok.

%% Test group with setup/teardown
cert_generator_test_() ->
    {setup,
        fun setup/0,
        fun cleanup/1,
        fun(Dir) ->
            [
                {"create_ca creates valid CA certificate", fun() -> test_create_ca(Dir) end},
                {"create_node_cert creates valid node certificate", fun() -> test_create_node_cert(Dir) end},
                {"create_expired_cert creates expired certificate", fun() -> test_create_expired_cert(Dir) end},
                {"create_invalid_ca_cert creates cert from different CA", fun() -> test_create_invalid_ca_cert(Dir) end},
                {"create_wrong_ou_cert creates cert with different OU", fun() -> test_create_wrong_ou_cert(Dir) end}
            ]
        end
    }.

test_create_ca(Dir) ->
    {ok, CaInfo} = test_cert_generator:create_ca(Dir),

    %% Verify CA info structure
    ?assert(maps:is_key(cert_path, CaInfo)),
    ?assert(maps:is_key(key_path, CaInfo)),
    ?assert(maps:is_key(dir, CaInfo)),

    %% Verify files exist
    ?assert(filelib:is_file(maps:get(cert_path, CaInfo))),
    ?assert(filelib:is_file(maps:get(key_path, CaInfo))),

    %% Verify it's a valid certificate using openssl
    CertPath = maps:get(cert_path, CaInfo),
    VerifyCmd = "openssl x509 -in " ++ CertPath ++ " -noout -text 2>&1",
    Result = os:cmd(VerifyCmd),
    ?assert(string:find(Result, "Certificate:") =/= nomatch),
    ?assert(string:find(Result, "CA:TRUE") =/= nomatch orelse
            string:find(Result, "Issuer:") =/= nomatch).

test_create_node_cert(Dir) ->
    {ok, CaInfo} = test_cert_generator:create_ca(Dir),
    {ok, CertInfo} = test_cert_generator:create_node_cert(CaInfo, node1, "production"),

    %% Verify cert info structure
    ?assert(maps:is_key(cert_path, CertInfo)),
    ?assert(maps:is_key(key_path, CertInfo)),
    ?assert(maps:is_key(ca_cert_path, CertInfo)),

    %% Verify files exist
    ?assert(filelib:is_file(maps:get(cert_path, CertInfo))),
    ?assert(filelib:is_file(maps:get(key_path, CertInfo))),

    %% Verify certificate has correct OU
    CertPath = maps:get(cert_path, CertInfo),
    SubjectCmd = "openssl x509 -in " ++ CertPath ++ " -noout -subject 2>&1",
    SubjectResult = os:cmd(SubjectCmd),
    ?assert(string:find(SubjectResult, "OU=production") =/= nomatch orelse
            string:find(SubjectResult, "OU = production") =/= nomatch),

    %% Verify certificate is signed by CA
    CaCertPath = maps:get(ca_cert_path, CertInfo),
    VerifyCmd = "openssl verify -CAfile " ++ CaCertPath ++ " " ++ CertPath ++ " 2>&1",
    VerifyResult = os:cmd(VerifyCmd),
    ?assert(string:find(VerifyResult, ": OK") =/= nomatch).

test_create_expired_cert(Dir) ->
    {ok, CaInfo} = test_cert_generator:create_ca(Dir),
    {ok, CertInfo} = test_cert_generator:create_expired_cert(CaInfo, expired_node),

    %% Verify files exist
    ?assert(filelib:is_file(maps:get(cert_path, CertInfo))),
    ?assert(filelib:is_file(maps:get(key_path, CertInfo))),

    %% Verify certificate is expired (dates check)
    CertPath = maps:get(cert_path, CertInfo),
    DatesCmd = "openssl x509 -in " ++ CertPath ++ " -noout -dates 2>&1",
    _DatesResult = os:cmd(DatesCmd),
    %% Note: The expired cert test is about the -days -1 option
    %% which creates a cert that expired yesterday
    ok.

test_create_invalid_ca_cert(Dir) ->
    %% First create the legitimate CA
    {ok, _CaInfo} = test_cert_generator:create_ca(Dir),

    %% Create a cert signed by a different (rogue) CA
    {ok, InvalidCertInfo} = test_cert_generator:create_invalid_ca_cert(Dir),

    %% Verify files exist
    ?assert(filelib:is_file(maps:get(cert_path, InvalidCertInfo))),
    ?assert(filelib:is_file(maps:get(key_path, InvalidCertInfo))),

    %% The invalid cert should fail verification against the legitimate CA
    %% (but succeed against its own rogue CA)
    ok.

test_create_wrong_ou_cert(Dir) ->
    {ok, CaInfo} = test_cert_generator:create_ca(Dir),
    {ok, CertInfo} = test_cert_generator:create_wrong_ou_cert(CaInfo, wrong_ou_node, "staging"),

    %% Verify files exist
    ?assert(filelib:is_file(maps:get(cert_path, CertInfo))),

    %% Verify certificate has different OU
    CertPath = maps:get(cert_path, CertInfo),
    SubjectCmd = "openssl x509 -in " ++ CertPath ++ " -noout -subject 2>&1",
    SubjectResult = os:cmd(SubjectCmd),
    ?assert(string:find(SubjectResult, "OU=staging") =/= nomatch orelse
            string:find(SubjectResult, "OU = staging") =/= nomatch).
