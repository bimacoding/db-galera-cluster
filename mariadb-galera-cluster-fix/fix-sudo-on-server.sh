#!/usr/bin/env bash
# ==============================================================
# fix-sudo-on-server.sh
# Jalankan DI SETIAP SERVER (sebagai root), bukan di Mac.
# Contoh dari Mac (jika root login via SSH tersedia):
#   scp fix-sudo-on-server.sh root@10.219.3.50:/tmp/
#   ssh root@10.219.3.50 'bash /tmp/fix-sudo-on-server.sh vta'
# Atau paste isi script lewat console cloud provider.
# ==============================================================
set -Eeuo pipefail

SUDO_USER_NAME="${1:-vta}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Harus dijalankan sebagai root."
    exit 1
fi

SUDOERS_FILE="/etc/sudoers.d/${SUDO_USER_NAME}"

cat > "${SUDOERS_FILE}" <<EOF
# Ansible deploy — sudo tanpa password untuk ${SUDO_USER_NAME}
Defaults:${SUDO_USER_NAME} !requiretty
${SUDO_USER_NAME} ALL=(ALL) NOPASSWD:ALL
EOF

chmod 440 "${SUDOERS_FILE}"

if visudo -c; then
    echo "[OK] Sudo NOPASSWD aktif untuk user: ${SUDO_USER_NAME}"
    echo "[OK] Verifikasi (sebagai ${SUDO_USER_NAME}): sudo -n whoami  => harus 'root'"
else
    echo "[ERROR] visudo -c gagal. Periksa ${SUDOERS_FILE}"
    exit 1
fi
