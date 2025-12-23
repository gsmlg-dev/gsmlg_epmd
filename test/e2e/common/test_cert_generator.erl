%%% @doc Test Certificate Generator
%%%
%%% Generates X.509 certificates for TLS mode E2E tests.
%%% Creates CA certificates, node certificates, and invalid certificates
%%% for testing various authentication scenarios.
%%%
%%% Uses OpenSSL command-line tool for certificate generation.
%%%
%%% @end
-module(test_cert_generator).

-export([
    create_ca/1,
    create_node_cert/3,
    create_node_cert/4,
    create_expired_cert/2,
    create_invalid_ca_cert/1,
    create_wrong_ou_cert/3,
    get_cert_paths/2,
    cleanup_certs/1
]).

-define(KEY_SIZE, 2048).
-define(VALID_DAYS, 365).
-define(EXPIRED_DAYS, -1).

-type ca_info() :: #{
    cert_path := string(),
    key_path := string(),
    dir := string()
}.

-type cert_info() :: #{
    cert_path := string(),
    key_path := string(),
    ca_cert_path := string()
}.

-export_type([ca_info/0, cert_info/0]).

%% @doc Create a new Certificate Authority for a test suite.
%% Returns paths to the CA certificate and private key.
-spec create_ca(string()) -> {ok, ca_info()} | {error, term()}.
create_ca(BaseDir) ->
    CaDir = filename:join(BaseDir, "ca"),
    ok = filelib:ensure_dir(filename:join(CaDir, "dummy")),

    CertPath = filename:join(CaDir, "ca-cert.pem"),
    KeyPath = filename:join(CaDir, "ca-key.pem"),

    Subject = "/CN=Test CA/O=GSMLG EPMD Test/OU=E2E Tests",

    Cmd = io_lib:format(
        "openssl req -x509 -newkey rsa:~p -keyout ~s -out ~s "
        "-days ~p -nodes -subj \"~s\" 2>/dev/null",
        [?KEY_SIZE, KeyPath, CertPath, ?VALID_DAYS, Subject]
    ),

    case os:cmd(lists:flatten(Cmd)) of
        "" ->
            %% Set restrictive permissions on private key
            os:cmd("chmod 400 " ++ KeyPath),
            {ok, #{cert_path => CertPath, key_path => KeyPath, dir => CaDir}};
        Error ->
            {error, {openssl_cmd_failed, Error}}
    end.

%% @doc Create a node certificate signed by the given CA.
%% The OU field is set to the Group parameter for trust group isolation.
-spec create_node_cert(ca_info(), atom() | string(), string()) ->
    {ok, cert_info()} | {error, term()}.
create_node_cert(CaInfo, NodeName, Group) ->
    BaseDir = filename:dirname(maps:get(dir, CaInfo)),
    create_node_cert(CaInfo, NodeName, Group, BaseDir).

%% @doc Create a node certificate in a specific directory.
-spec create_node_cert(ca_info(), atom() | string(), string(), string()) ->
    {ok, cert_info()} | {error, term()}.
create_node_cert(CaInfo, NodeName, Group, BaseDir) ->
    NodeNameStr = to_string(NodeName),
    NodeDir = filename:join([BaseDir, Group, NodeNameStr]),
    ok = filelib:ensure_dir(filename:join(NodeDir, "dummy")),

    CertPath = filename:join(NodeDir, "cert.pem"),
    KeyPath = filename:join(NodeDir, "key.pem"),
    CsrPath = filename:join(NodeDir, "cert.csr"),
    CaCertPath = maps:get(cert_path, CaInfo),
    CaKeyPath = maps:get(key_path, CaInfo),

    Subject = io_lib:format(
        "/CN=~s/O=GSMLG EPMD Test/OU=~s",
        [NodeNameStr, Group]
    ),

    %% Generate key and CSR
    CsrCmd = io_lib:format(
        "openssl req -newkey rsa:~p -keyout ~s -out ~s "
        "-nodes -subj \"~s\" 2>/dev/null",
        [?KEY_SIZE, KeyPath, CsrPath, Subject]
    ),

    case os:cmd(lists:flatten(CsrCmd)) of
        "" ->
            %% Sign with CA
            SignCmd = io_lib:format(
                "openssl x509 -req -in ~s -CA ~s -CAkey ~s "
                "-CAcreateserial -out ~s -days ~p 2>/dev/null",
                [CsrPath, CaCertPath, CaKeyPath, CertPath, ?VALID_DAYS]
            ),
            case os:cmd(lists:flatten(SignCmd)) of
                "" ->
                    %% Set restrictive permissions and cleanup CSR
                    os:cmd("chmod 400 " ++ KeyPath),
                    file:delete(CsrPath),
                    %% Create symlink to CA cert
                    CaCertLink = filename:join(NodeDir, "ca-cert.pem"),
                    file:make_symlink(CaCertPath, CaCertLink),
                    {ok, #{
                        cert_path => CertPath,
                        key_path => KeyPath,
                        ca_cert_path => CaCertPath
                    }};
                SignError ->
                    {error, {sign_failed, SignError}}
            end;
        CsrError ->
            {error, {csr_failed, CsrError}}
    end.

%% @doc Create an expired certificate for testing expiration rejection.
-spec create_expired_cert(ca_info(), atom() | string()) ->
    {ok, cert_info()} | {error, term()}.
create_expired_cert(CaInfo, NodeName) ->
    NodeNameStr = to_string(NodeName),
    BaseDir = filename:dirname(maps:get(dir, CaInfo)),
    NodeDir = filename:join([BaseDir, "invalid", "expired_" ++ NodeNameStr]),
    ok = filelib:ensure_dir(filename:join(NodeDir, "dummy")),

    CertPath = filename:join(NodeDir, "cert.pem"),
    KeyPath = filename:join(NodeDir, "key.pem"),
    CsrPath = filename:join(NodeDir, "cert.csr"),
    CaCertPath = maps:get(cert_path, CaInfo),
    CaKeyPath = maps:get(key_path, CaInfo),

    Subject = io_lib:format(
        "/CN=~s/O=GSMLG EPMD Test/OU=expired",
        [NodeNameStr]
    ),

    %% Generate key and CSR
    CsrCmd = io_lib:format(
        "openssl req -newkey rsa:~p -keyout ~s -out ~s "
        "-nodes -subj \"~s\" 2>/dev/null",
        [?KEY_SIZE, KeyPath, CsrPath, Subject]
    ),

    case os:cmd(lists:flatten(CsrCmd)) of
        "" ->
            %% Sign with CA but make it already expired
            %% Use startdate in the past and enddate also in the past
            SignCmd = io_lib:format(
                "openssl x509 -req -in ~s -CA ~s -CAkey ~s "
                "-CAcreateserial -out ~s -days ~p 2>/dev/null",
                [CsrPath, CaCertPath, CaKeyPath, CertPath, ?EXPIRED_DAYS]
            ),
            case os:cmd(lists:flatten(SignCmd)) of
                "" ->
                    os:cmd("chmod 400 " ++ KeyPath),
                    file:delete(CsrPath),
                    {ok, #{
                        cert_path => CertPath,
                        key_path => KeyPath,
                        ca_cert_path => CaCertPath
                    }};
                SignError ->
                    {error, {sign_failed, SignError}}
            end;
        CsrError ->
            {error, {csr_failed, CsrError}}
    end.

%% @doc Create a certificate signed by a different (invalid) CA.
%% This simulates a certificate that won't be trusted.
-spec create_invalid_ca_cert(string()) -> {ok, cert_info()} | {error, term()}.
create_invalid_ca_cert(BaseDir) ->
    InvalidDir = filename:join([BaseDir, "invalid", "wrong_ca"]),
    ok = filelib:ensure_dir(filename:join(InvalidDir, "dummy")),

    %% First create a separate "rogue" CA
    RogueCaDir = filename:join(InvalidDir, "rogue_ca"),
    ok = filelib:ensure_dir(filename:join(RogueCaDir, "dummy")),

    RogueCaCert = filename:join(RogueCaDir, "ca-cert.pem"),
    RogueCaKey = filename:join(RogueCaDir, "ca-key.pem"),

    RogueCaCmd = io_lib:format(
        "openssl req -x509 -newkey rsa:~p -keyout ~s -out ~s "
        "-days ~p -nodes -subj \"/CN=Rogue CA/O=Evil Corp\" 2>/dev/null",
        [?KEY_SIZE, RogueCaKey, RogueCaCert, ?VALID_DAYS]
    ),

    case os:cmd(lists:flatten(RogueCaCmd)) of
        "" ->
            %% Now create a cert signed by the rogue CA
            CertPath = filename:join(InvalidDir, "cert.pem"),
            KeyPath = filename:join(InvalidDir, "key.pem"),
            CsrPath = filename:join(InvalidDir, "cert.csr"),

            CsrCmd = io_lib:format(
                "openssl req -newkey rsa:~p -keyout ~s -out ~s "
                "-nodes -subj \"/CN=invalid-node/O=Evil Corp/OU=production\" 2>/dev/null",
                [?KEY_SIZE, KeyPath, CsrPath]
            ),

            case os:cmd(lists:flatten(CsrCmd)) of
                "" ->
                    SignCmd = io_lib:format(
                        "openssl x509 -req -in ~s -CA ~s -CAkey ~s "
                        "-CAcreateserial -out ~s -days ~p 2>/dev/null",
                        [CsrPath, RogueCaCert, RogueCaKey, CertPath, ?VALID_DAYS]
                    ),
                    case os:cmd(lists:flatten(SignCmd)) of
                        "" ->
                            os:cmd("chmod 400 " ++ KeyPath),
                            file:delete(CsrPath),
                            %% Return cert signed by wrong CA, but point to real CA for verification
                            %% This will cause verification to fail
                            {ok, #{
                                cert_path => CertPath,
                                key_path => KeyPath,
                                ca_cert_path => RogueCaCert
                            }};
                        SignError ->
                            {error, {sign_failed, SignError}}
                    end;
                CsrError ->
                    {error, {csr_failed, CsrError}}
            end;
        CaError ->
            {error, {rogue_ca_failed, CaError}}
    end.

%% @doc Create a certificate with wrong OU (different trust group).
-spec create_wrong_ou_cert(ca_info(), atom() | string(), string()) ->
    {ok, cert_info()} | {error, term()}.
create_wrong_ou_cert(CaInfo, NodeName, WrongGroup) ->
    %% This is essentially the same as create_node_cert but stored in invalid dir
    NodeNameStr = to_string(NodeName),
    BaseDir = filename:dirname(maps:get(dir, CaInfo)),
    NodeDir = filename:join([BaseDir, "invalid", "wrong_ou_" ++ NodeNameStr]),
    ok = filelib:ensure_dir(filename:join(NodeDir, "dummy")),

    CertPath = filename:join(NodeDir, "cert.pem"),
    KeyPath = filename:join(NodeDir, "key.pem"),
    CsrPath = filename:join(NodeDir, "cert.csr"),
    CaCertPath = maps:get(cert_path, CaInfo),
    CaKeyPath = maps:get(key_path, CaInfo),

    Subject = io_lib:format(
        "/CN=~s/O=GSMLG EPMD Test/OU=~s",
        [NodeNameStr, WrongGroup]
    ),

    CsrCmd = io_lib:format(
        "openssl req -newkey rsa:~p -keyout ~s -out ~s "
        "-nodes -subj \"~s\" 2>/dev/null",
        [?KEY_SIZE, KeyPath, CsrPath, Subject]
    ),

    case os:cmd(lists:flatten(CsrCmd)) of
        "" ->
            SignCmd = io_lib:format(
                "openssl x509 -req -in ~s -CA ~s -CAkey ~s "
                "-CAcreateserial -out ~s -days ~p 2>/dev/null",
                [CsrPath, CaCertPath, CaKeyPath, CertPath, ?VALID_DAYS]
            ),
            case os:cmd(lists:flatten(SignCmd)) of
                "" ->
                    os:cmd("chmod 400 " ++ KeyPath),
                    file:delete(CsrPath),
                    {ok, #{
                        cert_path => CertPath,
                        key_path => KeyPath,
                        ca_cert_path => CaCertPath
                    }};
                SignError ->
                    {error, {sign_failed, SignError}}
            end;
        CsrError ->
            {error, {csr_failed, CsrError}}
    end.

%% @doc Get certificate paths for a node in a group.
-spec get_cert_paths(string(), string()) -> cert_info().
get_cert_paths(BaseDir, NodeDir) ->
    #{
        cert_path => filename:join(NodeDir, "cert.pem"),
        key_path => filename:join(NodeDir, "key.pem"),
        ca_cert_path => filename:join([BaseDir, "ca", "ca-cert.pem"])
    }.

%% @doc Remove all generated certificates in a directory.
-spec cleanup_certs(string()) -> ok.
cleanup_certs(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            os:cmd("rm -rf " ++ Dir),
            ok;
        false ->
            ok
    end.

%%% Internal functions

-spec to_string(atom() | string()) -> string().
to_string(Atom) when is_atom(Atom) -> atom_to_list(Atom);
to_string(Str) when is_list(Str) -> Str.
