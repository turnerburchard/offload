#!/bin/zsh
# Runs the self-test INCLUDING the certificate-pinning tests.
# Makes two throwaway self-signed code-signing certs in a temporary keychain, temporarily adds that keychain
# to the user search list (codesign can only find untrusted certs that way), and always restores the
# original search list and deletes the keychain afterwards. The login keychain is never modified.
# Usage: scripts/test-signing.sh [scratch-dir]      (build first: ./build.sh)
set -euo pipefail
cd "${0:A:h}/.."
SCRATCH=${1:-$(mktemp -d)}
mkdir -p "$SCRATCH/certs"
K="$SCRATCH/certs/offload-test.keychain-db"
KPW=$(uuidgen)

saved=("${(@f)$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')}")
cleanup() {
  security list-keychains -d user -s "${saved[@]}"
  security delete-keychain "$K" 2>/dev/null || true
  rm -rf "$SCRATCH/certs"
}
trap cleanup EXIT

LEGACY=(); openssl version | grep -q LibreSSL || LEGACY=(-legacy)   # OpenSSL 3 p12s need -legacy for `security import`
security create-keychain -p "$KPW" "$K"
security unlock-keychain -p "$KPW" "$K"
for n in A B; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Offload Test $n" \
    -keyout "$SCRATCH/certs/$n.key" -out "$SCRATCH/certs/$n.crt" \
    -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  openssl pkcs12 -export $LEGACY -inkey "$SCRATCH/certs/$n.key" -in "$SCRATCH/certs/$n.crt" \
    -name "Offload Test $n" -out "$SCRATCH/certs/$n.p12" -passout pass:test
  security import "$SCRATCH/certs/$n.p12" -k "$K" -P test -T /usr/bin/codesign >/dev/null
done
security set-key-partition-list -S apple-tool:,apple: -s -k "$KPW" "$K" >/dev/null
security list-keychains -d user -s "$K" "${saved[@]}"

ids=(${(f)"$(security find-identity -p codesigning "$K" | awk '/[0-9A-F]{40}/ {print $2}' | sort -u)"})
[[ ${#ids} -eq 2 ]] || { echo "expected 2 identities, got ${#ids}" >&2; exit 1; }
OFFLOAD_TEST_SIGN_IDS="${ids[1]},${ids[2]}" .build/release/offload-selftest "$SCRATCH/selftest"
