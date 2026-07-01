#!/usr/bin/env bash
# Stop paksa, reset state Galera, deploy ulang sampai selesai.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "[1/2] Reset cluster..."
"${SCRIPT_DIR}/reset-galera-cluster.sh"

echo ""
echo "[2/2] Deploy playbook..."
exec ansible-playbook --fork=1 deploy-mariadb-cluster.yml -e @group_vars_haproxy.yml "$@"
