# Security Best Practices

This document outlines security best practices for deploying **GSMLG EPMD**, particularly when using the TLS auto-mesh mode with certificate-based trust groups.

---

## Table of Contents

1. [Security Model Overview](#security-model-overview)
2. [Certificate Management](#certificate-management)
3. [CA Security](#ca-security)
4. [Private Key Protection](#private-key-protection)
5. [Group Isolation](#group-isolation)
6. [TLS Configuration](#tls-configuration)
7. [Network Security](#network-security)
8. [Operational Security](#operational-security)
9. [Common Pitfalls](#common-pitfalls)
10. [Security Checklist](#security-checklist)

---

## Security Model Overview

### TLS Auto-Mesh Trust Model

GSMLG EPMD's TLS mode implements a **certificate-based trust system** with the following security layers:

1. **CA-Based Authentication**: Only nodes with certificates signed by a trusted CA can connect
2. **Group Membership**: Certificate OU (Organizational Unit) field defines trust groups
3. **Group Isolation**: Different OU values = no connection, even with same CA
4. **Dynamic Cookies**: 256-bit random cookies exchanged over TLS (no pre-shared secrets)
5. **Mutual TLS**: Both client and server validate each other's certificates

### Threat Model

**What GSMLG EPMD TLS mode protects against:**
- Unauthorized nodes joining the cluster (no valid certificate)
- Cross-group connections (different OU values)
- Man-in-the-middle attacks (mutual TLS authentication)
- Cookie compromise (dynamic generation, secure exchange)
- EPMD port mapper vulnerabilities (no EPMD daemon)

**What it does NOT protect against:**
- Compromised CA private key (attacker can issue valid certificates)
- Compromised node private keys (attacker can impersonate that node)
- Physical access to certificate files
- Insider threats with valid certificates
- Application-level vulnerabilities in Erlang code

---

## Certificate Management

### Certificate Lifecycle

#### 1. Generation

**DO:**
- Use strong key sizes: 2048-bit RSA minimum, 4096-bit recommended, or ECDSA P-256+
- Set appropriate certificate validity periods (1 year recommended, max 2 years)
- Use unique CN (Common Name) for each node
- Set OU field to match trust group name exactly
- Include SAN (Subject Alternative Name) if using hostnames

**DON'T:**
- Reuse certificates across nodes
- Use overly long validity periods (>2 years)
- Use weak key sizes (<2048-bit RSA)
- Share private keys between nodes

**Example: Secure certificate generation**
```bash
# Use the provided script with strong defaults
./tools/generate_certs.sh production node1

# Verify certificate details
openssl x509 -in certs/production/node1/cert.pem -noout -text
```

#### 2. Storage

**File Permissions:**
```bash
# CA private key: Most sensitive, never copy to nodes
chmod 400 certs/ca/ca-key.pem
chown root:root certs/ca/ca-key.pem

# Node private keys: Read-only by the Erlang process owner
chmod 400 certs/production/node1/key.pem
chown erlang:erlang certs/production/node1/key.pem

# Certificates and CA cert: Readable
chmod 444 certs/production/node1/cert.pem
chmod 444 certs/production/node1/ca-cert.pem
```

**Storage Locations:**
- **Production**: Use secrets management (Kubernetes Secrets, HashiCorp Vault, AWS Secrets Manager)
- **Development**: Local filesystem with proper permissions
- **Never**: Environment variables (too easy to leak in logs), version control, shared filesystems

#### 3. Distribution

**Secure distribution methods:**
- Configuration management tools (Ansible, Chef, Puppet) with encrypted vaults
- Secrets managers (Kubernetes Secrets with encryption at rest)
- Manual secure copy (scp with key-based auth)

**Avoid:**
- Copying via unencrypted channels
- Storing in Docker images (use volumes/secrets instead)
- Committing to git repositories

#### 4. Rotation

**When to rotate:**
- Before expiration (30-60 days in advance)
- After suspected compromise
- When employee/admin with access leaves
- Periodically (every 12-24 months)

**Rotation process:**
```bash
# 1. Generate new certificates with same OU
./tools/generate_certs.sh production node1-new

# 2. Deploy new certificates to nodes (blue-green or rolling)
# 3. Restart nodes with new certificates
# 4. Verify connections still work
# 5. Revoke old certificates (if using CRL/OCSP)
# 6. Delete old private keys securely
shred -vfz -n 10 old-key.pem
```

#### 5. Revocation

**Current limitation**: GSMLG EPMD does not currently support CRL (Certificate Revocation Lists) or OCSP (Online Certificate Status Protocol).

**Workaround:**
- Rotate CA certificate when compromise suspected
- Remove compromised node certificates from nodes
- Use short certificate validity periods (6-12 months)

**Future enhancement**: Add CRL/OCSP support (see PROJECT_STATUS.md)

---

## CA Security

### CA Private Key Protection

**The CA private key is the most critical secret.** Compromise = attacker can issue valid certificates for any group.

#### Offline CA (Recommended for Production)

**Best practice:**
1. Generate CA on an air-gapped machine
2. Store CA private key on encrypted USB drive
3. Keep in physical safe
4. Only connect to sign new certificates
5. Never copy to production systems

```bash
# Generate CA offline
openssl genrsa -aes256 -out ca-key.pem 4096  # Password-protected

# Sign certificates offline, then copy only the signed cert
openssl x509 -req -in node.csr -CA ca-cert.pem -CAkey ca-key.pem -out node-cert.pem
```

#### Online CA (Development/Testing Only)

If you must use an online CA:
- Store CA key in hardware security module (HSM) or key management service (KMS)
- Use strong encryption at rest
- Restrict access via IAM policies
- Enable audit logging for all CA operations
- Use separate CAs for dev/staging/production

### CA Certificate Chain

**Support for intermediate CAs:**
```
Root CA (offline, long-lived)
  └─> Intermediate CA (online, shorter-lived)
      └─> Node certificates
```

**Benefits:**
- Root CA can be kept completely offline
- Intermediate CA compromise doesn't require re-trusting root
- Easier rotation (just rotate intermediate)

**Configuration:**
```bash
# Concatenate chain for cacertfile
cat intermediate-ca.pem root-ca.pem > ca-chain.pem
export GSMLG_EPMD_TLS_CACERTFILE=/path/to/ca-chain.pem
```

---

## Private Key Protection

### Node Private Keys

**Each node has its own private key.** Compromise = attacker can impersonate that specific node.

#### Storage

**DO:**
- Store on encrypted filesystems
- Use restrictive file permissions (chmod 400)
- Use secrets management in production
- Encrypt in transit when distributing

**DON'T:**
- Store in Docker images
- Commit to version control
- Share between nodes
- Store in environment variables
- Log private key paths/contents

#### Key Generation

**Strong randomness:**
```bash
# Good: Use OpenSSL with proper entropy
openssl genrsa -out key.pem 4096

# Better: Use hardware RNG if available
openssl genrsa -rand /dev/hwrng -out key.pem 4096
```

#### Encrypted Private Keys

For extra security, encrypt private keys with a passphrase:

```bash
# Generate encrypted key
openssl genrsa -aes256 -out key-encrypted.pem 4096

# Erlang needs decrypted key at runtime (use encrypted volume or HSM instead)
```

**Note:** Erlang's SSL library requires access to decrypted keys at runtime, so encryption at rest is most effective with full-disk encryption or encrypted volumes.

---

## Group Isolation

### OU Field Security

**The OU (Organizational Unit) field is critical for group isolation.**

#### Setting OU

**Correct:**
```bash
# OU set to match trust group
./tools/generate_certs.sh production node1
# Result: OU=production

./tools/generate_certs.sh staging node2
# Result: OU=staging
```

**Verify:**
```bash
openssl x509 -in cert.pem -noout -subject
# Should show: OU=production
```

#### Group Membership Attacks

**Threat**: Attacker with CA access issues certificate with wrong OU

**Mitigation**:
- Strict CA access controls
- Audit all certificate issuance
- Use OU naming conventions (e.g., `prod-us-east`, not just `production`)
- Validate OU matches expected value on node startup

**Validation example:**
```erlang
% In sys.config
{gsmlg_epmd, [
    {group, "production"},  % Explicit group check
    ...
]}.
```

#### Cross-Group Connections

**Design guarantee**: Nodes with different OU fields **cannot** connect, even if:
- Signed by same CA
- On same network
- Discovered via mDNS
- Have correct private keys

**Verification:**
```erlang
% On production node
nodes().
% Should only show other production nodes, never staging
```

---

## TLS Configuration

### Cipher Suites

**Recommended configuration** in `ssl_dist.config`:

```erlang
[
  {server, [
    {certfile, "/path/to/cert.pem"},
    {keyfile, "/path/to/key.pem"},
    {cacertfile, "/path/to/ca.pem"},
    {verify, verify_peer},
    {fail_if_no_peer_cert, true},

    % Strong cipher suites (TLS 1.2+)
    {versions, ['tlsv1.2', 'tlsv1.3']},
    {ciphers, [
      "TLS_AES_256_GCM_SHA384",           % TLS 1.3
      "TLS_AES_128_GCM_SHA256",           % TLS 1.3
      "ECDHE-RSA-AES256-GCM-SHA384",      % TLS 1.2
      "ECDHE-ECDSA-AES256-GCM-SHA384",    % TLS 1.2
      "ECDHE-RSA-AES128-GCM-SHA256",      % TLS 1.2
      "ECDHE-ECDSA-AES128-GCM-SHA256"     % TLS 1.2
    ]},

    % Additional security
    {honor_cipher_order, true},
    {secure_renegotiate, true}
  ]},
  {client, [
    % Same options as server
    {certfile, "/path/to/cert.pem"},
    {keyfile, "/path/to/key.pem"},
    {cacertfile, "/path/to/ca.pem"},
    {verify, verify_peer},
    {versions, ['tlsv1.2', 'tlsv1.3']},
    {server_name_indication, disable}  % Not needed for IP-based connections
  ]}
].
```

**Key security options:**
- `verify_peer`: Always verify certificate (never `verify_none`)
- `fail_if_no_peer_cert`: Reject connections without client cert
- `versions`: TLS 1.2 minimum, TLS 1.3 preferred
- `honor_cipher_order`: Prefer server's cipher order

### Erlang Distribution TLS

**VM args for secure distribution:**
```erlang
-proto_dist inet_tls
-ssl_dist_optfile /path/to/ssl_dist.config
```

**Security considerations:**
- Distribution uses separate TLS connection from EPMD
- Cookie still used (but exchanged securely via gsmlg_epmd_cookie)
- All inter-node RPC encrypted via TLS

---

## Network Security

### mDNS Security

**mDNS (`_epmd._tcp.local`) uses multicast and is unauthenticated.**

#### Threat: Rogue mDNS advertisements

**Attack**: Malicious node advertises fake service, attempts connection

**Mitigations:**
1. **Certificate validation** (primary defense): Rogue node rejected during TLS handshake if no valid cert
2. **Network segmentation**: Use VLANs/network policies to restrict multicast
3. **Group filtering**: Only nodes with matching OU connect

**Network security layers:**
```
Layer 1: Network segmentation (mDNS limited to trusted VLAN)
Layer 2: TLS handshake (certificate validation)
Layer 3: OU verification (group membership check)
Layer 4: Cookie exchange (secure authentication)
```

#### Network Recommendations

**Container environments (Docker, Kubernetes):**
- Use bridge networks, not host networking
- Enable network policies to restrict multicast
- Consider service mesh (Istio, Linkerd) for additional security

**Cloud environments:**
- Use private VPCs/VNets
- Restrict security groups to cluster nodes only
- Enable VPC flow logs for auditing

**Physical networks:**
- Segment production/staging/dev networks
- Use 802.1X for node authentication
- Monitor multicast traffic for anomalies

### Firewall Rules

**Minimum required ports:**

| Port | Protocol | Purpose | Access |
|------|----------|---------|--------|
| 4369 | TCP | GSMLG EPMD TLS server | Inter-node only |
| 8001+ | TCP | Erlang distribution | Inter-node only |
| 5353 | UDP | mDNS | Multicast (cluster network) |

**Example iptables rules:**
```bash
# Allow mDNS from cluster network only
iptables -A INPUT -p udp --dport 5353 -s 10.0.0.0/24 -j ACCEPT
iptables -A INPUT -p udp --dport 5353 -j DROP

# Allow EPMD TLS from cluster nodes only
iptables -A INPUT -p tcp --dport 4369 -s 10.0.0.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 4369 -j DROP

# Allow Erlang distribution (adjust range as needed)
iptables -A INPUT -p tcp --dport 8001:8999 -s 10.0.0.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 8001:8999 -j DROP
```

---

## Operational Security

### Logging and Monitoring

**Enable Erlang logging:**
```erlang
% In sys.config
[{kernel, [
    {logger_level, info},
    {logger, [
        {handler, default, logger_std_h, #{
            formatter => {logger_formatter, #{
                single_line => false,
                template => [time, " ", level, " ", msg, "\n"]
            }}
        }}
    ]}
]}].
```

**Monitor for:**
- TLS handshake failures (potential attacks or misconfigurations)
- Group mismatch errors (cross-group connection attempts)
- Certificate expiration warnings
- Unexpected node discoveries
- Failed cookie exchanges

**Log retention:**
- Keep logs for 90+ days for security audits
- Centralize logs (ELK, Splunk, CloudWatch)
- Alert on security events (failed TLS, group mismatches)

### Security Audits

**Regular audits:**
- Review certificate expiration dates monthly
- Audit CA operations (who issued certificates, when)
- Review node connection patterns (unexpected connections?)
- Check file permissions on private keys
- Verify firewall rules haven't been weakened

**Automated checks:**
```bash
# Check certificate expiration
openssl x509 -in cert.pem -noout -enddate

# Verify file permissions
find /path/to/certs -name "*.pem" -exec ls -la {} \;

# Check for certificates expiring soon (30 days)
for cert in certs/**/cert.pem; do
  expiry=$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)
  echo "$cert expires: $expiry"
done
```

### Incident Response

**If private key compromised:**
1. Immediately revoke certificate (if CRL/OCSP supported)
2. Generate new certificate for affected node
3. Deploy new certificate
4. Restart affected node
5. Monitor logs for unauthorized connections
6. Review how compromise occurred
7. Update security procedures

**If CA key compromised:**
1. **Critical incident** - entire trust system compromised
2. Generate new CA immediately
3. Generate new certificates for ALL nodes
4. Deploy new CA + certificates to all nodes
5. Restart all nodes
6. Audit all recent certificate issuances
7. Investigate root cause

**Preparation:**
- Document incident response procedures
- Practice certificate rotation drills
- Maintain offline backups of CA (separate from compromised system)
- Have emergency contact list for security team

---

## Common Pitfalls

### 1. Reusing Certificates

**WRONG:**
```bash
# Same certificate on multiple nodes
scp node1/cert.pem node2:/etc/certs/
scp node1/cert.pem node3:/etc/certs/
```

**Why it's bad:**
- Compromise of one node = all nodes compromised
- Cannot revoke individual nodes
- Violates certificate uniqueness

**CORRECT:**
```bash
# Unique certificate per node
./tools/generate_certs.sh production node1
./tools/generate_certs.sh production node2
./tools/generate_certs.sh production node3
```

### 2. Weak File Permissions

**WRONG:**
```bash
chmod 644 key.pem  # World-readable private key!
```

**CORRECT:**
```bash
chmod 400 key.pem
chown erlang:erlang key.pem
```

### 3. Committing Secrets to Git

**WRONG:**
```bash
git add certs/
git commit -m "Add certificates"
git push
```

**Why it's bad:**
- Secrets exposed in git history forever
- Hard to revoke (need to change all certs)
- Visible to anyone with repo access

**CORRECT:**
```bash
# .gitignore
certs/
*.pem
*.key

# Generate certs outside repo or in CI/CD
```

### 4. Long Certificate Validity

**WRONG:**
```bash
# 10-year certificate
openssl x509 ... -days 3650
```

**Why it's bad:**
- Longer exposure window if compromised
- Harder to rotate (infrequent process)
- Industry standards moving to 1-year max

**CORRECT:**
```bash
# 1-year certificate (default in generate_certs.sh)
openssl x509 ... -days 365
```

### 5. Ignoring Certificate Expiration

**WRONG:**
- No monitoring of expiration dates
- Certificates expire, cluster breaks

**CORRECT:**
```bash
# Automated expiration monitoring
openssl x509 -in cert.pem -noout -checkend $((86400 * 30))
if [ $? -ne 0 ]; then
  echo "Certificate expires in <30 days!"
  # Alert ops team
fi
```

### 6. Using Weak Ciphers

**WRONG:**
```erlang
{ciphers, ["RC4-SHA", "DES-CBC3-SHA"]}  % Weak/broken ciphers
{versions, ['tlsv1', 'tlsv1.1']}         % Deprecated TLS versions
```

**CORRECT:**
```erlang
{ciphers, ["ECDHE-RSA-AES256-GCM-SHA384", "TLS_AES_256_GCM_SHA384"]}
{versions, ['tlsv1.2', 'tlsv1.3']}
```

### 7. Disabling Certificate Verification

**WRONG:**
```erlang
{verify, verify_none}  % NEVER DO THIS
```

**Why it's bad:**
- Completely bypasses TLS security
- Allows any node to connect
- Defeats entire trust system

**CORRECT:**
```erlang
{verify, verify_peer}
{fail_if_no_peer_cert, true}
```

### 8. Storing CA Key on Nodes

**WRONG:**
```bash
# Copying CA private key to production nodes
scp ca-key.pem node1:/etc/certs/
```

**Why it's bad:**
- CA key compromise if node compromised
- No reason for nodes to have CA key
- Violates principle of least privilege

**CORRECT:**
- CA key stays on offline certificate-signing machine
- Nodes only get their own cert + public CA cert
- CA key never leaves signing machine

---

## Security Checklist

### Pre-Deployment

- [ ] CA private key generated on secure/offline machine
- [ ] CA private key stored encrypted with strong passphrase
- [ ] CA private key has restricted access (only cert admins)
- [ ] Unique certificates generated for each node
- [ ] Certificates use 2048-bit RSA minimum (4096-bit preferred)
- [ ] OU field correctly set for each trust group
- [ ] Certificate validity period ≤ 1 year
- [ ] Private keys have chmod 400 permissions
- [ ] Private keys owned by correct user (e.g., erlang:erlang)
- [ ] Certificates not committed to version control
- [ ] `.gitignore` includes `certs/`, `*.pem`, `*.key`

### TLS Configuration

- [ ] `verify_peer` enabled (never `verify_none`)
- [ ] `fail_if_no_peer_cert` set to `true`
- [ ] TLS 1.2 minimum, TLS 1.3 preferred
- [ ] Strong cipher suites configured
- [ ] Weak ciphers disabled (RC4, DES, 3DES, MD5)
- [ ] `ssl_dist.config` has same security settings for client and server

### Network Security

- [ ] Firewall rules restrict EPMD port (4369) to cluster network
- [ ] Firewall rules restrict distribution ports to cluster network
- [ ] mDNS multicast restricted to cluster network (VLAN/network policy)
- [ ] Production network segmented from dev/staging
- [ ] VPC/VNet configured with private subnets
- [ ] Security groups/network policies implemented

### Operational Security

- [ ] Certificate expiration monitoring enabled
- [ ] Alerting configured for expiring certificates (<30 days)
- [ ] Centralized logging enabled
- [ ] Security event alerts configured (TLS failures, group mismatches)
- [ ] Certificate rotation procedure documented
- [ ] Incident response plan documented
- [ ] Certificate rotation drills scheduled (quarterly)

### Container/Kubernetes Specific

- [ ] Certificates stored in Secrets (not ConfigMaps)
- [ ] Secrets encryption at rest enabled
- [ ] Secrets not mounted to unnecessary pods
- [ ] RBAC restricts Secret access
- [ ] Secrets not logged or printed
- [ ] Secrets not in container images
- [ ] Pod security policies restrict privileged containers

### Documentation

- [ ] Trust group membership documented
- [ ] Certificate rotation procedure documented
- [ ] Emergency response procedures documented
- [ ] Security contact list maintained
- [ ] Architecture diagrams include security boundaries
- [ ] Runbooks include certificate troubleshooting

---

## Reporting Security Issues

If you discover a security vulnerability in GSMLG EPMD:

1. **DO NOT** open a public GitHub issue
2. Email security details to: [security@gsmlg.dev](mailto:security@gsmlg.dev)
3. Include:
   - Description of vulnerability
   - Steps to reproduce
   - Impact assessment
   - Suggested fix (if any)

We will respond within 48 hours and work with you to address the issue.

---

## References

- [Erlang/OTP SSL/TLS Documentation](https://www.erlang.org/doc/man/ssl.html)
- [X.509 Certificate Best Practices](https://www.ietf.org/rfc/rfc5280.txt)
- [TLS Best Practices](https://wiki.mozilla.org/Security/Server_Side_TLS)
- [OWASP Transport Layer Protection Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Protection_Cheat_Sheet.html)

---

**Last Updated**: 2025-10-26
**Version**: 1.0.0
