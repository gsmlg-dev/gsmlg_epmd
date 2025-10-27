%%% @doc Certificate management for TLS-based EPMD
%%%
%%% This module handles loading, validating, and extracting information from
%%% X.509 certificates used for TLS mutual authentication in gsmlg_epmd.
%%%
%%% Certificate Group Encoding:
%%% - Group membership is encoded in the OU (Organizational Unit) field
%%% - Example: OU=production, OU=staging, OU=development
%%% - Nodes with matching OU values are considered part of the same trust group
%%% @end
-module(gsmlg_epmd_cert).

-export([load_config/0,
         get_server_opts/0,
         get_client_opts/1,
         validate_peer_cert/3,
         extract_group/1,
         get_group/0]).

-include_lib("public_key/include/public_key.hrl").

-define(DEFAULT_TLS_PORT, 4369).

%% @doc Load TLS configuration from application environment or environment variables
-spec load_config() -> {ok, Config :: map()} | {error, Reason :: term()}.
load_config() ->
    CertFile = get_config(tls_certfile, "GSMLG_EPMD_TLS_CERTFILE"),
    KeyFile = get_config(tls_keyfile, "GSMLG_EPMD_TLS_KEYFILE"),
    CACertFile = get_config(tls_cacertfile, "GSMLG_EPMD_TLS_CACERTFILE"),
    Port = get_config(tls_port, "GSMLG_EPMD_TLS_PORT", ?DEFAULT_TLS_PORT),
    Group = get_config(group, "GSMLG_EPMD_GROUP", undefined),

    case {CertFile, KeyFile, CACertFile} of
        {undefined, _, _} ->
            {error, {missing_config, tls_certfile}};
        {_, undefined, _} ->
            {error, {missing_config, tls_keyfile}};
        {_, _, undefined} ->
            {error, {missing_config, tls_cacertfile}};
        {C, K, CA} ->
            Config = #{
                certfile => C,
                keyfile => K,
                cacertfile => CA,
                port => Port,
                group => Group
            },
            {ok, Config}
    end.

%% @doc Get SSL options for server (listen) socket
-spec get_server_opts() -> {ok, [ssl:tls_server_option()]} | {error, term()}.
get_server_opts() ->
    case load_config() of
        {ok, Config} ->
            #{certfile := CertFile,
              keyfile := KeyFile,
              cacertfile := CACertFile} = Config,

            Opts = [
                {certfile, CertFile},
                {keyfile, KeyFile},
                {cacertfile, CACertFile},
                {verify, verify_peer},
                {fail_if_no_peer_cert, true},
                {verify_fun, {fun ?MODULE:validate_peer_cert/3, #{}}},
                {versions, ['tlsv1.2', 'tlsv1.3']},
                {ciphers, ssl:cipher_suites(all, 'tlsv1.3') ++
                          ssl:cipher_suites(all, 'tlsv1.2')},
                {nodelay, true}
            ],
            {ok, Opts};
        Error ->
            Error
    end.

%% @doc Get SSL options for client (connect) socket
-spec get_client_opts(string()) -> {ok, [ssl:tls_client_option()]} | {error, term()}.
get_client_opts(ServerName) ->
    case load_config() of
        {ok, Config} ->
            #{certfile := CertFile,
              keyfile := KeyFile,
              cacertfile := CACertFile} = Config,

            Opts = [
                {certfile, CertFile},
                {keyfile, KeyFile},
                {cacertfile, CACertFile},
                {verify, verify_peer},
                {server_name_indication, ServerName},
                {verify_fun, {fun ?MODULE:validate_peer_cert/3, #{}}},
                {versions, ['tlsv1.2', 'tlsv1.3']},
                {ciphers, ssl:cipher_suites(all, 'tlsv1.3') ++
                          ssl:cipher_suites(all, 'tlsv1.2')},
                {nodelay, true}
            ],
            {ok, Opts};
        Error ->
            Error
    end.

%% @doc Custom certificate validation function
%% Validates certificate chain and checks group membership
-spec validate_peer_cert(Cert :: #'OTPCertificate'{} | binary(),
                         Event :: valid | valid_peer | {bad_cert, Reason :: atom()} |
                                 {extension, #'Extension'{}},
                         UserState :: map()) -> {valid, map()} | {fail, term()}.
validate_peer_cert(_Cert, {bad_cert, _Reason} = Event, _UserState) ->
    {fail, Event};
validate_peer_cert(_Cert, {extension, _}, UserState) ->
    {valid, UserState};
validate_peer_cert(_Cert, valid, UserState) ->
    %% Intermediate certificate in chain
    {valid, UserState};
validate_peer_cert(Cert, valid_peer, UserState) ->
    %% Leaf certificate - validate group membership
    case extract_group(Cert) of
        {ok, PeerGroup} ->
            case get_group() of
                {ok, LocalGroup} when LocalGroup =:= PeerGroup ->
                    {valid, UserState#{peer_group => PeerGroup}};
                {ok, LocalGroup} ->
                    {fail, {group_mismatch, LocalGroup, PeerGroup}};
                undefined ->
                    %% No local group configured, accept any group
                    {valid, UserState#{peer_group => PeerGroup}}
            end;
        {error, Reason} ->
            {fail, {group_extraction_failed, Reason}}
    end.

%% @doc Extract group name from certificate OU field
-spec extract_group(#'OTPCertificate'{} | binary()) ->
    {ok, Group :: string()} | {error, Reason :: term()}.
extract_group(DerCert) when is_binary(DerCert) ->
    Cert = public_key:pkix_decode_cert(DerCert, otp),
    extract_group(Cert);
extract_group(#'OTPCertificate'{} = Cert) ->
    TBS = Cert#'OTPCertificate'.tbsCertificate,
    Subject = TBS#'OTPTBSCertificate'.subject,

    case Subject of
        {rdnSequence, RDNSeq} ->
            extract_ou_from_rdn(RDNSeq);
        _ ->
            {error, invalid_subject_format}
    end.

%% @doc Get the local node's group from configuration or certificate
-spec get_group() -> {ok, Group :: string()} | undefined.
get_group() ->
    %% First check explicit configuration
    case get_config(group, "GSMLG_EPMD_GROUP", undefined) of
        undefined ->
            %% Extract from own certificate
            case load_config() of
                {ok, #{certfile := CertFile}} ->
                    case file:read_file(CertFile) of
                        {ok, PemBin} ->
                            case public_key:pem_decode(PemBin) of
                                [{'Certificate', DerCert, _} | _] ->
                                    extract_group(DerCert);
                                _ ->
                                    undefined
                            end;
                        _ ->
                            undefined
                    end;
                _ ->
                    undefined
            end;
        Group ->
            {ok, Group}
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
get_config(Key, EnvVar) ->
    get_config(Key, EnvVar, undefined).

%% @private
get_config(Key, EnvVar, Default) ->
    case application:get_env(gsmlg_epmd, Key) of
        {ok, Value} ->
            Value;
        undefined ->
            case os:getenv(EnvVar) of
                false ->
                    Default;
                Value when is_list(Value), Key =:= tls_port ->
                    list_to_integer(Value);
                Value ->
                    Value
            end
    end.

%% @private
%% Extract OU (Organizational Unit) from RDN sequence
extract_ou_from_rdn([]) ->
    {error, no_ou_found};
extract_ou_from_rdn([RDN | Rest]) ->
    case extract_ou_from_attribute_list(RDN) of
        {ok, OU} ->
            {ok, OU};
        {error, _} ->
            extract_ou_from_rdn(Rest)
    end.

%% @private
extract_ou_from_attribute_list([]) ->
    {error, no_ou_in_rdn};
extract_ou_from_attribute_list([#'AttributeTypeAndValue'{
    type = ?'id-at-organizationalUnitName',
    value = Value} | _]) ->
    %% Value can be various string types
    OU = case Value of
        {utf8String, Str} when is_binary(Str) ->
            binary_to_list(Str);
        {printableString, Str} when is_list(Str) ->
            Str;
        {ia5String, Str} when is_list(Str) ->
            Str;
        Str when is_list(Str) ->
            Str;
        _ ->
            ""
    end,
    {ok, OU};
extract_ou_from_attribute_list([_ | Rest]) ->
    extract_ou_from_attribute_list(Rest).
