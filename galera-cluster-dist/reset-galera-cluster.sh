#!/usr/bin/env bash
# ==============================================================
# reset-galera-cluster.sh
# Stop paksa semua node Galera, bersihkan state rusak, siap bootstrap.
# ==============================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

PRIMARY="${1:-mariadb_node_1}"
ANSIBLE_SHELL=( -e ansible_shell_executable=/bin/bash )

log_info "=== 1. Cek koneksi SSH ==="
if ! ansible all -m ping -f 4 2>/dev/null | grep -q SUCCESS; then
    log_error "Beberapa host tidak reachable. Perbaiki SSH/VPN dulu."
    ansible all -m ping || true
    exit 1
fi
log_ok "SSH ke semua host OK"

log_info "=== 2. Stop paksa MariaDB/Galera di semua node DB ==="
ansible mariadb_cluster -m shell --become -f 4 "${ANSIBLE_SHELL[@]}" -a '
systemctl unmask mariadb 2>/dev/null || true
timeout 20 systemctl stop mariadb 2>/dev/null || true
systemctl kill -s SIGKILL mariadb 2>/dev/null || true
pkill -9 mariadbd 2>/dev/null || true
pkill -9 -f wsrep_sst 2>/dev/null || true
systemctl reset-failed mariadb 2>/dev/null || true
systemctl disable mariadb 2>/dev/null || true
pgrep mariadbd >/dev/null 2>&1 && echo STILL_RUNNING || echo STOPPED
' || true

ansible mariadb_cluster -m shell --become -f 4 "${ANSIBLE_SHELL[@]}" -a '
pkill -9 mariadbd 2>/dev/null || true
pkill -9 -f wsrep_sst 2>/dev/null || true
systemctl reset-failed mariadb 2>/dev/null || true
pgrep mariadbd >/dev/null 2>&1 && echo STILL_RUNNING || echo STOPPED
' || true

log_info "=== 3. Bersihkan data Galera di node slave (node 2 & 3) ==="
ansible mariadb_node_2,mariadb_node_3 -m shell --become -f 2 "${ANSIBLE_SHELL[@]}" -a '
find /var/lib/mysql -mindepth 1 -maxdepth 1 -exec rm -rf {} +
echo WIPED
' || log_warn "Wipe slave gagal sebagian"

log_info "=== 4. Set safe_to_bootstrap di node primary (${PRIMARY}) ==="
ansible "${PRIMARY}" -m shell --become "${ANSIBLE_SHELL[@]}" -a '
GRASTATE="/var/lib/mysql/grastate.dat"
if [ -f "${GRASTATE}" ]; then
  sed -i "s/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/" "${GRASTATE}"
else
  cat > "${GRASTATE}" <<EOF
# GALERA saved state
version: 2.1
uuid:    00000000-0000-0000-0000-000000000000
seqno:   -1
safe_to_bootstrap: 1
EOF
fi
chown mysql:mysql "${GRASTATE}"
chmod 660 "${GRASTATE}"
cat "${GRASTATE}"
'

log_info "=== 5. Cek status akhir ==="
ansible mariadb_cluster -m shell --become -f 4 "${ANSIBLE_SHELL[@]}" -a '
printf "%s: mariadb=" "$(hostname)"
systemctl is-active mariadb 2>&1 || true
printf " mariadbd="
pgrep mariadbd || echo none
'

log_ok "Reset selesai."
