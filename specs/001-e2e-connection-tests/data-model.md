# Data Model: E2E Node Connection Tests

**Feature**: 001-e2e-connection-tests
**Date**: 2025-11-19
**Purpose**: Define test entities, certificate structures, and connection matrices

## Entity: Test Node

**Purpose**: Represents a running Erlang node configured for one of the three EPMD modes

**Attributes**:
- `name`: atom() - Node name (e.g., `node1@localhost`)
- `mode`: `tls` | `static` | `variable` - Connection mode
- `port`: integer() - Distribution port (49152-65535 range)
- `cookie`: binary() | atom() - Erlang distribution cookie
- `cert_path`: string() | undefined - Path to node certificate (TLS mode only)
- `key_path`: string() | undefined - Path to private key (TLS mode only)
- `ca_cert_path`: string() | undefined - Path to CA certificate (TLS mode only)
- `group`: string() | undefined - Trust group name from cert OU field (TLS mode only)
- `pid`: pid() - Node process identifier (from `peer` or `slave`)
- `config`: map() - Additional configuration (VM args, env vars)

**Lifecycle States**:
1. `init` → Node created but not started
2. `starting` → Node startup in progress
3. `running` → Node operational, EPMD mode active
4. `connected` → Node connected to peers
5. `stopping` → Shutdown initiated
6. `stopped` → Node terminated, resources cleaned

**Validation Rules**:
- `name` must be unique per test case
- `port` must be available and in ephemeral range
- TLS mode requires `cert_path`, `key_path`, `ca_cert_path`, `group`
- Static/variable modes require `cookie`
- `pid` must be valid after transition to `running` state

## Entity: Trust Group

**Purpose**: Defines a set of nodes with certificates sharing the same OU field for TLS mode testing

**Attributes**:
- `name`: string() - Group identifier (e.g., "production", "staging")
- `ca_cert`: binary() - CA certificate PEM data
- `ca_key`: binary() - CA private key PEM data
- `member_certs`: #{node_name => {cert, key}} - Map of node certificates
- `created_at`: integer() - Unix timestamp of group creation

**Relationships**:
- One Trust Group has many Test Nodes (TLS mode)
- Test Nodes in different Trust Groups cannot connect (group isolation)

**Validation Rules**:
- `name` must match regex `^[a-zA-Z0-9_-]+$` (alphanumeric, hyphen, underscore)
- `ca_cert` and `ca_key` must be valid PEM format
- All member certificates must be signed by this group's CA
- All member certificates must have `OU=<group_name>` in subject

## Entity: Connection Matrix

**Purpose**: Defines expected connection outcomes between nodes based on mode and configuration

**Attributes**:
- `node_a`: atom() - First node name
- `node_b`: atom() - Second node name
- `expected_result`: `connected` | `rejected` | `timeout` - Expected outcome
- `reason`: string() | undefined - Expected error reason if rejected
- `conditions`: map() - Test conditions (same_cookie, same_group, valid_cert, etc.)

**Example Matrix (TLS Mode)**:
```erlang
[
  %% Same group, valid certs → connected
  #{node_a => 'n1@localhost', node_b => 'n2@localhost',
    expected_result => connected,
    conditions => #{same_group => true, valid_certs => true}},

  %% Different groups, same CA → rejected (group mismatch)
  #{node_a => 'n1@localhost', node_b => 'n3@localhost',
    expected_result => rejected,
    reason => "group_mismatch",
    conditions => #{same_group => false, valid_certs => true}},

  %% Invalid cert → rejected (cert validation error)
  #{node_a => 'n1@localhost', node_b => 'n4@localhost',
    expected_result => rejected,
    reason => "certificate_verify_failed",
    conditions => #{same_group => true, valid_certs => false}}
]
```

**Validation Rules**:
- `node_a` and `node_b` must reference existing Test Nodes
- `expected_result` must match actual connection attempt outcome
- `reason` required if `expected_result` is `rejected`

## Entity: Test Certificate Set

**Purpose**: Collection of certificates with varying properties for comprehensive TLS testing

**Attributes**:
- `ca`: {cert, key} - Root CA certificate and private key
- `valid_certs`: #{group => #{node => {cert, key}}} - Valid node certificates by group
- `invalid_certs`: [{cert, key, reason}] - Invalid certificates for negative testing
- `expired_certs`: [{cert, key}] - Expired certificates for expiration testing

**Certificate Properties**:
- Valid cert: 2048-bit RSA, OU=<group>, signed by CA, not expired
- Invalid CA cert: 2048-bit RSA, OU=<group>, self-signed (not from test CA)
- Expired cert: 2048-bit RSA, OU=<group>, signed by CA, `notAfter` in past
- Wrong OU cert: 2048-bit RSA, OU=<different_group>, signed by CA

**Generation Patterns**:
```erlang
%% Valid certificate for group "production"
create_node_cert(CA, NodeName, "production") ->
    Subject = #{
        commonName => atom_to_list(NodeName),
        organizationalUnit => "production",
        organization => "GSMLG"
    },
    generate_and_sign_cert(Subject, CA).

%% Expired certificate (notAfter = yesterday)
create_expired_cert(CA, NodeName, Group) ->
    Cert = create_node_cert(CA, NodeName, Group),
    set_validity_period(Cert, {days, -365}, {days, -1}).
```

## Entity: Test Scenario

**Purpose**: Complete test configuration including nodes, expected connections, and pass/fail criteria

**Attributes**:
- `name`: string() - Scenario identifier (e.g., "tls_auto_mesh_same_group")
- `mode`: `tls` | `static` | `variable` - Connection mode being tested
- `nodes`: [Test Node] - List of nodes to start
- `setup_actions`: [function()] - Pre-test setup steps
- `test_actions`: [function()] - Actual test assertions
- `teardown_actions`: [function()] - Cleanup steps
- `expected_topology`: Connection Matrix - Expected final node connections
- `timeout`: integer() - Maximum test duration in seconds

**Lifecycle**:
1. Execute `setup_actions` (generate certs, start nodes)
2. Wait for initial state (nodes running, EPMD registered)
3. Execute `test_actions` (trigger connections, assert outcomes)
4. Verify `expected_topology` matches actual node connections
5. Execute `teardown_actions` (stop nodes, clean temp files)

**Example Scenario (TLS Mode)**:
```erlang
#{
    name => "tls_group_isolation_two_groups",
    mode => tls,
    nodes => [
        #{name => 'prod1@localhost', group => "production", port => 50001},
        #{name => 'prod2@localhost', group => "production", port => 50002},
        #{name => 'stage1@localhost', group => "staging", port => 50003}
    ],
    expected_topology => [
        %% Production nodes connect to each other
        #{node_a => 'prod1@localhost', node_b => 'prod2@localhost',
          expected_result => connected},
        %% Staging node isolated from production
        #{node_a => 'prod1@localhost', node_b => 'stage1@localhost',
          expected_result => rejected, reason => "group_mismatch"},
        #{node_a => 'prod2@localhost', node_b => 'stage1@localhost',
          expected_result => rejected, reason => "group_mismatch"}
    ],
    timeout => 60
}
```

## Data Relationships

```
Trust Group (1) ──┬──▶ Test Node (N) [TLS mode]
                  │
                  └──▶ Test Certificate Set (1)

Test Scenario (1) ──┬──▶ Test Node (N)
                    │
                    └──▶ Connection Matrix (1)

Connection Matrix (1) ──▶ Test Node pairs (N)
```

## Test Data Storage

**Temporary Directory Structure** (created per suite, cleaned after):
```
/tmp/gsmlg_epmd_test_<suite_name>_<timestamp>/
├── ca/
│   ├── ca-cert.pem
│   └── ca-key.pem
├── production/
│   ├── node1/
│   │   ├── cert.pem
│   │   ├── key.pem
│   │   └── ca-cert.pem (symlink)
│   └── node2/
│       ├── cert.pem
│       ├── key.pem
│       └── ca-cert.pem (symlink)
├── staging/
│   └── node3/
│       ├── cert.pem
│       ├── key.pem
│       └── ca-cert.pem (symlink)
└── invalid/
    ├── expired-cert.pem
    ├── wrong-ca-cert.pem
    └── wrong-ou-cert.pem
```

**Cleanup**: All directories under `/tmp/gsmlg_epmd_test_*` removed in `end_per_suite/1` hook

## State Transitions

**Test Node Lifecycle**:
```
init ──▶ starting ──▶ running ──▶ connected ──▶ stopping ──▶ stopped
   ▲                      │                         ▲
   │                      │                         │
   └──────────────────────┴─────────────────────────┘
                    (error transitions)
```

**Connection Matrix Evaluation**:
```
Defined Matrix ──▶ Trigger Connections ──▶ Wait for Settle ──▶ Compare Actual vs Expected
       │                                                              │
       └──────────────────────────────────────────────────────────┬──┘
                                                                  │
                                                             PASS or FAIL
```

## Invariants

1. **Port Uniqueness**: No two Test Nodes in same test case share same port
2. **Name Uniqueness**: No two Test Nodes in same test case share same name
3. **Group Isolation**: Nodes in different Trust Groups never reach `connected` state
4. **Resource Cleanup**: All Test Nodes transition to `stopped` before test case ends
5. **Certificate Validity**: All TLS mode Test Nodes have valid cert/key/CA paths before `starting`
