# Feature Specification: E2E Node Connection Tests

**Feature Branch**: `001-e2e-connection-tests`
**Created**: 2025-11-19
**Status**: Draft
**Input**: User description: "Create e2e test, test node connection with all connection method and auth method."

## Clarifications

### Session 2025-11-19

- Q: CI/CD Workflow Structure - How should the GitHub Actions workflow be organized for parallel test execution? → A: Single e2e-test.yml with matrix strategy - parallel jobs for each mode (TLS, static, variable port) across OTP versions
- Q: Test Artifacts Retention - How long should test artifacts be retained in CI/CD? → A: Retain test logs and failure diagnostics only for 30 days, delete successful run artifacts after 7 days

## User Scenarios & Testing *(mandatory)*

### User Story 1 - TLS Mode Connection Verification (Priority: P1)

Developers need automated end-to-end tests to verify that TLS mode connections work correctly with certificate-based authentication and mDNS auto-discovery across different group configurations.

**Why this priority**: TLS mode is the flagship feature requiring certificate validation, group isolation, and mDNS discovery. Critical for production deployments.

**Independent Test**: Can be fully tested by launching 2+ nodes with valid certificates in the same trust group, verifying automatic connection via mDNS, then testing group isolation with nodes in different groups. Delivers confidence that certificate-based trust groups work as specified.

**Acceptance Scenarios**:

1. **Given** multiple nodes with certificates from the same CA and matching OU fields, **When** nodes are started with TLS mode and mDNS enabled, **Then** nodes automatically discover each other and establish connections within 10 seconds
2. **Given** nodes with certificates from the same CA but different OU fields, **When** nodes attempt to connect, **Then** connection is rejected with group mismatch error
3. **Given** a node with an invalid or expired certificate, **When** attempting to connect to valid nodes, **Then** TLS handshake fails with certificate validation error
4. **Given** nodes in the same trust group with mDNS disabled, **When** nodes are started, **Then** manual connection via `net_adm:ping/1` succeeds using TLS authentication
5. **Given** connected nodes in TLS mode, **When** verifying cookie exchange, **Then** dynamic cookies are exchanged and Erlang distribution is established

---

### User Story 2 - Static Port Mode Connection Verification (Priority: P2)

Developers need automated end-to-end tests to verify that static port mode connections work correctly with shared cookie authentication and automatic mesh formation.

**Why this priority**: Static port mode is essential for backward compatibility and simple Docker deployments where all nodes use the same port.

**Independent Test**: Can be fully tested by launching 3+ nodes with the same port and shared cookie, verifying automatic mesh formation when any node connects to another. Delivers confidence that static port automatic meshing works.

**Acceptance Scenarios**:

1. **Given** multiple nodes configured with the same static port and shared cookie, **When** node A connects to node B, and node B connects to node C, **Then** all nodes form a complete mesh automatically
2. **Given** nodes with mismatched cookies, **When** attempting to connect, **Then** authentication fails with cookie verification error
3. **Given** nodes with the same cookie but different ports, **When** attempting to connect using static port mode, **Then** connection fails as port configuration doesn't match
4. **Given** nodes successfully connected in static port mode, **When** a new node joins with matching configuration, **Then** the new node automatically integrates into the existing mesh

---

### User Story 3 - Variable Port Mode Connection Verification (Priority: P3)

Developers need automated end-to-end tests to verify that variable port mode (client mode) works correctly with manual node registration and shared cookie authentication.

**Why this priority**: Variable port mode provides flexibility for dynamic port allocation scenarios. Lower priority as it requires manual configuration.

**Independent Test**: Can be fully tested by launching nodes with different ports, manually registering peer nodes via `gsmlg_epmd_client:add_node/2`, and verifying connections. Delivers confidence that manual registration works.

**Acceptance Scenarios**:

1. **Given** nodes with different ports and matching cookies, **When** peers are manually registered via `add_node/2`, **Then** connections are established successfully
2. **Given** a node with registered peers, **When** calling `net_adm:ping/1` for a registered node, **Then** connection succeeds using the registered port
3. **Given** nodes with registered peers and mismatched cookies, **When** attempting to connect, **Then** authentication fails with cookie mismatch error
4. **Given** a connected node, **When** calling `gsmlg_epmd_client:list_nodes/0`, **Then** all registered nodes are listed with their host and port information
5. **Given** a registered node, **When** calling `gsmlg_epmd_client:remove_node/1`, **Then** the node is unregistered and subsequent connection attempts fail

---

### Edge Cases

- What happens when TLS mode nodes attempt to connect during certificate expiration window?
- How does the system handle rapid node restarts (connection churn) in automatic mesh modes?
- What happens when mDNS discovery finds nodes but TLS handshake fails due to certificate issues?
- How does static port mode handle port conflicts when a new node tries to join?
- What happens when variable port mode has stale node registrations (nodes that went offline)?
- How does the system behave with mixed OTP versions (OTP 21-27) across connected nodes?
- What happens when network partitions occur and nodes reconnect?
- How does certificate revocation affect existing connections in TLS mode?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Test suite MUST verify TLS mode connections with valid certificates and matching OU fields result in successful automatic mesh formation
- **FR-002**: Test suite MUST verify TLS mode group isolation by ensuring nodes with different OU fields cannot connect
- **FR-003**: Test suite MUST verify mDNS auto-discovery in TLS mode by confirming nodes discover peers within 10 seconds
- **FR-004**: Test suite MUST verify static port mode automatic mesh formation when nodes connect with matching cookies
- **FR-005**: Test suite MUST verify variable port mode manual registration and connection via `gsmlg_epmd_client` API
- **FR-006**: Test suite MUST verify cookie authentication failures result in clear error messages for all modes
- **FR-007**: Test suite MUST verify certificate validation errors (expired, invalid CA, wrong OU) are properly reported in TLS mode
- **FR-008**: Test suite MUST verify dynamic cookie exchange in TLS mode by confirming cookies are generated and exchanged over TLS
- **FR-009**: Test suite MUST test across multiple OTP versions (minimum: OTP 23, 25, 27) to ensure compatibility
- **FR-010**: Test suite MUST verify all three modes support basic Erlang distribution operations (RPC, message passing, global registration)
- **FR-011**: Test suite MUST verify connection recovery after network interruptions for all modes
- **FR-012**: Test suite MUST verify proper cleanup and disconnection when nodes are stopped
- **FR-013**: GitHub Actions workflow (e2e-test.yml) MUST execute tests in parallel using matrix strategy with separate jobs for each connection mode (TLS, static, variable port) across OTP versions

### Non-Functional Requirements

- **NFR-001**: Test execution time MUST NOT exceed 10 minutes for the full suite across all modes
- **NFR-002**: Tests MUST be idempotent and runnable in parallel without conflicts
- **NFR-003**: Tests MUST provide clear failure diagnostics including mode, authentication method, and failure reason
- **NFR-004**: Test infrastructure MUST support running in both CI/CD environments (GitHub Actions matrix strategy) and local development with single command execution
- **NFR-005**: Tests MUST not leave orphaned processes or resources after completion
- **NFR-006**: Test coverage MUST include all three connection modes and both authentication methods (certificate-based and cookie-based)
- **NFR-007**: CI/CD artifacts MUST retain test logs and failure diagnostics for 30 days, with successful run artifacts deleted after 7 days to optimize storage

### Key Entities

- **Test Node**: A running Erlang node configured with one of the three EPMD modes, representing a cluster member under test
- **Trust Group**: A set of nodes with certificates containing the same OU field, used for TLS mode group isolation testing
- **Connection Matrix**: A mapping of which nodes should successfully connect under various mode and authentication configurations
- **Test Certificate Set**: Collection of CA certificates, valid node certificates, invalid certificates, and expired certificates for comprehensive TLS testing
- **Test Scenario**: A specific combination of connection mode, authentication method, node configuration, and expected outcome

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All three connection modes (TLS, static, variable port) can be verified with automated tests showing 100% pass rate for valid configurations
- **SC-002**: TLS mode group isolation is validated with tests confirming 0% connection success rate between nodes in different trust groups
- **SC-003**: mDNS auto-discovery in TLS mode completes within 10 seconds in 95% of test runs
- **SC-004**: Static port mode automatic mesh formation completes within 5 seconds for 3-node clusters
- **SC-005**: Test suite detects and reports all authentication failures (certificate errors, cookie mismatches) with actionable error messages
- **SC-006**: Test coverage includes at least 3 OTP versions (23, 25, 27) with all tests passing on each version
- **SC-007**: Full test suite execution completes in under 10 minutes in CI/CD environments
- **SC-008**: Tests can detect regressions in connection logic with 100% accuracy (no false positives or negatives)
- **SC-009**: Test infrastructure can be executed locally by developers with a single command
- **SC-010**: Each test scenario produces clear pass/fail results with diagnostic information for debugging failures

### Test Coverage Goals

- **Coverage-001**: All three connection modes tested independently
- **Coverage-002**: Both authentication methods (certificate-based TLS and shared cookie) validated
- **Coverage-003**: Group isolation verified for TLS mode with at least 2 different trust groups
- **Coverage-004**: Certificate validation tested with valid, expired, and invalid CA certificates
- **Coverage-005**: Network failure recovery tested for all modes
- **Coverage-006**: OTP compatibility verified across 3 major versions (21-27 range)
- **Coverage-007**: Connection API operations tested (manual registration, node listing, removal)

## Assumptions

1. Test infrastructure has access to generate valid and invalid TLS certificates for testing
2. Test environment supports running multiple Erlang nodes simultaneously (minimum 4 nodes for comprehensive testing)
3. mDNS multicast is available in test network environments (may need special configuration in Docker/CI)
4. Tests can bind to multiple ports for different test scenarios without conflicts
5. Test execution environment has OTP 21+ installed (specific versions may be tested via CI matrix)
6. Certificate generation tools (OpenSSL) are available in test environment
7. Test scenarios can simulate network partitions and recovery for resilience testing
8. Test framework can capture and assert on Erlang distribution connection events
