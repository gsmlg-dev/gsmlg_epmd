# Quickstart: E2E Node Connection Tests

**Feature**: 001-e2e-connection-tests
**Purpose**: Guide for running E2E tests locally and in CI

## Prerequisites

### Required Software

- **Erlang/OTP**: 21+ (23, 25, or 27 recommended for full compatibility testing)
- **rebar3**: 3.22 or newer
- **OpenSSL**: For certificate generation (usually pre-installed on macOS/Linux)
- **Git**: For checking out the repository

### Verification

```bash
# Check Erlang version
erl -eval '{ok, Version} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:fwrite(Version), halt().' -noshell

# Check rebar3
rebar3 version

# Check OpenSSL
openssl version
```

Expected output:
```
OTP-23.0 (or higher)
rebar 3.22.0 (or higher)
OpenSSL 1.1.1 or 3.0.x
```

## Running All E2E Tests

### Option 1: All Test Suites (Recommended for CI Parity)

```bash
# Run all three connection modes
rebar3 ct --suite test/e2e/tls_mode_SUITE,test/e2e/static_mode_SUITE,test/e2e/variable_mode_SUITE

# View results
open _build/test/logs/index.html  # macOS
xdg-open _build/test/logs/index.html  # Linux
```

### Option 2: Single Connection Mode

```bash
# TLS mode only
rebar3 ct --suite test/e2e/tls_mode_SUITE

# Static port mode only
rebar3 ct --suite test/e2e/static_mode_SUITE

# Variable port mode only
rebar3 ct --suite test/e2e/variable_mode_SUITE
```

### Option 3: Specific Test Case

```bash
# Run single test case from TLS mode suite
rebar3 ct --suite test/e2e/tls_mode_SUITE --case test_tls_auto_discovery

# Run multiple test cases
rebar3 ct --suite test/e2e/tls_mode_SUITE --case test_tls_auto_discovery,test_tls_group_isolation
```

## Test Execution Details

### Timing Expectations

- **TLS mode suite**: ~5-7 minutes (includes mDNS discovery delays)
- **Static mode suite**: ~2-3 minutes
- **Variable mode suite**: ~2-3 minutes
- **Full suite**: <10 minutes (spec requirement)

### Resource Usage

- **Concurrent nodes**: 4-6 per test case (typical mesh scenarios)
- **Port range**: 49152-65535 (ephemeral, random allocation)
- **Disk usage**: ~5MB per test run (temporary certificates)
- **Memory**: ~100MB per Erlang node (~400-600MB total during tests)

## Local Test Configuration

### Environment Variables (Optional)

```bash
# Adjust mDNS discovery timeout (default: 10s)
export GSMLG_EPMD_MDNS_TIMEOUT=15

# Enable verbose logging
export CT_LOG_LEVEL=debug

# Custom temp directory for certificates
export GSMLG_EPMD_TEST_TEMP_DIR=/tmp/my_e2e_tests
```

### Running with Different OTP Versions

```bash
# Using asdf (https://asdf-vm.com/)
asdf install erlang 23.3.4
asdf local erlang 23.3.4
rebar3 ct --suite test/e2e/tls_mode_SUITE

asdf install erlang 25.3
asdf local erlang 25.3
rebar3 ct --suite test/e2e/tls_mode_SUITE

asdf install erlang 27.0
asdf local erlang 27.0
rebar3 ct --suite test/e2e/tls_mode_SUITE
```

## Troubleshooting

### Problem: mDNS Discovery Fails ("no nodes discovered")

**Symptoms**:
```
Test failed: Expected nodes [node2@localhost] to be discovered via mDNS, but got []
```

**Causes & Solutions**:

1. **Multicast blocked by firewall**
   ```bash
   # macOS: Allow multicast in firewall
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/local/bin/erl
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/local/bin/erl

   # Linux: Check iptables
   sudo iptables -L | grep MULTICAST
   # Allow if blocked:
   sudo iptables -A INPUT -m pkttype --pkt-type multicast -j ACCEPT
   ```

2. **Wrong network interface**
   ```bash
   # Check active interfaces
   ifconfig | grep -A 1 "UP,.*MULTICAST"

   # Set specific interface (if needed)
   export GSMLG_EPMD_MDNS_INTERFACE=en0  # macOS
   export GSMLG_EPMD_MDNS_INTERFACE=eth0  # Linux
   ```

3. **mDNS daemon not running (Linux)**
   ```bash
   # Check Avahi (mDNS implementation on Linux)
   systemctl status avahi-daemon

   # Start if not running
   sudo systemctl start avahi-daemon
   ```

### Problem: Port Conflicts ("address already in use")

**Symptoms**:
```
Test failed: Node startup error: {error, eaddrinuse}
```

**Solutions**:

1. **Kill orphaned test nodes**
   ```bash
   # Find test nodes still running
   ps aux | grep beam | grep gsmlg_epmd_test

   # Kill all (caution: kills all beam processes)
   pkill -f "beam.*gsmlg_epmd_test"
   ```

2. **Check port availability before tests**
   ```bash
   # Check if port 50000 is in use
   lsof -i :50000
   netstat -an | grep 50000
   ```

3. **Clean up Common Test lock files**
   ```bash
   rm -rf _build/test/logs/ct_run.*
   rm -f /tmp/.ct_*
   ```

### Problem: Certificate Generation Fails

**Symptoms**:
```
Test setup failed: {error, {openssl_cmd_failed, 127}}
```

**Solutions**:

1. **Verify OpenSSL in PATH**
   ```bash
   which openssl
   # Should return: /usr/bin/openssl or /usr/local/bin/openssl
   ```

2. **Check OpenSSL config**
   ```bash
   openssl version -d
   # Should show config directory (e.g., /etc/ssl)
   ```

3. **Manually test certificate generation**
   ```bash
   # Try generating a test cert
   openssl req -x509 -newkey rsa:2048 -keyout /tmp/test-key.pem -out /tmp/test-cert.pem -days 365 -nodes -subj "/CN=test"
   # Should succeed without errors
   ```

### Problem: Tests Timeout

**Symptoms**:
```
Test case 'test_tls_auto_discovery' timed out after 60000 ms
```

**Solutions**:

1. **Increase test case timeout (for debugging)**
   ```erlang
   % In test/e2e/tls_mode_SUITE.erl
   test_tls_auto_discovery(Config) ->
       ct:timetrap({minutes, 5}),  % Increase from default 1 minute
       ...
   ```

2. **Check node startup logs**
   ```bash
   # Test nodes log to temp directories
   ls /tmp/gsmlg_epmd_test_*/
   tail -f /tmp/gsmlg_epmd_test_*/node1/erlang.log.1
   ```

3. **Run test interactively with Erlang shell**
   ```bash
   rebar3 shell
   ```
   ```erlang
   % In Erlang shell
   ct:run_test([{suite, "test/e2e/tls_mode_SUITE"}, {case, test_tls_auto_discovery}, {logdir, "/tmp/ct_logs"}]).
   ```

### Problem: Orphaned Processes After Tests

**Symptoms**:
```
Warning: Found running processes matching 'gsmlg_epmd_test'
```

**Solutions**:

1. **Verify cleanup hooks executed**
   ```bash
   # Check test logs for "end_per_suite" and "end_per_testcase"
   grep -r "end_per_suite" _build/test/logs/
   ```

2. **Manual cleanup**
   ```bash
   # Kill all test nodes
   pkill -f "beam.*gsmlg_epmd_test"

   # Remove temp directories
   rm -rf /tmp/gsmlg_epmd_test_*

   # Clear Common Test state
   rm -rf _build/test/logs/
   ```

3. **Add cleanup to test suite** (if missing)
   ```erlang
   end_per_suite(Config) ->
       % Force kill all test nodes
       Nodes = ?config(test_nodes, Config),
       [erlang:halt(Node) || Node <- Nodes],
       ok.
   ```

## CI/CD Integration

### GitHub Actions

The e2e-test.yml workflow runs automatically on:
- Push to `main` branch
- Pull requests targeting `main`
- Manual workflow dispatch

**Matrix execution**:
- 9 parallel jobs (3 modes × 3 OTP versions)
- Total duration: ~7-10 minutes (parallel execution)

**Viewing results**:
1. Navigate to repository → Actions tab
2. Select workflow run
3. Expand job logs (e.g., "E2E tls (OTP 25)")
4. Download artifacts for failed runs (30-day retention)

### Local CI Simulation

Run all matrix combinations locally:

```bash
#!/bin/bash
# simulate-ci.sh

MODES=("tls" "static" "variable")
OTP_VERSIONS=("23" "25" "27")

for mode in "${MODES[@]}"; do
    for otp in "${OTP_VERSIONS[@]}"; do
        echo "=========================================="
        echo "Running $mode mode tests on OTP $otp"
        echo "=========================================="

        # Switch OTP version (requires asdf or similar)
        asdf local erlang ${otp}.3

        # Run tests
        rebar3 ct --suite test/e2e/${mode}_mode_SUITE

        # Check result
        if [ $? -ne 0 ]; then
            echo "❌ FAILED: $mode on OTP $otp"
            exit 1
        else
            echo "✅ PASSED: $mode on OTP $otp"
        fi
    done
done

echo "✅ All tests passed across all modes and OTP versions!"
```

## Performance Benchmarking

### Measure Test Execution Time

```bash
# Time full suite
time rebar3 ct --suite test/e2e/tls_mode_SUITE,test/e2e/static_mode_SUITE,test/e2e/variable_mode_SUITE

# Expected output (approximate):
# real    8m32s
# user    2m15s
# sys     0m45s
```

### Profile Individual Test Cases

```erlang
% In test suite
test_tls_auto_discovery(Config) ->
    Start = erlang:monotonic_time(millisecond),

    % Test logic...

    End = erlang:monotonic_time(millisecond),
    Duration = End - Start,
    ct:log("Test duration: ~p ms", [Duration]),

    % Assert performance requirement
    ?assert(Duration < 10000, "Discovery should complete in <10s").
```

## Next Steps

- **Implement tests**: See `tasks.md` for implementation order
- **Add test cases**: Extend suites with edge cases from spec
- **CI integration**: Create `.github/workflows/e2e-test.yml` from contract
- **Documentation**: Update main README with E2E test section
