#!/usr/bin/env bash
# ==============================================================
# pack-dist.sh — Build TUI (platform lokal) + rakit galera-cluster-dist
# Output: ../galera-cluster-dist/
# Untuk semua platform: gunakan GitHub Actions atau assemble-dist.sh
# ==============================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/.."
DIST="${SRC}/../galera-cluster-dist"
TUI_SRC="${SRC}/tui"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
log() { echo -e "${BLUE}[pack]${NC} $*"; }
ok()  { echo -e "${GREEN}[ok]${NC}  $*"; }
err() { echo -e "${RED}[err]${NC} $*" >&2; }

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${OS}-${ARCH}" in
    darwin-arm64|darwin-aarch64) PLATFORM="darwin-aarch64" ;;
    darwin-x86_64)               PLATFORM="darwin-x86_64" ;;
    linux-x86_64|linux-amd64)    PLATFORM="linux-x86_64" ;;
    linux-aarch64|linux-arm64)   PLATFORM="linux-aarch64" ;;
    mingw*|msys*|cygwin*)        PLATFORM="windows-x86_64" ;;
    *) err "Platform tidak dikenali: ${OS}-${ARCH}"; exit 1 ;;
esac

log "Source: ${SRC}"
log "Output: ${DIST}"
log "Platform binary: ${PLATFORM}"

log "Building galera-tui (release)..."
(cd "${TUI_SRC}" && cargo build --release) || { err "cargo build gagal"; exit 1; }

TUI_BIN="${TUI_SRC}/target/release/galera-tui"
if [[ "${PLATFORM}" == windows-x86_64 ]]; then
    TUI_BIN="${TUI_SRC}/target/release/galera-tui.exe"
fi
[[ -f "${TUI_BIN}" ]] || { err "Binary tidak ditemukan: ${TUI_BIN}"; exit 1; }

TMP_BIN="$(mktemp -d)"
trap 'rm -rf "${TMP_BIN}"' EXIT
mkdir -p "${TMP_BIN}/${PLATFORM}"
cp "${TUI_BIN}" "${TMP_BIN}/${PLATFORM}/"
chmod +x "${TMP_BIN}/${PLATFORM}/"* 2>/dev/null || true

export SRC DIST BIN_ROOT="${TMP_BIN}"
bash "${SCRIPT_DIR}/assemble-dist.sh"

echo ""
echo "  Langkah berikutnya:"
echo "    1. cd galera-cluster-dist"
echo "    2. ./configure-inventory.sh"
echo "    3. cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml"
echo "    4. cp group_vars_haproxy.yml.example group_vars_haproxy.yml"
echo "    5. ./start.sh"
echo ""
echo "  Semua platform sekaligus: push ke GitHub → Actions → artifact galera-cluster-dist.zip"
