# Research: E2E Node Connection Tests

**Feature**: 001-e2e-connection-tests
**Date**: 2025-11-19
**Purpose**: Research technical approaches for end-to-end testing of GSMLG EPMD connection modes

## Decision 1: Test Framework Selection

**Decision**: Use Common Test (CT) for E2E suites, EUnit for helper module unit tests

**Rationale**:
- Common Test is Erlang/OTP's standard framework for system and integration testing
- CT provides built-in support for test suites (`*_SUITE.erl`), init/end_per_suite hooks ideal for node lifecycle management
- CT supports parallel test case execution with proper isolation
- EUnit remains appropriate for unit testing helper modules (cert generation, connection helpers)
- Existing project already uses EUnit for unit tests (`test/*_tests.erl`) - maintaining consistency

**Alternatives Considered**:
- **EUnit only**: Rejected - lacks robust system testing features, no built-in suite-level fixtures
- **PropEr (property-based)**: Deferred - valuable for future fuzz testing but overkill for deterministic connection scenarios
- **Custom test harness**: Rejected - reinventing wheel, Common Test is battle-tested

**Implementation Notes**:
- CT test discovery via `rebar3 ct` command
- Test suites will be in `test/e2e/*_SUITE.erl`
- Each suite corresponds to one connection mode (TLS, static, variable)

## Decision 2: Node Lifecycle Management Strategy

**Decision**: Use `peer` module (OTP 25+) with fallback to `slave` for OTP 21-24

**Rationale**:
- `peer` module (introduced OTP 25) is modern approach for starting Erlang nodes in tests
- Provides better isolation and resource cleanup than deprecated `slave` module
- Supports starting nodes with custom VM args and environment variables
- For OTP 21-24 compatibility, conditional compilation with `slave` fallback
- Both support starting nodes on same host with different names/ports

**Alternatives Considered**:
- **Docker containers per node**: Rejected - adds complexity, slower startup, harder to debug interactively
- **`os:cmd` + erl startup**: Rejected - manual process management, no built-in cleanup
- **Always use `slave`**: Rejected - deprecated in OTP 27, limits future maintainability

**Implementation Notes**:
```erlang
-ifdef(OTP_RELEASE >= 25).
    start_test_node(Name, Args) -> peer:start_link(#{name => Name, args => Args}).
-else.
    start_test_node(Name, Args) -> slave:start_link(node(), Name, Args).
-endif.
```

## Decision 3: Certificate Generation Strategy

**Decision**: Generate certificates on-the-fly per test suite using `test_cert_generator` module wrapping OpenSSL

**Rationale**:
- Avoids committing certificates to version control (constitution requirement)
- Enables testing certificate expiration, invalid CA, wrong OU scenarios dynamically
- Each test suite gets fresh CA and node certs with controlled properties
- OpenSSL is standard tool, available in all CI environments (GitHub Actions Ubuntu includes it)
- Self-contained test execution - no external certificate dependencies

**Alternatives Considered**:
- **Pre-generated test certificates in test/data**: Rejected - violates constitution "no certs in version control", expires over time
- **Manual setup before tests**: Rejected - not idempotent, fails CI automation requirement
- **Erlang public_key module only**: Rejected - complex API for full certificate generation, OpenSSL simpler for test cases

**Implementation Notes**:
- `test_cert_generator:create_ca/1` → returns CA cert + key
- `test_cert_generator:create_node_cert/3` → generates node cert with specified OU field
- `test_cert_generator:create_expired_cert/2` → for expiration testing
- Certificates stored in temp directory, cleaned up in `end_per_suite/1`

## Decision 4: Port Allocation Strategy

**Decision**: Use ephemeral port range (49152-65535) with random selection + conflict detection

**Rationale**:
- Parallel CI matrix jobs (9 concurrent) require isolated port spaces
- Ephemeral range reduces conflicts with system services
- Random selection minimizes collision probability between concurrent test suites
- Retry logic (3 attempts) handles rare collisions gracefully
- Each test case picks fresh ports for its nodes

**Alternatives Considered**:
- **Fixed port assignment per suite**: Rejected - causes conflicts in parallel execution
- **Sequential port allocation**: Rejected - not parallel-safe across matrix jobs
- **Let OS assign ports**: Rejected - need to know ports before starting nodes for configuration

**Implementation Notes**:
```erlang
allocate_test_ports(Count) ->
    lists:map(fun(_) ->
        Port = 49152 + rand:uniform(16383),
        case port_available(Port) of
            true -> Port;
            false -> allocate_test_ports(1) %% Retry
        end
    end, lists:seq(1, Count)).
```

## Decision 5: mDNS Testing in CI

**Decision**: Use GitHub Actions service containers with multicast networking enabled

**Rationale**:
- GitHub Actions default network mode blocks multicast (mDNS requirement)
- Solution: Run tests in Docker container with `--network=host` or custom bridge network with multicast
- Alternative: Mock mDNS for CI, real mDNS for local testing (compromises test authenticity)
- Service container approach keeps tests realistic and validates actual mDNS behavior

**Alternatives Considered**:
- **Mock mDNS entirely**: Rejected - doesn't test real discovery mechanism, defeats purpose of e2e tests
- **Skip mDNS tests in CI**: Rejected - mDNS is critical TLS mode feature, must be tested
- **Use GitHub-hosted runners with multicast**: Rejected - not supported natively, requires workarounds

**Implementation Notes**:
- e2e-test.yml workflow uses custom Docker network:
```yaml
services:
  test-network:
    image: alpine
    options: --network=multicast-bridge
```
- Test suite detects CI environment via `$CI` env var, adjusts mDNS timeouts if needed (local: 5s, CI: 10s)

## Decision 6: GitHub Actions Matrix Strategy

**Decision**: Single workflow file (e2e-test.yml) with 2D matrix: `[mode] × [otp_version]`

**Rationale**:
- Clarification session confirmed: single workflow with matrix strategy (not separate files)
- Matrix dimensions:
  - `mode`: [tls, static, variable]
  - `otp_version`: [23, 25, 27]
  - Total: 9 parallel jobs
- Each job runs only its mode-specific test suite (`ct --suite tls_mode_SUITE`)
- GitHub Actions automatically parallelizes matrix jobs (free tier: 20 concurrent)
- Single workflow file simplifies maintenance, consistent artifact handling

**Alternatives Considered**:
- **Sequential execution**: Rejected - violates spec requirement "run tasks parallel for each kind of test"
- **3 separate workflow files**: Rejected - duplication, harder to maintain, user explicitly chose option B (matrix strategy)

**Implementation Notes**:
```yaml
strategy:
  matrix:
    mode: [tls, static, variable]
    otp_version: [23, 25, 27]
  fail-fast: false  # Continue other jobs if one fails
steps:
  - name: Run ${{ matrix.mode }} mode tests
    run: rebar3 ct --suite test/e2e/${{ matrix.mode }}_mode_SUITE
```

## Decision 7: Test Artifact Retention

**Decision**: 30-day retention for logs/failures, 7-day retention for success artifacts

**Rationale**:
- Clarification session answer: "Retain test logs and failure diagnostics only for 30 days, delete successful run artifacts after 7 days"
- GitHub Actions default: 90 days (excessive for tests, costs storage)
- Failure logs need longer retention for debugging old issues
- Success artifacts (CT HTML reports) less critical, shorter retention reduces costs

**Implementation Notes**:
```yaml
- name: Upload test results (failure)
  if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: test-logs-${{ matrix.mode }}-otp${{ matrix.otp_version }}
    path: _build/test/logs/
    retention-days: 30

- name: Upload test results (success)
  if: success()
  uses: actions/upload-artifact@v4
  with:
    name: test-reports-${{ matrix.mode }}-otp${{ matrix.otp_version }}
    path: _build/test/logs/*.html
    retention-days: 7
```

## Decision 8: Test Execution Timeout Strategy

**Decision**: Per-test-case timeout 60s, per-suite timeout 10 minutes

**Rationale**:
- Spec requirement: "Test execution time MUST NOT exceed 10 minutes for the full suite"
- Individual connection tests should complete in <10s normally, 60s timeout catches hangs
- Full suite (30-40 test cases) with setup/teardown fits in 10 minutes
- Common Test supports `{timetrap, {minutes, 10}}` at suite level
- Prevents infinite waits on mDNS discovery failures or node startup issues

**Implementation Notes**:
```erlang
suite() ->
    [{timetrap, {minutes, 10}}].  %% Suite-level timeout

test_tls_auto_discovery(Config) ->
    ct:timetrap({seconds, 60}),  %% Override for specific test
    %% Test logic
```

## Open Questions

**None** - All technical decisions resolved during research phase.

## Next Steps

Proceed to **Phase 1** to create:
1. `data-model.md` - Test entities, certificate structures, connection matrices
2. `contracts/e2e-test-workflow.yml` - Full GitHub Actions workflow specification
3. `quickstart.md` - Local test execution guide
