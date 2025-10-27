# TLS Auto-Mesh Example

This example demonstrates automatic mesh network formation using TLS-based trust groups with mDNS service discovery.

## Features Demonstrated

1. **CA-Based Trust Groups**: Nodes with certificates from the same CA and same OU (group) automatically form a mesh
2. **mDNS Auto-Discovery**: Nodes discover each other via mDNS without manual configuration
3. **Secure Cookie Exchange**: Cookies are dynamically exchanged over TLS after mutual authentication
4. **Group Isolation**: Nodes in different groups (OU fields) remain isolated even with the same CA

## Architecture

```
Production Group (OU=production):
  ┌─────────┐     ┌─────────┐     ┌─────────┐
  │  node1  │────▶│  node2  │────▶│  node3  │
  └─────────┘◀────└─────────┘◀────└─────────┘
       ▲                                ▲
       └────────────────────────────────┘
            Auto-formed full mesh

Staging Group (OU=staging):
  ┌─────────┐
  │  node4  │  (Isolated from production group)
  └─────────┘
```

## Quick Start

### 1. Generate Certificates

```bash
# Generate certificates for production group
../../tools/generate_certs.sh production node1 ./certs
../../tools/generate_certs.sh production node2 ./certs
../../tools/generate_certs.sh production node3 ./certs

# Generate certificate for staging group (uses same CA, different OU)
../../tools/generate_certs.sh staging node4 ./certs
```

This creates:
- `certs/ca/` - CA certificate (shared by all nodes)
- `certs/production/node1/` - node1 certificate with OU=production
- `certs/production/node2/` - node2 certificate with OU=production
- `certs/production/node3/` - node3 certificate with OU=production
- `certs/staging/node4/` - node4 certificate with OU=staging

### 2. Build the Release

```bash
rebar3 release
```

### 3. Start with Docker Compose

```bash
docker-compose up
```

This starts 4 nodes:
- `node1`, `node2`, `node3` in the `production` group → will auto-mesh
- `node4` in the `staging` group → will remain isolated

### 4. Verify Auto-Mesh

Connect to node1 and check connected nodes:

```bash
docker exec -it tls_node1 bin/gsmlg_epmd_test remote_console

# In the Erlang shell:
(node1@node1)1> nodes().
[node2@node2, node3@node3]  % Auto-connected!

(node1@node1)2> gsmlg_epmd_tls:list_discovered_nodes().
# Shows all discovered nodes with their info
```

Connect to node4 (staging group):

```bash
docker exec -it tls_node4 bin/gsmlg_epmd_test remote_console

(node4@node4)1> nodes().
[]  % Not connected to production nodes (group isolation)
```

## How It Works

### 1. mDNS Service Advertisement

Each node advertises itself via mDNS as `_epmd._tcp.local` with:
- Port: TLS port (4369)
- TXT records: group name, distribution port

### 2. Service Discovery

Nodes subscribe to mDNS advertisements and discover peers:
```erlang
% When a node is discovered:
% 1. Check group match (OU field in certificate)
% 2. If groups match → initiate TLS connection
```

### 3. TLS Mutual Authentication

```
Node1                           Node2
  |                               |
  |--- TLS ClientHello --------▶ |
  |◀-- TLS ServerHello ----------|
  |                               |
  |--- Certificate (OU=prod) ---▶|
  |◀-- Certificate (OU=prod) ----|
  |                               |
  |    Verify: Same CA? ✓         |
  |    Verify: Same OU? ✓         |
  |                               |
  |--- Cookie Exchange ----------▶|
  |◀-- Cookie Exchange -----------|
  |                               |
  | Erlang Distribution Start     |
  └───────────────────────────────┘
```

### 4. Automatic Mesh Formation

Once cookies are exchanged:
- Nodes automatically connect via Erlang distribution
- Full mesh is formed within the group
- No manual `net_adm:ping/1` needed!

## Configuration

### VM Args (`config/vm.args.src`)

```erlang
-sname ${NODE_NAME}@${HOSTNAME}
-setcookie temporary  # Will be replaced by dynamic exchange
-start_epmd false
-epmd_module gsmlg_epmd_tls
-proto_dist inet_tls
-ssl_dist_optfile /app/config/ssl_dist.config
```

### SSL Distribution (`config/ssl_dist.config`)

```erlang
[
  {server, [
    {certfile, "/app/certs/cert.pem"},
    {keyfile, "/app/certs/key.pem"},
    {cacertfile, "/app/certs/ca-cert.pem"},
    {verify, verify_peer},
    {fail_if_no_peer_cert, true}
  ]},
  {client, [
    {certfile, "/app/certs/cert.pem"},
    {keyfile, "/app/certs/key.pem"},
    {cacertfile, "/app/certs/ca-cert.pem"},
    {verify, verify_peer}
  ]}
].
```

### Environment Variables

```bash
GSMLG_EPMD_TLS_CERTFILE=/app/certs/cert.pem
GSMLG_EPMD_TLS_KEYFILE=/app/certs/key.pem
GSMLG_EPMD_TLS_CACERTFILE=/app/certs/ca-cert.pem
GSMLG_EPMD_TLS_PORT=4369
GSMLG_EPMD_AUTO_CONNECT=true
GSMLG_EPMD_MDNS_ENABLE=true
ERL_DIST_PORT=8001
```

## Testing Group Isolation

### Same CA, Different Groups

The example includes both `production` and `staging` groups:

```bash
# Production group nodes
docker exec -it tls_node1 bin/gsmlg_epmd_test remote_console
(node1@node1)> nodes().
[node2@node2, node3@node3]  % Only production nodes

# Staging group node
docker exec -it tls_node4 bin/gsmlg_epmd_test remote_console
(node4@node4)> nodes().
[]  % Isolated - no connections to production
```

Even though all nodes use the same CA, they're isolated by OU field.

## Logs

View TLS handshake and discovery logs:

```bash
# Node1 logs
docker logs tls_node1

# You'll see:
# - mDNS service advertised
# - Nodes discovered via mDNS
# - TLS handshake successful
# - Cookie exchange
# - Node registration
```

## Cleanup

```bash
docker-compose down
rm -rf certs/  # Remove generated certificates
```

## Troubleshooting

### Nodes not connecting?

1. **Check group names**: `openssl x509 -in certs/production/node1/cert.pem -noout -subject`
2. **Check mDNS**: Ensure Docker network allows multicast
3. **Check logs**: `docker logs tls_node1`

### TLS errors?

1. **Verify certificates**: `openssl verify -CAfile certs/ca/ca-cert.pem certs/production/node1/cert.pem`
2. **Check permissions**: Ensure cert files are readable in containers
3. **Check dates**: Ensure certificates haven't expired

## Advanced Usage

### Manual Connection

Even with auto-discovery, you can manually trigger connections:

```erlang
% Add a node manually
gsmlg_epmd_tls:register_discovered_node(#{
    node => 'node5@remotehost',
    dist_port => 8001,
    group => "production"
}).

% Then connect
net_adm:ping('node5@remotehost').
```

### Disable Auto-Connect

```bash
# Set in environment
GSMLG_EPMD_AUTO_CONNECT=false

# Nodes will still discover via mDNS but won't auto-connect
# You can manually connect using net_adm:ping/1
```
