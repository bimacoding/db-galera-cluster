#!/usr/bin/env bash
# Jalankan deploy MariaDB Galera Cluster dari Mac / mesin administrator.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

SECRETS_FILE="${SCRIPT_DIR}/group_vars/all/secrets.yml"

if [ ! -f "${SECRETS_FILE}" ]; then
    echo "[ERROR] ${SECRETS_FILE} tidak ditemukan."
    echo "        Salin: cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml"
    echo "        Lalu isi ansible_become_password (password sudo user vta)."
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/group_vars_haproxy.yml" ]; then
    echo "[ERROR] group_vars_haproxy.yml tidak ditemukan."
    exit 1
fi

echo "[INFO] Pre-flight: cek SSH ke semua host..."
ansible all -m ping "$@" || {
    echo "[WARN] Beberapa host gagal ping SSH. Perbaiki koneksi/VPN dulu."
    echo "       Node 2 (10.219.3.51) sering timeout jika VPN putus."
    read -r -p "Lanjut deploy anyway? (y/N): " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
}

# Cek sudo: NOPASSWD atau password di group_vars/all/secrets.yml
echo "[INFO] Cek sudo (become)..."
if ansible all -m command -a "whoami" --become 2>/dev/null | grep -q "UNREACHABLE\\|FAILED"; then
    echo "[WARN] Sudo gagal. Pilih salah satu:"
    echo "  1) Jalankan fix-sudo-on-server.sh di SETIAP server (sebagai root)"
    echo "  2) Isi password sudo Linux user vta di group_vars/all/secrets.yml"
    echo "     (BUKAN password MariaDB di .pass / deploy-mariadb-cluster.yml)"
    read -r -p "Lanjut deploy anyway? (y/N): " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
fi

exec ansible-playbook --fork=1 deploy-mariadb-cluster.yml \
    -e @group_vars_haproxy.yml \
    "$@"
