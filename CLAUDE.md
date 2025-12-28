# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**GSMLG EPMD** is a fork of `epmdless` enabling Erlang/Elixir distribution without EPMD. It provides three strategies for node connectivity:

- **gsmlg_epmd_static**: Static port - all nodes use the same port (automatic mesh)
- **gsmlg_epmd_client**: Variable ports - nodes manually register peer ports
- **gsmlg_epmd_tls**: TLS-based trust groups with mDNS auto-discovery and dynamic cookie exchange

### TLS Mode Features
- Certificate-based authentication with group membership via OU field
- mDNS service discovery (`_epmd._tcp.local`)
- Secure dynamic cookie exchange over TLS
- Automatic mesh formation within trust groups
- Group isolation (different OUs can't connect)

## Build and Test Commands

```bash
# Compile
rebar3 compile

# Static analysis
rebar3 dialyzer

# EUnit tests (cert and cookie modules)
rebar3 eunit

# E2E tests (Common Test suites)
rebar3 ct --suite test/e2e/tls_mode_SUITE
rebar3 ct --suite test/e2e/static_mode_SUITE
rebar3 ct --suite test/e2e/variable_mode_SUITE

# All E2E tests
rebar3 ct --suite test/e2e/tls_mode_SUITE,test/e2e/static_mode_SUITE,test/e2e/variable_mode_SUITE

# Shell integration tests
cd shelltests && ./run_tests.sh

# Style checking
rebar3 lint
```

## Development Environment

Uses `devenv` (Nix-based) with Erlang/OTP 27 and Elixir:
```bash
devenv shell  # or use direnv integration
```

## Architecture

### Core Modules

| Module | Purpose |
|--------|---------|
| `gsmlg_epmd_static` | Static port EPMD - all nodes use same port, auto-mesh |
| `gsmlg_epmd_client` | Variable port EPMD - manual node registration via `add_node/2` |
| `gsmlg_epmd_tls` | TLS mode EPMD callback - coordinates TLS server, mDNS, node registry |
| `gsmlg_epmd_cert` | Certificate loading, CA validation, group extraction from OU |
| `gsmlg_epmd_cookie` | 256-bit cookie generation and TLS exchange protocol |
| `gsmlg_epmd_tls_server` | TLS listener with mutual auth |
| `gsmlg_epmd_mdns` | mDNS `_epmd._tcp.local` advertisement and discovery |
| `gsmlg_epmd_sup` | Supervisor - starts cookie/tls immediately, mdns/tls_server dynamically |

### Test Structure

```
test/
├── gsmlg_epmd_cert_tests.erl    # EUnit - certificate operations
├── gsmlg_epmd_cookie_tests.erl  # EUnit - cookie generation/exchange
└── e2e/
    ├── common/                   # Shared test helpers (auto-compiled by CT)
    ├── tls_mode_SUITE.erl       # TLS auto-discovery, group isolation
    ├── static_mode_SUITE.erl    # Static port auto-mesh
    └── variable_mode_SUITE.erl  # Manual registration
```

## Configuration Patterns

### VM Args by Mode

**Static Port:**
```erlang
-start_epmd false
-epmd_module gsmlg_epmd_static
-erl_epmd_port 8001
```

**Variable Ports:**
```erlang
-start_epmd false
-epmd_module gsmlg_epmd_client
# Use ERL_DIST_PORT env var
```

**TLS Auto-Mesh:**
```erlang
-start_epmd false
-epmd_module gsmlg_epmd_tls
-proto_dist inet_tls
-ssl_dist_optfile /path/to/ssl_dist.config
```

### TLS Environment Variables

```bash
GSMLG_EPMD_TLS_CERTFILE=/path/to/cert.pem    # Required
GSMLG_EPMD_TLS_KEYFILE=/path/to/key.pem      # Required
GSMLG_EPMD_TLS_CACERTFILE=/path/to/ca.pem    # Required
ERL_DIST_PORT=8001                            # Required
GSMLG_EPMD_TLS_PORT=4369                      # Optional (default 4369)
GSMLG_EPMD_GROUP=production                   # Optional (overrides cert OU)
GSMLG_EPMD_AUTO_CONNECT=true                  # Optional (default true)
GSMLG_EPMD_MDNS_ENABLE=true                   # Optional (default true)
```

### Release Configuration

```erlang
{deps, [{gsmlg_epmd, {git, "https://github.com/gsmlg-dev/gsmlg_epmd", {branch, "main"}}}]}.

{relx, [{release, {my_app, "1.0.0"},
         [gsmlg_epmd,  % Include in release, not in .app.src
          my_app]},
        {vm_args_src, "config/vm.args.src"}]}.
```

## Certificate Generation

```bash
./tools/generate_certs.sh <group_name> <node_name>

# Example
./tools/generate_certs.sh production node1
./tools/generate_certs.sh staging node2

# Output: certs/<group>/<node>/{cert.pem, key.pem, ca-cert.pem}
```

## Behavioral Notes

### Static Mode (gsmlg_epmd_static)
- All nodes use identical port
- Automatic full mesh when nodes connect
- Requires shared cookie

### Variable Mode (gsmlg_epmd_client)
- Manual mesh: `gsmlg_epmd_client:add_node(NodeName, Port)` before connecting
- Each node maintains its own mapping table
- No automatic discovery

### TLS Mode (gsmlg_epmd_tls)
- Zero-config: mDNS discovery + cert-based auth
- Group isolation via certificate OU field
- Dynamic cookies exchanged over TLS (no pre-shared secrets)
- Services start dynamically on first node registration

## OTP Version Support

- **Supported**: OTP 26, 27 (CI test matrix)
- **OTP 23+**: Distribution protocol v6, `-dist_listen false` for remote shells
- **Pre-OTP-23**: Protocol v5, use `EPMDLESS_REMSH_PORT` for remote connections

## GitHub Actions

Three workflows on push/PR to `main`:
- **E2E Tests**: 3 modes × 2 OTP versions (26, 27)
- **Lint**: Elvis style checker, Dialyzer
- **Test**: EUnit tests, shell integration tests
