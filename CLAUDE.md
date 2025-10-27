# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **GSMLG EPMD**, a sophisticated fork of `epmdless` that enables Erlang/Elixir distribution without requiring the EPMD (Erlang Port Mapper Daemon). It provides three main strategies for node connectivity:

- **gsmlg_epmd_static**: Static port - all nodes use the same port (creates automatic mesh) [ORIGINAL]
- **gsmlg_epmd_client**: Variable ports - nodes manually register peer ports (requires explicit `add_node/2` calls) [ORIGINAL]
- **gsmlg_epmd_tls**: TLS-based trust groups with mDNS auto-discovery and dynamic cookie exchange [NEW ⭐]

### What's New in GSMLG EPMD

The project adds a complete **CA-based trust system** with:
- Certificate-based authentication and group membership (via OU field)
- mDNS service discovery (`_epmd._tcp.local`)
- Secure dynamic cookie exchange over TLS
- Automatic mesh formation within trust groups
- Group isolation (different OUs can't connect)

## Build and Development Commands

### Compilation
```bash
rebar3 compile
```

### Static Analysis
```bash
rebar3 dialyzer
```

### Testing
Tests use [shelltestrunner](https://github.com/simonmichael/shelltestrunner/):
```bash
# Run tests from shelltests directory
cd shelltests
./run_tests.sh
```

The test script:
- Downloads latest rebar3 nightly
- Builds a release in `shelltests/epmdless_test/`
- Tests daemon start/stop with `ERL_DIST_PORT=9001`

### Certificate Generation (for TLS mode)
```bash
# Generate certificates for nodes in a trust group
./tools/generate_certs.sh production node1
./tools/generate_certs.sh production node2

# Generate certificates for different groups
./tools/generate_certs.sh staging node3

# Output in certs/ directory:
# certs/ca/ca-cert.pem, ca-key.pem
# certs/production/node1/cert.pem, key.pem, ca-cert.pem
```

### Building a Release (using examples)
```bash
# For TLS auto-mesh example (NEW)
cd examples/tls_auto_mesh
make certs        # Generate certificates
make up           # Start with docker-compose
make shell-node1  # Connect to node1

# For variable ports example
cd examples/erlang_variable_ports_example
rebar3 release

# For Docker static port example
cd examples/erlang_docker_example
docker-compose up
```

## Architecture

### Core Modules

#### Original EPMD Modules (Renamed)

**src/gsmlg_epmd_client.erl**: Variable port EPMD module
- Implements `gen_server` and EPMD callback behavior (`-epmd_module`)
- Maintains state mapping of node names to ports via `add_node/2`, `remove_node/1`, `list_nodes/0`
- Port determined by `ERL_DIST_PORT` environment variable
- Nodes must be manually registered - does NOT automatically create mesh networks

**src/gsmlg_epmd_static.erl**: Static port EPMD module
- All nodes use same port (from `ERL_DIST_PORT` env var or `-erl_epmd_port` VM arg)
- Automatically creates full mesh when nodes connect (no manual registration)
- Simpler setup for Docker/containerized deployments

**src/gsmlg_epmd_dist.erl**: Distribution protocol helper
- Configures TLS/TCP socket options for distribution
- Helper API wrapping gsmlg_epmd_client

**src/gsmlg_epmd_proto_dist.erl**: Protocol distribution module
- Lower-level protocol implementation for custom distribution

#### NEW: TLS Trust Group Modules

**src/gsmlg_epmd_tls.erl**: Main EPMD callback for TLS mode (228 lines)
- Implements complete EPMD callback behavior (`-epmd_module`)
- Coordinates TLS server and mDNS services
- Manages discovered node registry
- Dynamically starts TLS server and mDNS on node registration
- OTP 21-23+ compatible

**src/gsmlg_epmd_cert.erl**: Certificate management (217 lines)
- Loads certificates from environment variables or application config
- Validates certificate chains against CA (supports intermediate CAs)
- Extracts group name from certificate OU (Organizational Unit) field
- Provides TLS options for server/client connections
- Custom verify_fun for group-based validation

**src/gsmlg_epmd_cookie.erl**: Secure cookie exchange (224 lines)
- Generates 256-bit cryptographically secure random cookies
- Implements binary exchange protocol over TLS
- Stores remote node cookies in gen_server state
- Protocol versioning (v1) for future compatibility
- Cookies used for Erlang distribution authentication

**src/gsmlg_epmd_tls_server.erl**: TLS connection acceptor (221 lines)
- Listens on configured port (default 4369) for incoming TLS connections
- Performs mutual TLS authentication (both client and server validate certs)
- Validates group membership from certificate OU field
- Triggers cookie exchange after successful auth
- Notifies main EPMD module about discovered nodes

**src/gsmlg_epmd_mdns.erl**: Service discovery via mDNS (242 lines)
- Advertises local node as `_epmd._tcp.local` service
- Discovers peers via mDNS subscription using gproc pub/sub
- Auto-connects to discovered nodes with matching groups
- Triggers TLS authentication for new discoveries
- Integrates with shortishly/mdns library

**src/gsmlg_epmd_sup.erl**: Application supervisor (50 lines)
- one_for_one supervision strategy (10 restarts / 60 seconds)
- Starts gsmlg_epmd_cookie and gsmlg_epmd_tls immediately
- TLS server and mDNS are dynamically started by gsmlg_epmd_tls

**src/gsmlg_epmd_app.erl**: Application callback (14 lines)
- Standard OTP application behavior
- Starts gsmlg_epmd_sup supervisor tree

**src/gsmlg_epmd.hrl**: Shared logging macros
- OTP 21-23+ compatible logging macros
- Supports both new logger (OTP 21+) and legacy error_logger

### Key Configuration Patterns

**VM Args for Static Port (vm.args.src)**:
```erlang
-start_epmd false
-epmd_module gsmlg_epmd_static
-erl_epmd_port 8001
```

**VM Args for Variable Ports (vm.args.src)**:
```erlang
-start_epmd false
-epmd_module gsmlg_epmd_client
# No -erl_epmd_port, use ERL_DIST_PORT env var instead
```

**VM Args for TLS Auto-Mesh (vm.args.src)** [NEW]:
```erlang
-sname node@localhost
-setcookie temporary  # Replaced by dynamic exchange
-start_epmd false
-epmd_module gsmlg_epmd_tls
-proto_dist inet_tls
-ssl_dist_optfile /path/to/ssl_dist.config
```

**Environment Variables for TLS Mode**:
```bash
# Required: Certificate paths
export GSMLG_EPMD_TLS_CERTFILE=/path/to/cert.pem
export GSMLG_EPMD_TLS_KEYFILE=/path/to/key.pem
export GSMLG_EPMD_TLS_CACERTFILE=/path/to/ca-cert.pem

# Required: Distribution port
export ERL_DIST_PORT=8001

# Optional: TLS server port (default 4369)
export GSMLG_EPMD_TLS_PORT=4369

# Optional: Override certificate OU for group
export GSMLG_EPMD_GROUP=production

# Optional: Feature flags (default true)
export GSMLG_EPMD_AUTO_CONNECT=true
export GSMLG_EPMD_MDNS_ENABLE=true
```

**Application Config for TLS (sys.config)**:
```erlang
{gsmlg_epmd, [
    {tls_certfile, "/path/to/cert.pem"},
    {tls_keyfile, "/path/to/key.pem"},
    {tls_cacertfile, "/path/to/ca.pem"},
    {tls_port, 4369},
    {group, "production"},
    {auto_connect, true},
    {mdns_enabled, true}
]}.
```

**SSL Distribution Config (ssl_dist.config)**:
```erlang
[
  {server, [
    {certfile, "/path/to/cert.pem"},
    {keyfile, "/path/to/key.pem"},
    {cacertfile, "/path/to/ca.pem"},
    {verify, verify_peer},
    {fail_if_no_peer_cert, true}
  ]},
  {client, [
    {certfile, "/path/to/cert.pem"},
    {keyfile, "/path/to/key.pem"},
    {cacertfile, "/path/to/ca.pem"},
    {verify, verify_peer}
  ]}
].
```

**Rebar3 Config Pattern**:
```erlang
{deps, [
    {gsmlg_epmd, {git, "https://github.com/gsmlg-dev/gsmlg_epmd", {branch, "master"}}}
]}.

{relx, [{release, {my_app, "1.0.0"},
         [gsmlg_epmd,  % Include in release, not in .app.src
          my_app]},
        {vm_args_src, "config/vm.args.src"}]}.
```
- Include `gsmlg_epmd` in release applications list (not in .app.src dependencies)
- It's a deployment dependency, not a runtime application dependency

### OTP Version Handling

The codebase supports OTP 21+, with special handling:
- OTP 23+ uses distribution protocol version 6
- OTP 22 and earlier use version 5
- OTP 23+ supports `-dist_listen false` for remote shells (no port binding needed)
- Pre-OTP-23 requires `EPMDLESS_REMSH_PORT` environment variable for remote connections

## Development Environment

Uses `devenv` (Nix-based):
- Elixir/Erlang toolchain via `languages.elixir.enable = true`
- Package: `pkgs-stable.beam27Packages.elixir`
- Run `devenv shell` or use direnv integration

## GitHub Actions

Workflow `.github/workflows/main.yml` runs on push/PR to master:
- Compiles code with `rebar3 compile`
- Runs static analysis with `rebar3 dialyzer`
- Executes shell tests via `shelltests/run_tests.sh`

Note: CI only performs static checks and analysis (no unit tests, per global instructions).

## Important Behavioral Notes

### Variable Ports (gsmlg_epmd_client)
- **Manual mesh management**: If node A connects to B and C, B and C won't connect unless explicitly configured
- Each node maintains its own mapping table
- Use `gsmlg_epmd_client:add_node(NodeName, Port)` before connecting
- No automatic discovery or connection

### Static Ports (gsmlg_epmd_static)
- **Automatic mesh**: All nodes discover each other when one node initiates connections
- Simpler for container orchestration (Docker Compose, Kubernetes)
- All nodes must use identical port configuration
- Requires shared cookie across all nodes

### TLS Auto-Mesh (gsmlg_epmd_tls) [NEW]
- **Zero-configuration discovery**: Nodes automatically discover each other via mDNS (`_epmd._tcp.local`)
- **Certificate-based trust**: Only nodes with certificates signed by the same CA can connect
- **Group isolation**: Nodes with different OU (Organizational Unit) fields cannot connect, even with same CA
- **Dynamic cookies**: Each node generates a random 256-bit cookie, securely exchanged over TLS
- **Automatic mesh formation**: Discovered nodes auto-authenticate and connect within trust groups
- **Service lifecycle**:
  - TLS server and mDNS services start dynamically on first node registration
  - Services remain active for lifetime of node
  - Cookie exchange happens before Erlang distribution connection
- **Security model**:
  - Mutual TLS authentication (both client and server validate certificates)
  - Full certificate chain validation (supports intermediate CAs)
  - Group membership verified from certificate OU field
  - Failed auth = connection rejected, no retry
- **No pre-shared secrets**: Cookie exchange replaces traditional shared cookie requirement

### Remote Connections
- OTP 23+: Use `ERL_DIST_PORT` with `-dist_listen false` for remote shells
- Pre-OTP-23: Use `EPMDLESS_REMSH_PORT` for the target port, optionally set `ERL_DIST_PORT` for local port
- TLS mode: Remote console requires valid certificate with matching group OU

## Example Projects

- **`examples/tls_auto_mesh/`** [NEW]: TLS auto-mesh with Docker Compose
  - 4 nodes: 3 in "production" group, 1 in "staging" group
  - Demonstrates auto-discovery via mDNS, group isolation, dynamic cookie exchange
  - Complete with certificate generation, Docker setup, and verification scripts
  - See `examples/tls_auto_mesh/README.md` for full walkthrough

- **`examples/erlang_docker_example/`**: Docker Compose setup with static ports
  - Traditional static port configuration
  - Shared cookie required
  - Manual mesh via explicit connections

- **`examples/erlang_variable_ports_example/`**: Variable ports with manual registration
  - Dynamic port allocation
  - Requires explicit `gsmlg_epmd_client:add_node/2` calls
  - Manual mesh management

- **`shelltests/epmdless_test/`**: Test project for CI validation
  - Shell-based integration tests
  - Tests daemon mode, remote console, basic connectivity
