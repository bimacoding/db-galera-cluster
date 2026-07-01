#!/usr/bin/env bash
# Cek koneksi SSH (dari Mac) dan mesh ping antar-node Galera.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NODES=(50 51 52)
LB=53
USER="${1:-vta}"

log_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "=== 1. SSH dari Mac ke semua host ==="
for ip in "${NODES[@]}" "$LB"; do
    host="10.219.3.${ip}"
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "${USER}@${host}" "hostname" &>/dev/null; then
        log_ok "SSH ${host}"
    else
        log_fail "SSH ${host} — tidak bisa dijangkau dari Mac"
    fi
done

echo ""
echo "=== 2. Ping antar-node (dari node 3 sebagai witness) ==="
WITNESS="10.219.3.52"
for target in 50 51 53; do
    result=$(ssh -o ConnectTimeout=10 "${USER}@${WITNESS}" \
        "ping -c 2 -W 2 10.219.3.${target} >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null || echo "SSH_FAIL")
    if [ "${result}" = "OK" ]; then
        log_ok "node3 -> 10.219.3.${target} ping"
    else
        log_fail "node3 -> 10.219.3.${target} ping (${result})"
    fi
done

echo ""
echo "=== 3. Cek MAC address (duplikat = penyebab node1<->node2 gagal) ==="
mac_table=$(ssh -o ConnectTimeout=10 "${USER}@${WITNESS}" \
    "for ip in 50 51 52 53; do printf '%s ' 10.219.3.\$ip; ip neigh show 10.219.3.\$ip 2>/dev/null | awk '{print \$5}'; done" 2>/dev/null || true)

if [ -n "${mac_table}" ]; then
    echo "${mac_table}"
    dup=$(echo "${mac_table}" | awk '{print $2}' | sort | uniq -d)
    if [ -n "${dup}" ]; then
        log_fail "MAC DUPLIKAT terdeteksi: ${dup}"
        echo ""
        echo "  Node 1 (.50) dan Node 2 (.51) kemungkinan punya MAC address sama"
        echo "  (biasanya karena clone VM Proxmox/cloud tanpa regenerate MAC)."
        echo ""
        echo "  PERBAIKAN di hypervisor (Proxmox/cloud panel):"
        echo "    - Stop VM node 1 ATAU node 2"
        echo "    - Regenerate / ganti MAC address network interface (ens18)"
        echo "    - Pastikan setiap VM punya MAC UNIK"
        echo "    - Start ulang VM, lalu jalankan script ini lagi"
    else
        log_ok "Tidak ada MAC duplikat terdeteksi dari node 3"
    fi
else
    log_warn "Tidak bisa baca tabel MAC dari node 3"
fi

echo ""
echo "=== 4. Tes kritis: node1 <-> node2 (wajib untuk Galera) ==="
n1_n2=$(ssh -o ConnectTimeout=10 "${USER}@10.219.3.50" \
    "ping -c 2 -W 2 10.219.3.51 >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null || echo "SSH_FAIL")
n2_n1=$(ssh -o ConnectTimeout=10 "${USER}@10.219.3.51" \
    "ping -c 2 -W 2 10.219.3.50 >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null || echo "SSH_FAIL")

if [ "${n1_n2}" = "OK" ] && [ "${n2_n1}" = "OK" ]; then
    log_ok "node1 <-> node2 saling reach"
else
    log_fail "node1 <-> node2 GAGAL (node1->node2: ${n1_n2}, node2->node1: ${n2_n1})"
    echo "  Galera cluster TIDAK akan sync sampai ini diperbaiki."
fi

echo ""
echo "=== Selesai ==="
