<!--
Sync Impact Report:
- Version Change: 1.0.0 → 1.1.0 (MINOR: Expanded Security-First Design principle)
- Modified Principles:
  * Principle I (Security-First Design): Expanded to clarify multi-mode security model
    - Added distinction between TLS mode (certificate-based) and traditional modes (cookie-based)
    - Clarified that TLS security requirements apply specifically to gsmlg_epmd_tls mode
    - Maintained backward compatibility principle alignment
- Added Sections: Multi-mode security guidance in Principle I
- Removed Sections: None
- Templates Status:
  ✅ plan-template.md: No changes required (generic constitution check)
  ✅ spec-template.md: No changes required (requirements structure unchanged)
  ✅ tasks-template.md: No changes required (task categorization unchanged)
- Follow-up TODOs: None
- Rationale: User clarified that the package supports both auto-discovery (mDNS) and manual
  config, plus both TLS auth and pre-shared key (cookie) auth. The original v1.0.0
  over-emphasized certificate-based security as the "primary value proposition" when in fact
  the package supports three distinct modes with different security models.
-->

# GSMLG EPMD Constitution

## Core Principles

### I. Security-First Design

**MUST**: Every feature involving network communication, authentication, or cryptographic operations MUST undergo security review before implementation.

**Multi-Mode Security Model**: GSMLG EPMD supports three operational modes with different security characteristics:
- **gsmlg_epmd_tls** (TLS mode): Certificate-based authentication with trust groups
- **gsmlg_epmd_static** (static port): Shared cookie authentication
- **gsmlg_epmd_client** (variable port): Shared cookie authentication with manual registration

Security requirements below apply according to the operational mode in use.

**MUST**: When using TLS mode (gsmlg_epmd_tls), certificate management MUST follow industry best practices:
- Private keys MUST have 400 permissions (read-only by owner)
- CA private keys MUST be kept offline in production environments
- Certificate validity periods MUST NOT exceed 2 years (1 year recommended)
- All TLS connections MUST use TLS 1.2 minimum (TLS 1.3 preferred)
- Mutual TLS authentication MUST be enforced for inter-node communication
- Group isolation via OU field MUST be validated during TLS handshake

**MUST**: When using traditional modes (static/client), cookie security MUST be maintained:
- Cookies MUST be cryptographically random (256-bit when generated dynamically)
- Cookie distribution MUST follow secure deployment practices
- Cookie rotation procedures MUST be documented and supported

**SHOULD**: TLS mode SHOULD be preferred for production deployments requiring zero-configuration auto-discovery and group isolation.

**Rationale**: GSMLG EPMD provides both modern certificate-based security (TLS mode) and traditional cookie-based security (static/client modes). Each mode has distinct threat models and security requirements. TLS mode offers advanced features like auto-discovery via mDNS, dynamic cookie exchange, and certificate-based trust groups, while traditional modes maintain backward compatibility with original epmdless functionality. Security standards must be mode-appropriate rather than universally certificate-centric.

### II. Backward Compatibility

**MUST**: Original epmdless functionality (static port and variable port modes) MUST remain fully functional and receive bug fixes.

**MUST**: API changes to existing modules (`gsmlg_epmd_static`, `gsmlg_epmd_client`) MUST follow semantic versioning with deprecation warnings before removal.

**SHOULD**: New features SHOULD be additive and not break existing deployments without explicit migration paths.

**Rationale**: Users relying on the original epmdless functionality must be able to upgrade without disruption. The TLS trust group feature is an addition, not a replacement.

### III. Test-Driven Development (NON-NEGOTIABLE)

**MUST**: All new code MUST have corresponding tests written and approved before implementation.

**MUST**: Test coverage for security-critical modules (certificate validation, TLS handshake, cookie exchange) MUST be 100%.

**MUST**: Tests MUST follow Red-Green-Refactor cycle:
1. Write failing tests
2. Implement minimum code to pass
3. Refactor while keeping tests green

**MUST**: Pull requests without tests MUST be rejected unless explicitly marked as documentation-only or infrastructure.

**Rationale**: Given the security-critical nature of this project, untested code is unacceptable. The TLS trust system has already achieved 8/8 passing tests (100%) and this standard must be maintained.

### IV. OTP Compatibility

**MUST**: All code MUST support OTP 21+ (current support range: OTP 21-27).

**MUST**: OTP version-specific features MUST be gated with appropriate preprocessor directives (`-ifdef(OTP_RELEASE)`).

**MUST**: CI/CD workflows MUST test against multiple OTP versions (currently: 23, 24, 25, 26, 27).

**SHOULD**: Deprecation of old OTP versions MUST follow Erlang/OTP's official support lifecycle with 6-month advance notice.

**Rationale**: Erlang/Elixir ecosystems have diverse OTP version requirements. Maintaining broad compatibility ensures maximum adoption while allowing modernization as old versions phase out.

### V. Documentation as Code

**MUST**: Every new module MUST include:
- Module-level documentation (`@doc`) explaining purpose and usage
- Function-level documentation (`@spec` and `@doc`) for all public APIs
- Usage examples in README or dedicated example projects

**MUST**: Security-sensitive features MUST have corresponding sections in `SECURITY.md`.

**MUST**: Breaking changes MUST be documented in `CHANGELOG.md` (to be created) with migration guides.

**SHOULD**: Architecture documentation (CLAUDE.md) MUST be updated for significant structural changes.

**Rationale**: Documentation is not optional - it's part of the codebase. The project's comprehensive documentation (2,500+ lines) is a competitive advantage that must be maintained.

### VI. Observability and Debugging

**MUST**: All critical operations (TLS handshake, certificate validation, cookie exchange, mDNS discovery) MUST emit structured log messages.

**MUST**: Logging MUST use OTP 21+ logger API with graceful fallback to error_logger for older versions.

**MUST**: Error messages MUST be actionable:
- Include error codes or categories
- Suggest remediation steps where applicable
- Never expose sensitive data (private keys, cookies)

**SHOULD**: Metrics and telemetry integration SHOULD be supported through standard Erlang telemetry libraries.

**Rationale**: In production environments, observability is critical for diagnosing cluster formation issues, certificate problems, and network connectivity failures.

## Security Requirements

### Certificate Lifecycle Management (TLS Mode Only)

**MUST**: Certificate generation tools MUST enforce:
- Minimum 2048-bit RSA keys (4096-bit recommended)
- Proper OU field extraction and validation
- Certificate chain validation including intermediate CAs

**MUST**: Certificate expiration MUST be monitored, with warnings emitted 30 days before expiry.

**MUST NOT**: Certificates MUST NOT be committed to version control (enforced by `.gitignore`).

### Cryptographic Standards

**MUST**: Cookie generation (TLS mode dynamic exchange) MUST use `crypto:strong_rand_bytes/1` for 256-bit (32-byte) cryptographically secure random values.

**MUST**: TLS cipher suites (TLS mode) MUST exclude weak ciphers (RC4, DES, 3DES, MD5).

**MUST**: TLS configuration (TLS mode) MUST set `verify_peer` and `fail_if_no_peer_cert` to true for all inter-node connections.

**SHOULD**: Pre-shared cookies (static/client modes) SHOULD be generated using cryptographically secure random number generators.

### Group Isolation (TLS Mode Only)

**MUST**: Group membership validation MUST be enforced at the TLS handshake level.

**MUST**: Cross-group connection attempts MUST be rejected with clear error messages identifying the group mismatch.

**MUST**: Group names (OU values) MUST be case-sensitive and validated against a defined pattern (e.g., alphanumeric + hyphen/underscore).

## Development Workflow

### Code Quality Gates

**MUST**: All pull requests MUST pass:
1. Compilation without warnings (lint workflow with `--warnings-as-errors`)
2. Elvis style checking (no violations)
3. EUnit tests (all tests passing)
4. Dialyzer analysis (warnings reported but not blocking per current policy)

**MUST**: Code review MUST verify:
- Adherence to constitution principles
- Test coverage for new code
- Documentation completeness
- Security implications of changes

### Branching and Releases

**SHOULD**: Feature development SHOULD use feature branches named `feat/<feature-name>`.

**SHOULD**: Bug fixes SHOULD use branches named `fix/<issue-description>`.

**MUST**: Release versions MUST follow semantic versioning (MAJOR.MINOR.PATCH):
- MAJOR: Breaking changes to public APIs or certificate validation logic
- MINOR: New features (e.g., new discovery mechanisms, additional certificate validation)
- PATCH: Bug fixes, documentation, non-breaking improvements

**MUST**: Releases MUST include:
- Updated CHANGELOG.md with all changes since last release
- Git tag matching version number
- GitHub release with compiled release notes

### Continuous Integration

**MUST**: Two separate workflows MUST be maintained:
1. **Lint Workflow** (`lint.yml`): Compilation, style checking, Dialyzer
2. **Test Workflow** (`test.yml`): EUnit tests, shell integration tests

**MUST**: Matrix testing MUST cover:
- Lint: OTP 23, 24, 25, 26, 27
- Test: OTP 23, 25, 27 (subset for faster feedback)

**MUST**: CI failures MUST block merging to main branch.

## Performance Standards

### Resource Constraints

**SHOULD**: Memory footprint per node SHOULD NOT exceed 5 MB for the gsmlg_epmd application alone.

**SHOULD**: TLS handshake completion (TLS mode) SHOULD NOT exceed 500ms on modern hardware with network latency <50ms.

**SHOULD**: mDNS discovery (TLS mode) SHOULD complete within 5 seconds on local networks.

**MAY**: Performance optimizations that compromise security or maintainability MAY be rejected.

### Scalability Targets

**SHOULD**: Certificate storage (TLS mode) SHOULD scale to 1,000+ nodes without requiring external databases (in-memory is acceptable).

**SHOULD**: Cookie exchange protocol (TLS mode) SHOULD handle 10+ simultaneous connections without blocking.

**MUST**: Group isolation checks (TLS mode) MUST be O(1) - constant time regardless of cluster size.

## Governance

### Amendment Process

**MUST**: Constitution amendments REQUIRE:
1. Proposed changes documented in pull request with rationale
2. Version bump following semantic versioning rules:
   - MAJOR: Removal or redefinition of existing principles
   - MINOR: Addition of new principles or substantial guidance expansion
   - PATCH: Clarifications, typo fixes, non-semantic improvements
3. Update of dependent templates (plan, spec, tasks, checklist)
4. Approval from project maintainer(s)
5. Migration plan for affected codebases (if breaking changes)

### Constitution Supremacy

**MUST**: All code reviews, design decisions, and architectural choices MUST be validated against this constitution.

**MUST**: Violations of NON-NEGOTIABLE principles MUST result in immediate rejection of pull requests.

**SHOULD**: Deviations from SHOULD/MAY guidelines MUST be explicitly justified in commit messages or pull request descriptions.

### Compliance Review

**MUST**: Quarterly compliance audits MUST verify:
- All modules have adequate test coverage
- Security best practices are followed
- Documentation is up-to-date
- Certificate management tools follow current standards

**MUST**: Audit findings MUST be documented and tracked to resolution.

### Runtime Development Guidance

**MUST**: For AI assistants (Claude, GitHub Copilot, etc.), refer to `CLAUDE.md` for project-specific development patterns and module architecture.

**MUST**: For security-sensitive changes, consult `SECURITY.md` for threat model and best practices.

**MUST**: For testing patterns, refer to `test/README.md` for test helper usage and coverage expectations.

---

**Version**: 1.1.0 | **Ratified**: 2025-11-18 | **Last Amended**: 2025-11-19
