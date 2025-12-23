# Implementation Plan: E2E Node Connection Tests

**Branch**: `001-e2e-connection-tests` | **Date**: 2025-11-19 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-e2e-connection-tests/spec.md`

## Summary

Create comprehensive end-to-end tests for all three GSMLG EPMD connection modes (TLS with certificate-based auth, static port with shared cookies, variable port with manual registration) across multiple OTP versions. Tests will run in parallel via GitHub Actions matrix strategy, validate connection establishment, authentication failures, group isolation, and Erlang distribution operations. Implementation follows Test-Driven Development with 100% coverage requirement per constitution.

## Technical Context

**Language/Version**: Erlang/OTP 21-27 (test matrix: OTP 23, 25, 27)
**Primary Dependencies**:
- EUnit (built-in testing framework)
- Common Test (CT) for e2e scenarios
- OpenSSL for certificate generation
- existing gsmlg_epmd modules (tls, static, client)

**Storage**: Filesystem for test certificates and temporary node data (ephemeral, cleaned after tests)
**Testing**: Common Test (CT) suites for e2e scenarios, EUnit for helper modules
**Target Platform**: Linux (GitHub Actions Ubuntu), macOS, Docker containers
**Project Type**: Test infrastructure (extends existing single-project Erlang application)
**Performance Goals**:
- Full test suite < 10 minutes CI execution
- mDNS discovery < 10 seconds
- Static mesh formation < 5 seconds
- Parallel execution of 9 matrix jobs (3 modes × 3 OTP versions)

**Constraints**:
- Tests must be idempotent and parallelizable
- No port conflicts between concurrent test runs
- mDNS multicast availability in CI
- Certificate generation on-the-fly per test suite
- Clean resource teardown (no orphaned processes)

**Scale/Scope**:
- 3 connection modes × 3 OTP versions = 9 parallel CI jobs
- ~30-40 individual test scenarios across all modes
- 4+ concurrent Erlang nodes per test scenario (for mesh/isolation testing)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Principle III: Test-Driven Development (NON-NEGOTIABLE)

✅ **PASS**: This feature IS the test infrastructure itself
- Tests will be written first (Red-Green-Refactor applies to test helpers/infrastructure)
- Test coverage for test helpers will be 100% per constitution
- All PR changes to tests require corresponding validation

### Principle I: Security-First Design

✅ **PASS**: Security testing is core purpose
- TLS certificate validation tests cover all security scenarios
- Cookie authentication failure tests verify proper rejection
- Group isolation tests validate OU field enforcement
- Certificate generation follows best practices (2048-bit RSA minimum)
- No certificates committed to version control

### Principle IV: OTP Compatibility

✅ **PASS**: Multi-version testing is explicit requirement
- Test matrix covers OTP 23, 25, 27 (constitution requires 23, 24, 25, 26, 27 for production)
- Tests will use OTP-agnostic Common Test framework
- No OTP version-specific test code unless gated with preprocessor directives

### Principle VI: Observability and Debugging

✅ **PASS**: Test diagnostics are comprehensive
- Clear failure messages with mode, auth method, and failure reason
- Structured logging of test events
- Artifact retention (30 days logs, 7 days success artifacts)
- Test output includes node connection states and error details

### Principle V: Documentation as Code

✅ **PASS**: Documentation will be comprehensive
- quickstart.md will document local test execution
- README updates for CI/CD integration
- Test helper modules will have full @doc and @spec annotations

## Project Structure

### Documentation (this feature)

```text
specs/001-e2e-connection-tests/
├── plan.md              # This file
├── research.md          # Phase 0: Test framework patterns, CI matrix strategy
├── data-model.md        # Phase 1: Test entities, certificate structures, connection matrices
├── quickstart.md        # Phase 1: Local execution guide, troubleshooting
├── contracts/           # Phase 1: GitHub Actions workflow schema, test result formats
└── tasks.md             # Phase 2: Task decomposition (created by /speckit.tasks)
```

### Source Code (repository root)

```text
# Existing Erlang project structure (single project)
test/
├── e2e/                          # NEW: E2E test suites
│   ├── tls_mode_SUITE.erl       # TLS mode connection tests
│   ├── static_mode_SUITE.erl    # Static port mode tests
│   ├── variable_mode_SUITE.erl  # Variable port mode tests
│   ├── common/                   # Shared test utilities
│   │   ├── test_node_manager.erl  # Node lifecycle management
│   │   ├── test_cert_generator.erl # Dynamic certificate generation
│   │   ├── test_connection_helper.erl # Connection assertions
│   │   └── test_cleanup.erl      # Resource cleanup utilities
│   └── data/                     # Test data templates
│       ├── vm.args.template      # VM args templates per mode
│       └── sys.config.template   # Config templates
│
├── gsmlg_epmd_cert_tests.erl     # EXISTING: Unit tests
├── gsmlg_epmd_cookie_tests.erl   # EXISTING: Unit tests
└── test_helpers.erl               # EXISTING: Test utilities

.github/
└── workflows/
    └── e2e-test.yml              # NEW: E2E test workflow (matrix strategy)
```

**Structure Decision**: Extending existing single-project Erlang structure with dedicated `test/e2e/` directory for end-to-end test suites. Common Test framework requires `*_SUITE.erl` naming convention. Test helpers in `common/` subdirectory for reusability across suites. GitHub Actions workflow added to `.github/workflows/` following existing CI pattern (lint.yml, test.yml already present).

## Complexity Tracking

> **No constitution violations - this section intentionally left empty per template guidance.**
