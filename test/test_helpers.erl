-module(test_helpers).

%% Test helper utilities for GSMLG EPMD tests
-export([
    setup_test_certs/1,
    cleanup_test_certs/1,
    create_test_cert/2,
    get_test_cert_config/1,
    with_test_env/2
]).

-include_lib("eunit/include/eunit.hrl").

%% @doc Setup test certificates for a given group
setup_test_certs(Group) ->
    TempDir = "/tmp/gsmlg_epmd_test_" ++ Group ++ "_" ++ integer_to_list(erlang:system_time()),
    file:make_dir(TempDir),

    CADir = filename:join(TempDir, "ca"),
    file:make_dir(CADir),

    %% Generate test CA
    CAKey = filename:join(CADir, "ca-key.pem"),
    CACert = filename:join(CADir, "ca-cert.pem"),

    CAKeyCmd = "openssl genrsa -out " ++ CAKey ++ " 2048 2>/dev/null",
    CACertCmd = "openssl req -new -x509 -key " ++ CAKey ++
                " -out " ++ CACert ++
                " -days 365 -subj '/C=US/ST=Test/L=Test/O=TestOrg/CN=TestCA' 2>/dev/null",

    os:cmd(CAKeyCmd),
    os:cmd(CACertCmd),

    #{
        temp_dir => TempDir,
        ca_dir => CADir,
        ca_key => CAKey,
        ca_cert => CACert,
        group => Group
    }.

%% @doc Create a test certificate for a node
create_test_cert(Config, NodeName) ->
    #{temp_dir := TempDir, ca_key := CAKey, ca_cert := CACert, group := Group} = Config,

    NodeDir = filename:join([TempDir, Group, NodeName]),
    filelib:ensure_dir(filename:join(NodeDir, "dummy")),

    NodeKey = filename:join(NodeDir, "key.pem"),
    NodeCert = filename:join(NodeDir, "cert.pem"),
    NodeCSR = filename:join(NodeDir, "cert.csr"),
    NodeCACert = filename:join(NodeDir, "ca-cert.pem"),

    %% Generate node key
    KeyCmd = "openssl genrsa -out " ++ NodeKey ++ " 2048 2>/dev/null",

    %% Generate CSR with OU set to group
    CSRCmd = "openssl req -new -key " ++ NodeKey ++ " -out " ++ NodeCSR ++
             " -subj '/C=US/ST=Test/L=Test/O=TestOrg/OU=" ++ Group ++ "/CN=" ++ NodeName ++ "' 2>/dev/null",

    %% Sign certificate
    SignCmd = "openssl x509 -req -in " ++ NodeCSR ++
              " -CA " ++ CACert ++ " -CAkey " ++ CAKey ++
              " -CAcreateserial -out " ++ NodeCert ++
              " -days 365 2>/dev/null",

    %% Copy CA cert
    CopyCmd = "cp " ++ CACert ++ " " ++ NodeCACert,

    os:cmd(KeyCmd),
    os:cmd(CSRCmd),
    os:cmd(SignCmd),
    os:cmd(CopyCmd),

    #{
        key => NodeKey,
        cert => NodeCert,
        ca_cert => NodeCACert,
        group => Group
    }.

%% @doc Get test certificate configuration for a node
get_test_cert_config(NodeConfig) ->
    #{key := Key, cert := Cert, ca_cert := CACert} = NodeConfig,
    #{
        certfile => Cert,
        keyfile => Key,
        cacertfile => CACert
    }.

%% @doc Run function with test environment variables
with_test_env(EnvVars, Fun) ->
    %% Save original env
    OriginalEnv = lists:map(fun({Key, _Val}) ->
        {Key, os:getenv(Key)}
    end, EnvVars),

    try
        %% Set test env
        lists:foreach(fun({Key, Val}) ->
            os:putenv(Key, Val)
        end, EnvVars),

        %% Run test
        Fun()
    after
        %% Restore original env
        lists:foreach(fun({Key, false}) ->
            os:unsetenv(Key);
        ({Key, OrigVal}) ->
            os:putenv(Key, OrigVal)
        end, OriginalEnv)
    end.

%% @doc Cleanup test certificates
cleanup_test_certs(#{temp_dir := TempDir}) ->
    os:cmd("rm -rf " ++ TempDir),
    ok.
