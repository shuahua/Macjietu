#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="JietuFree Local Development"
CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/.build/certs"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

mkdir -p "$CERT_DIR"

cat > "$CERT_DIR/codesign.cnf" <<'EOF'
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = ext

[ dn ]
CN = JietuFree Local Development

[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl req -x509 \
  -newkey rsa:2048 \
  -keyout "$CERT_DIR/截图FreeLocal.key" \
  -out "$CERT_DIR/截图FreeLocal.crt" \
  -days 3650 \
  -nodes \
  -config "$CERT_DIR/codesign.cnf"

openssl pkcs12 -legacy -export \
  -out "$CERT_DIR/截图FreeLocal.p12" \
  -inkey "$CERT_DIR/截图FreeLocal.key" \
  -in "$CERT_DIR/截图FreeLocal.crt" \
  -passout pass:localdev

security import "$CERT_DIR/截图FreeLocal.p12" \
  -k "$KEYCHAIN" \
  -P "localdev" \
  -T /usr/bin/codesign >/dev/null

security add-trusted-cert \
  -d \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$CERT_DIR/截图FreeLocal.crt" >/dev/null

printf '%s\n' "已创建并信任本地签名证书：$CERT_NAME"
