#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GALERA_CLUSTER_DIR="${ROOT}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${OS}-${ARCH}" in
    darwin-arm64|darwin-aarch64) PLAT="darwin-aarch64" ;;
    darwin-x86_64)               PLAT="darwin-x86_64" ;;
    linux-x86_64|linux-amd64)    PLAT="linux-x86_64" ;;
    linux-aarch64|linux-arm64)   PLAT="linux-aarch64" ;;
    *) echo "[ERROR] Platform ${OS}-${ARCH} — binary belum tersedia di bin/"; exit 1 ;;
esac

BIN="${ROOT}/bin/${PLAT}/galera-tui"
[[ -x "${BIN}" ]] || { echo "[ERROR] Binary tidak ada: ${BIN}"; echo "        Build di platform ini atau minta release binary ${PLAT}"; exit 1; }
exec "${BIN}"
