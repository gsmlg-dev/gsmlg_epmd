#!/usr/bin/env bash

##############################################################################
# Certificate Generation Script for GSMLG EPMD
#
# This script generates:
# 1. A Certificate Authority (CA) certificate and key
# 2. Node certificates signed by the CA with group membership
#
# Usage:
#   ./generate_certs.sh <group_name> <node_name> [output_dir]
#
# Example:
#   ./generate_certs.sh production node1
#   ./generate_certs.sh staging node2 ./certs
#
# The group_name is encoded in the certificate's OU (Organizational Unit)
# field, which is used by gsmlg_epmd to determine trust group membership.
##############################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DEFAULT_OUTPUT_DIR="./certs"
DAYS_VALID=3650  # 10 years
CA_DAYS_VALID=7300  # 20 years

# Parse arguments
GROUP_NAME="${1}"
NODE_NAME="${2}"
OUTPUT_DIR="${3:-$DEFAULT_OUTPUT_DIR}"

usage() {
    echo "Usage: $0 <group_name> <node_name> [output_dir]"
    echo ""
    echo "Arguments:"
    echo "  group_name   Trust group name (e.g., production, staging, development)"
    echo "  node_name    Node identifier (e.g., node1, node2, web-server)"
    echo "  output_dir   Output directory (default: ./certs)"
    echo ""
    echo "Examples:"
    echo "  $0 production node1"
    echo "  $0 staging web-server ./my-certs"
    echo ""
    echo "The script will:"
    echo "  1. Create a CA (if it doesn't exist) in <output_dir>/ca/"
    echo "  2. Generate node cert in <output_dir>/<group_name>/<node_name>/"
    echo "  3. Sign the node cert with the CA"
    echo "  4. Set the OU field to the group name for trust group membership"
    exit 1
}

if [ -z "$GROUP_NAME" ] || [ -z "$NODE_NAME" ]; then
    usage
fi

# Create directory structure
CA_DIR="${OUTPUT_DIR}/ca"
GROUP_DIR="${OUTPUT_DIR}/${GROUP_NAME}"
NODE_DIR="${GROUP_DIR}/${NODE_NAME}"

mkdir -p "${CA_DIR}"
mkdir -p "${NODE_DIR}"

echo -e "${GREEN}=== GSMLG EPMD Certificate Generator ===${NC}"
echo -e "Group: ${YELLOW}${GROUP_NAME}${NC}"
echo -e "Node:  ${YELLOW}${NODE_NAME}${NC}"
echo -e "Output: ${YELLOW}${OUTPUT_DIR}${NC}"
echo ""

##############################################################################
# Step 1: Create CA if it doesn't exist
##############################################################################

CA_KEY="${CA_DIR}/ca-key.pem"
CA_CERT="${CA_DIR}/ca-cert.pem"

if [ -f "${CA_CERT}" ] && [ -f "${CA_KEY}" ]; then
    echo -e "${GREEN}[1/4]${NC} CA already exists, reusing..."
else
    echo -e "${GREEN}[1/4]${NC} Generating Certificate Authority (CA)..."

    # Generate CA private key
    openssl genrsa -out "${CA_KEY}" 4096

    # Generate CA certificate
    openssl req -new -x509 -key "${CA_KEY}" -out "${CA_CERT}" \
        -days ${CA_DAYS_VALID} -sha256 \
        -subj "/C=US/ST=State/L=City/O=GSMLG/OU=CA/CN=GSMLG-CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

    echo -e "${GREEN}   ✓${NC} CA certificate created: ${CA_CERT}"
fi

##############################################################################
# Step 2: Generate node private key
##############################################################################

NODE_KEY="${NODE_DIR}/key.pem"
NODE_CERT="${NODE_DIR}/cert.pem"

echo -e "${GREEN}[2/4]${NC} Generating node private key..."
openssl genrsa -out "${NODE_KEY}" 2048

##############################################################################
# Step 3: Generate Certificate Signing Request (CSR)
##############################################################################

echo -e "${GREEN}[3/4]${NC} Generating Certificate Signing Request (CSR)..."

NODE_CSR="${NODE_DIR}/csr.pem"

# Create CSR with group in OU field
openssl req -new -key "${NODE_KEY}" -out "${NODE_CSR}" \
    -subj "/C=US/ST=State/L=City/O=GSMLG/OU=${GROUP_NAME}/CN=${NODE_NAME}"

##############################################################################
# Step 4: Sign the certificate with CA
##############################################################################

echo -e "${GREEN}[4/4]${NC} Signing certificate with CA..."

# Create extensions file for the certificate
EXT_FILE="${NODE_DIR}/extensions.cnf"
cat > "${EXT_FILE}" <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${NODE_NAME}
DNS.2 = ${NODE_NAME}.local
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

# Sign the certificate
openssl x509 -req -in "${NODE_CSR}" \
    -CA "${CA_CERT}" -CAkey "${CA_KEY}" \
    -CAcreateserial -out "${NODE_CERT}" \
    -days ${DAYS_VALID} -sha256 \
    -extfile "${EXT_FILE}"

# Clean up CSR and extensions file
rm "${NODE_CSR}" "${EXT_FILE}"

# Copy CA cert to node directory for convenience
cp "${CA_CERT}" "${NODE_DIR}/ca-cert.pem"

##############################################################################
# Summary
##############################################################################

echo ""
echo -e "${GREEN}=== Certificate Generation Complete ===${NC}"
echo ""
echo -e "${YELLOW}Node Certificate Files:${NC}"
echo -e "  Certificate: ${NODE_CERT}"
echo -e "  Private Key: ${NODE_KEY}"
echo -e "  CA Cert:     ${NODE_DIR}/ca-cert.pem"
echo ""
echo -e "${YELLOW}Verification:${NC}"

# Verify the certificate
CERT_OU=$(openssl x509 -in "${NODE_CERT}" -noout -subject | grep -o 'OU=[^/]*' | cut -d= -f2)
CERT_CN=$(openssl x509 -in "${NODE_CERT}" -noout -subject | grep -o 'CN=[^/]*' | cut -d= -f2)

echo -e "  Group (OU):  ${GREEN}${CERT_OU}${NC}"
echo -e "  Node (CN):   ${GREEN}${CERT_CN}${NC}"
echo -e "  Valid Until: $(openssl x509 -in "${NODE_CERT}" -noout -enddate | cut -d= -f2)"

# Verify certificate chain
if openssl verify -CAfile "${CA_CERT}" "${NODE_CERT}" > /dev/null 2>&1; then
    echo -e "  Chain:       ${GREEN}✓ Valid${NC}"
else
    echo -e "  Chain:       ${RED}✗ Invalid${NC}"
fi

echo ""
echo -e "${YELLOW}Environment Variables for Erlang:${NC}"
echo -e "  export GSMLG_EPMD_TLS_CERTFILE=\"${NODE_CERT}\""
echo -e "  export GSMLG_EPMD_TLS_KEYFILE=\"${NODE_KEY}\""
echo -e "  export GSMLG_EPMD_TLS_CACERTFILE=\"${NODE_DIR}/ca-cert.pem\""
echo -e "  export GSMLG_EPMD_GROUP=\"${GROUP_NAME}\""
echo ""

# Set proper permissions
chmod 600 "${NODE_KEY}"
chmod 644 "${NODE_CERT}"

echo -e "${GREEN}✓ Certificate permissions set${NC}"
echo ""
