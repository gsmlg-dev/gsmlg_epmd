# GSMLG EPMD Tests

This directory contains unit tests and integration tests for GSMLG EPMD.

## Test Structure

- **`test_helpers.erl`** - Common test utilities and certificate generation helpers
- **`gsmlg_epmd_cert_tests.erl`** - Tests for certificate management and validation
- **`gsmlg_epmd_cookie_tests.erl`** - Tests for cookie generation and exchange protocol

## Running Tests

### Unit Tests (EUnit)

```bash
# Run all tests
rebar3 eunit

# Run specific test module
rebar3 eunit --module=gsmlg_epmd_cert_tests

# Run tests with coverage
rebar3 cover --reset
rebar3 eunit
rebar3 cover --verbose
```

### Integration Tests

Integration tests are located in `shelltests/` and use [shelltestrunner](https://github.com/simonmichael/shelltestrunner/).

```bash
cd shelltests
./run_tests.sh
```

## Test Requirements

**Dependencies:**
- OpenSSL (for certificate generation in tests)
- Erlang/OTP 21+

**Environment:**
- Tests create temporary certificates in `/tmp/gsmlg_epmd_test_*`
- Tests clean up temporary files automatically
- Some tests require write permissions to `/tmp`

## Writing Tests

### Test Helpers

Use `test_helpers` module for common operations:

```erlang
-include_lib("eunit/include/eunit.hrl").

my_test_() ->
    {setup,
     fun() ->
         %% Setup test certificates
         Config = test_helpers:setup_test_certs("production"),
         NodeConfig = test_helpers:create_test_cert(Config, "node1"),
         #{base => Config, node => NodeConfig}
     end,
     fun(#{base := Config}) ->
         %% Cleanup
         test_helpers:cleanup_test_certs(Config)
     end,
     fun(Fixture) ->
         [
          {"My test", fun() -> my_test_impl(Fixture) end}
         ]
     end}.
```

### Certificate Tests

```erlang
test_with_certificates() ->
    Config = test_helpers:setup_test_certs("production"),
    Node1 = test_helpers:create_test_cert(Config, "node1"),

    #{cert := CertFile, key := KeyFile, ca_cert := CACert} = Node1,

    %% Use certificates in test
    test_helpers:with_test_env([
        {"GSMLG_EPMD_TLS_CERTFILE", CertFile},
        {"GSMLG_EPMD_TLS_KEYFILE", KeyFile},
        {"GSMLG_EPMD_TLS_CACERTFILE", CACert}
    ], fun() ->
        %% Test code here
        ok
    end),

    test_helpers:cleanup_test_certs(Config).
```

## Test Coverage

Current test coverage:

| Module | Coverage | Notes |
|--------|----------|-------|
| gsmlg_epmd_cert | ~70% | Certificate validation, group extraction |
| gsmlg_epmd_cookie | ~80% | Cookie generation, protocol serialization |
| gsmlg_epmd_tls | TBD | Main EPMD callbacks |
| gsmlg_epmd_tls_server | TBD | TLS connection handling |
| gsmlg_epmd_mdns | TBD | mDNS discovery |

**To improve:**
- Add integration tests for TLS handshake
- Add tests for mDNS discovery
- Add property-based tests (PropEr)
- Add end-to-end auto-mesh tests

## Continuous Integration

**Note:** Per project guidelines, CI only runs static checks and analysis (dialyzer), NOT unit tests.

The GitHub Actions workflow (`.github/workflows/main.yml`) runs:
- `rebar3 compile` - Compilation check
- `rebar3 dialyzer` - Static analysis

Unit tests are run separately in a dedicated test action.

## Debugging Tests

### Verbose Output

```bash
# Run with verbose output
rebar3 eunit --verbose

# Run specific test with debugging
rebar3 eunit --module=gsmlg_epmd_cert_tests --verbose
```

### Inspect Test Certificates

```bash
# Tests create certs in /tmp
ls /tmp/gsmlg_epmd_test_*

# Inspect a test certificate
openssl x509 -in /tmp/gsmlg_epmd_test_production_*/production/node1/cert.pem -noout -text
```

### Keep Test Artifacts

Modify test cleanup to keep certificates:

```erlang
cleanup(_Config) ->
    %% Comment out for debugging
    %% test_helpers:cleanup_test_certs(Config),
    ok.
```

## Test Utilities

### Certificate Helpers

- `test_helpers:setup_test_certs/1` - Create CA and directory structure
- `test_helpers:create_test_cert/2` - Generate node certificate
- `test_helpers:get_test_cert_config/1` - Get cert paths as map
- `test_helpers:cleanup_test_certs/1` - Remove temporary files

### Environment Helpers

- `test_helpers:with_test_env/2` - Run function with temporary env vars

## Common Issues

**OpenSSL not found:**
```
Error: openssl command not found
Solution: Install OpenSSL (apt-get install openssl, brew install openssl, etc.)
```

**Permission denied on /tmp:**
```
Error: Cannot create directory /tmp/gsmlg_epmd_test_*
Solution: Check /tmp permissions (should be 1777)
```

**Certificate validation fails:**
```
Error: certificate verify failed
Solution: Ensure test certificates are generated correctly, check OpenSSL output
```

## Future Test Enhancements

- [ ] Property-based tests with PropEr
- [ ] Load tests for cookie exchange
- [ ] Chaos testing (network partitions, node failures)
- [ ] Multi-node integration tests with real Erlang distribution
- [ ] Performance benchmarks
- [ ] Security audit tests (weak ciphers, expired certs, etc.)

---

**Last Updated**: 2025-10-26
