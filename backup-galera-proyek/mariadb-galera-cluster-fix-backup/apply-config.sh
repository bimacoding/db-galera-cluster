#!/usr/bin/env bash
# Deploy config MariaDB permanen + rolling restart semua node Galera.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Ambil mariadb_sst_password dari deploy-mariadb-cluster.yml (sumber tunggal)
SST_PASS="$(grep -m1 'mariadb_sst_password:' deploy-mariadb-cluster.yml \
  | sed -E 's/.*mariadb_sst_password:[[:space:]]*"([^"]+)".*/\1/')"
ROOT_PASS="$(grep -m1 'mariadb_root_password:' deploy-mariadb-cluster.yml \
  | sed -E 's/.*mariadb_root_password:[[:space:]]*"([^"]+)".*/\1/')"

if [ -z "${SST_PASS}" ] || [ -z "${ROOT_PASS}" ]; then
    echo "[ERROR] Tidak bisa baca password dari deploy-mariadb-cluster.yml"
    exit 1
fi

echo "[INFO] Deploy config + rolling restart (serial: 1)..."
exec ansible-playbook apply-config.yml \
    -e "mariadb_sst_password=${SST_PASS}" \
    -e "mariadb_root_password=${ROOT_PASS}" \
    "$@"
