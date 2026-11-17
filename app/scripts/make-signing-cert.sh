#!/bin/sh
# 로컬 코드 서명 인증서 "Servers Local" 을 만들어 로그인 키체인에 넣는다 (한 번만).
# ad-hoc 서명은 빌드마다 서명이 달라져 macOS 가 권한(위치 등)을 다시 묻는다. 고정 인증서로 서명하면 권한이 유지된다.
# 실행 중 macOS 가 로그인 비밀번호를 한 번 묻는다 (인증서 신뢰 설정). 이후 첫 codesign 때 "항상 허용" 을 누르면 다시 묻지 않는다.
set -eu
name="Servers Local"
keychain="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning | grep -q "\"$name\""; then
  echo "already present: $name"; exit 0
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
O = local
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/ext.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" -out "$tmp/id.p12" -passout pass:servers
security import "$tmp/id.p12" -k "$keychain" -P servers -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# 코드 서명 정책에서 이 인증서를 신뢰 (사용자 도메인, 비밀번호 창이 한 번 뜬다)
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"
security find-identity -v -p codesigning | grep "$name" || { echo "인증서가 codesigning 에 보이지 않습니다. 키체인 접근에서 '$name' 신뢰 설정을 확인하세요." >&2; exit 1; }
echo "created: $name"
