# GSMLG EPMD - Erlang Distribution without EPMD

![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)
![OTP](https://img.shields.io/badge/OTP-21%2B-brightgreen.svg)

**Zero-configuration auto-meshing Erlang/Elixir clusters with TLS-based trust groups and mDNS discovery.**

---

## Overview

GSMLG EPMD is a sophisticated fork of [epmdless](https://github.com/tsloughter/epmdless) that enables Erlang/Elixir distribution without the standard EPMD daemon. It provides three strategies for node connectivity:

1. **`gsmlg_epmd_static`** - Static port, automatic mesh (original epmdless feature)
2. **`gsmlg_epmd_client`** - Variable ports, manual registration (original epmdless feature)
3. **`gsmlg_epmd_tls`** ⭐ **NEW** - TLS-based trust groups with mDNS auto-discovery

### Why GSMLG EPMD?

**The Challenge:** Traditional Erlang distribution requires either:
- Manual configuration of every node's IP and port
- A centralized EPMD service
- Pre-shared cookies across all nodes

**The Solution:** GSMLG EPMD provides:
- ✅ **Zero-configuration auto-discovery** via mDNS
- ✅ **Certificate-based trust groups** instead of shared cookies
- ✅ **Automatic mesh formation** within trusted groups
- ✅ **Secure dynamic cookie exchange** over TLS
- ✅ **Group isolation** - different groups can't connect, even with the same CA

---

## ⭐ NEW: TLS-Based Trust Groups with Auto-Discovery

The headline feature of GSMLG EPMD is the new `gsmlg_epmd_tls` module that combines:

### Certificate-Based Trust Groups

Nodes use X.509 certificates with:
- **CA-based authentication** - Nodes must have certificates signed by a trusted CA
- **Group membership in OU field** - Certificate's Organizational Unit defines the trust group
- **Automatic isolation** - Nodes with different OU values won't connect, even with the same CA

```
Example Certificate Structure:
  Subject: CN=node1, OU=production, O=GSMLG
           ↑             ↑
       Node name    Trust group

Result:
  ✓ node1 (OU=production) + node2 (OU=production) → Auto-mesh
  ✗ node1 (OU=production) + node3 (OU=staging)    → Isolated
```

### mDNS Service Discovery

- Nodes advertise themselves as `_epmd._tcp.local` services
- Automatic peer discovery on the local network
- No manual IP address configuration needed
- Group information included in service advertisement

### Secure Dynamic Cookie Exchange

- No pre-shared cookies required
- Each node generates a 256-bit random cookie
- Cookies exchanged securely over TLS after mutual authentication
- Automatic Erlang distribution setup

### Complete Auto-Mesh Flow

```
1. Node starts → Reads certificate (OU=production)
2. Advertises via mDNS → Other nodes discover it
3. Peer discovered → Check group match (OU comparison)
4. Groups match → Initiate TLS connection
5. TLS handshake → Mutual certificate authentication
6. Cookie exchange → Over secure TLS channel
7. Auto-connect → Full mesh formed!
```

**No configuration, no manual connections, just start the nodes! 🚀**

---

## Quick Start

### Requirements

- **Erlang/OTP**: 21 or newer
- **OpenSSL**: For certificate generation
- **Docker** (optional): For running examples

### Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {gsmlg_epmd, {git, "https://github.com/gsmlg-dev/gsmlg_epmd", {branch, "master"}}}
]}.
```

Add to your release configuration (not `.app.src`):

```erlang
{relx, [{release, {my_app, "1.0.0"},
         [gsmlg_epmd,  % Add here
          my_app]},
        {vm_args_src, "config/vm.args.src"}]}.
```

---

## Usage Modes

### Mode 1: TLS Auto-Mesh (NEW ⭐)

**Best for:** Production clusters, zero-config deployments, maximum security

#### 1. Generate Certificates

```bash
# Create CA and node certificates
./tools/generate_certs.sh production node1
./tools/generate_certs.sh production node2
```

This creates certificates with `OU=production` for group membership.

#### 2. Configure VM Args

```erlang
# vm.args
-sname node1@localhost
-setcookie temporary  # Will be replaced by dynamic exchange
-start_epmd false
-epmd_module gsmlg_epmd_tls
-proto_dist inet_tls
-ssl_dist_optfile /path/to/ssl_dist.config
```

#### 3. Set Environment Variables

```bash
export GSMLG_EPMD_TLS_CERTFILE=/path/to/cert.pem
export GSMLG_EPMD_TLS_KEYFILE=/path/to/key.pem
export GSMLG_EPMD_TLS_CACERTFILE=/path/to/ca-cert.pem
export GSMLG_EPMD_AUTO_CONNECT=true
export GSMLG_EPMD_MDNS_ENABLE=true
export ERL_DIST_PORT=8001
```

#### 4. Start Node

```bash
erl -config sys.config -args_file vm.args -pa _build/default/lib/*/ebin
```

**Nodes with matching groups will automatically discover and connect!**

#### Example: Docker Compose Auto-Mesh

See the complete working example in `examples/tls_auto_mesh/`:

```bash
cd examples/tls_auto_mesh
make certs  # Generate certificates
make up     # Start 4 nodes (3 production, 1 staging)

# Check auto-mesh
make shell-node1
# nodes(). → [node2@node2, node3@node3]  ✓ Auto-connected!

make shell-node4  # Staging group node
# nodes(). → []  ✓ Isolated from production
```

---

### Mode 2: Static Port (Original)

**Best for:** Simple Docker deployments, all nodes use same port

#### Configuration

```erlang
# vm.args
-sname my_node
-setcookie my_cookie
-start_epmd false
-epmd_module gsmlg_epmd_static
-erl_epmd_port 8001
```

All nodes use port 8001. When node A connects to B and C, a full mesh is automatically created.

**Example:** `examples/erlang_docker_example/`

---

### Mode 3: Variable Ports (Original)

**Best for:** Dynamic port allocation, manual control

#### Configuration

```erlang
# vm.args
-sname my_node@localhost
-setcookie my_cookie
-start_epmd false
-epmd_module gsmlg_epmd_client
```

#### Usage

```erlang
% Manually register nodes
gsmlg_epmd_client:add_node('node2@host2', 8002).
gsmlg_epmd_client:add_node('node3@host3', 8003).

% Then connect
net_adm:ping('node2@host2').
```

**Example:** `examples/erlang_variable_ports_example/`

---

## Configuration Reference

### TLS Auto-Mesh Configuration

#### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GSMLG_EPMD_TLS_CERTFILE` | Yes | - | Path to node certificate |
| `GSMLG_EPMD_TLS_KEYFILE` | Yes | - | Path to private key |
| `GSMLG_EPMD_TLS_CACERTFILE` | Yes | - | Path to CA certificate |
| `GSMLG_EPMD_TLS_PORT` | No | 4369 | TLS server port |
| `GSMLG_EPMD_GROUP` | No | (from cert) | Override certificate OU |
| `GSMLG_EPMD_AUTO_CONNECT` | No | true | Auto-connect discovered nodes |
| `GSMLG_EPMD_MDNS_ENABLE` | No | true | Enable mDNS discovery |
| `ERL_DIST_PORT` | Yes | - | Erlang distribution port |

#### Application Configuration (sys.config)

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

#### SSL Distribution Configuration (ssl_dist.config)

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

---

## Tools

### Certificate Generation

Use the included script to generate certificates:

```bash
./tools/generate_certs.sh <group_name> <node_name> [output_dir]

# Examples
./tools/generate_certs.sh production node1
./tools/generate_certs.sh staging web-server ./my-certs
```

**What it does:**
- Creates a CA (if it doesn't exist)
- Generates node certificate with OU set to group name
- Signs certificate with CA
- Validates the certificate chain
- Sets proper file permissions

**Output:**
```
certs/
├── ca/
│   ├── ca-cert.pem
│   └── ca-key.pem
└── production/
    └── node1/
        ├── cert.pem
        ├── key.pem
        └── ca-cert.pem
```

---

## Architecture

### TLS Auto-Mesh Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ gsmlg_epmd_app                                               │
│   └─▶ gsmlg_epmd_sup (supervisor)                           │
│       ├─▶ gsmlg_epmd_cookie (gen_server)                    │
│       │   └─▶ Cookie generation & storage                   │
│       │                                                       │
│       ├─▶ gsmlg_epmd_tls (gen_server)                       │
│       │   ├─▶ EPMD callbacks                                │
│       │   └─▶ Node registry                                 │
│       │                                                       │
│       ├─▶ gsmlg_epmd_tls_server (gen_server) *              │
│       │   ├─▶ TLS listener (mutual auth)                    │
│       │   └─▶ Connection acceptor                           │
│       │                                                       │
│       └─▶ gsmlg_epmd_mdns (gen_server) *                    │
│           ├─▶ mDNS advertisement                            │
│           └─▶ Service discovery                             │
│                                                               │
│       * Dynamically started on node registration             │
└─────────────────────────────────────────────────────────────┘
```

### Modules

| Module | Purpose |
|--------|---------|
| **gsmlg_epmd_tls** | Main EPMD callback, coordinates all services |
| **gsmlg_epmd_cert** | Certificate loading, CA validation, group extraction |
| **gsmlg_epmd_cookie** | Cookie generation and secure exchange protocol |
| **gsmlg_epmd_tls_server** | TLS server for incoming connections |
| **gsmlg_epmd_mdns** | mDNS service discovery and advertisement |
| **gsmlg_epmd_sup** | Supervisor for all services |
| **gsmlg_epmd_client** | Variable ports EPMD (original) |
| **gsmlg_epmd_static** | Static port EPMD (original) |

---

## Examples

### 1. TLS Auto-Mesh with Docker Compose

**Location:** `examples/tls_auto_mesh/`

Demonstrates:
- 4 nodes (3 in "production" group, 1 in "staging" group)
- Automatic mesh formation via mDNS
- Group isolation (staging node can't connect to production)
- Dynamic cookie exchange
- Full TLS configuration

```bash
cd examples/tls_auto_mesh
make certs && make up
```

### 2. Static Port with Docker

**Location:** `examples/erlang_docker_example/`

Traditional static port setup with Docker Compose.

### 3. Variable Ports

**Location:** `examples/erlang_variable_ports_example/`

Manual node registration with variable ports.

---

## Security Features

### TLS Auto-Mesh Security

✅ **Mutual TLS Authentication**
- Both client and server must present valid certificates
- Certificates validated against trusted CA

✅ **Certificate Chain Validation**
- Full chain verification up to root CA
- Support for intermediate CAs
- Expiration date checking

✅ **Group-Based Access Control**
- Trust groups encoded in certificate OU field
- Automatic isolation of different groups
- Same CA, different OU = no connection

✅ **Secure Cookie Exchange**
- 256-bit cryptographically random cookies
- Exchanged only after TLS authentication
- No pre-shared secrets required
- Protocol versioning for compatibility

✅ **Modern TLS**
- TLS 1.2 and 1.3 support
- Strong cipher suites
- Perfect forward secrecy
- No fallback to insecure protocols

---

## API Reference

### gsmlg_epmd_tls

```erlang
%% Register a discovered node (called internally)
gsmlg_epmd_tls:register_discovered_node(NodeInfo) -> ok.

%% List all discovered nodes
gsmlg_epmd_tls:list_discovered_nodes() -> #{node() => map()}.
```

### gsmlg_epmd_client

```erlang
%% Add a node to the registry
gsmlg_epmd_client:add_node(Node, Port) -> ok.
gsmlg_epmd_client:add_node(NodeName, Host, IP, Port) -> ok.

%% Remove a node
gsmlg_epmd_client:remove_node(Node) -> ok.

%% List all registered nodes
gsmlg_epmd_client:list_nodes() -> [{Node, {Host, Port}}].
```

### gsmlg_epmd_cert

```erlang
%% Load TLS configuration
gsmlg_epmd_cert:load_config() -> {ok, Config} | {error, Reason}.

%% Get SSL options for server/client
gsmlg_epmd_cert:get_server_opts() -> {ok, Opts} | {error, Reason}.
gsmlg_epmd_cert:get_client_opts(ServerName) -> {ok, Opts} | {error, Reason}.

%% Extract group from certificate
gsmlg_epmd_cert:extract_group(Cert) -> {ok, Group} | {error, Reason}.
```

---

## Troubleshooting

### Nodes not auto-connecting?

1. **Check certificates:**
   ```bash
   openssl x509 -in cert.pem -noout -subject
   # Should show: OU=<group_name>
   ```

2. **Verify group match:**
   ```erlang
   gsmlg_epmd_cert:get_group().
   % Should return {ok, "production"} or your group name
   ```

3. **Check mDNS:**
   - Ensure network allows multicast
   - Docker: Use bridge network (not host)
   - Check logs for "mDNS service advertised"

4. **Check TLS handshake:**
   ```bash
   openssl verify -CAfile ca-cert.pem cert.pem
   # Should show: cert.pem: OK
   ```

### TLS errors?

1. **"certificate verify failed"**
   - Certificate not signed by configured CA
   - CA certificate path incorrect
   - Certificate expired

2. **"group mismatch"**
   - Nodes have different OU fields
   - This is expected behavior for isolation!

3. **"no peer certificate"**
   - `fail_if_no_peer_cert` is true but peer didn't send cert
   - Check ssl_dist.config on both nodes

---

## Testing

Run the test suite:

```bash
cd shelltests
./run_tests.sh
```

This builds a release and tests:
- Node startup with EPMD replacement
- Daemon mode
- Remote console
- Basic connectivity

---

## Comparison with Original epmdless

| Feature | Original epmdless | GSMLG EPMD |
|---------|------------------|------------|
| Static port mode | ✅ | ✅ (renamed to gsmlg_epmd_static) |
| Variable port mode | ✅ | ✅ (renamed to gsmlg_epmd_client) |
| TLS distribution support | ✅ | ✅ Enhanced |
| mDNS auto-discovery | ❌ | ✅ NEW |
| Certificate-based trust | ❌ | ✅ NEW |
| Dynamic cookie exchange | ❌ | ✅ NEW |
| Zero-config auto-mesh | ❌ | ✅ NEW |
| Group isolation | ❌ | ✅ NEW |

---

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Submit a pull request

---

## License

Apache License 2.0

---

## Credits

- **Original epmdless**: [tsloughter/epmdless](https://github.com/tsloughter/epmdless)
- **GSMLG EPMD enhancements**: TLS trust groups, mDNS discovery, auto-meshing
- **mDNS library**: [shortishly/mdns](https://github.com/shortishly/mdns)

---

## Links

- **GitHub**: https://github.com/gsmlg-dev/gsmlg_epmd
- **Original epmdless**: https://github.com/tsloughter/epmdless
- **Documentation**: See `CLAUDE.md` for developer documentation
- **Security**: See `SECURITY.md` for security best practices (coming soon)

---

## Support

For issues, questions, or contributions:
- **Issues**: https://github.com/gsmlg-dev/gsmlg_epmd/issues
- **Discussions**: Use GitHub Discussions for questions

---

**Built with ❤️ for the Erlang/Elixir community**
