#!/usr/bin/env bash
# ==============================================================
# configure-inventory.sh
# Atur IP dan username SSH untuk cluster MariaDB Galera + HAProxy
# secara interaktif. Hanya ansible_host, interface_ip, dan
# ansible_user yang diubah — port (22) dan nama host tetap.
# ==============================================================
# Cara pakai:
#   chmod +x configure-inventory.sh
#   ./configure-inventory.sh
# ==============================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo ""; echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"; }

trap 'log_error "Script berhenti tidak terduga di baris $LINENO."' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${SCRIPT_DIR}/inventory.yml"
SSH_PORT=22

# Nama host tetap (tidak bisa diubah lewat script ini)
HOST_NODE_1="mariadb_node_1"
HOST_NODE_2="mariadb_node_2"
HOST_NODE_3="mariadb_node_3"
HOST_LB="haproxy_load_balancer"

# IP per host
IP_NODE_1=""
IP_NODE_2=""
IP_NODE_3=""
IP_LB=""
SSH_USER=""

# ==============================================================
# VALIDASI IP
# ==============================================================
is_valid_ip() {
    local ip="$1"
    if [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}"
        [[ "${o1}" -le 255 && "${o2}" -le 255 && "${o3}" -le 255 && "${o4}" -le 255 ]]
        return $?
    fi
    return 1
}

# ==============================================================
# VALIDASI USERNAME SSH
# ==============================================================
is_valid_username() {
    local user="$1"
    [[ -n "${user}" && "${user}" =~ ^[a-zA-Z0-9._-]+$ ]]
}

# ==============================================================
# SIMPAN IP KE VAR HOST
# ==============================================================
set_host_ip() {
    local host="$1"
    local ip="$2"

    case "${host}" in
        "${HOST_NODE_1}") IP_NODE_1="${ip}" ;;
        "${HOST_NODE_2}") IP_NODE_2="${ip}" ;;
        "${HOST_NODE_3}") IP_NODE_3="${ip}" ;;
        "${HOST_LB}")     IP_LB="${ip}" ;;
    esac
}

# ==============================================================
# BACA IP DARI SATU BARIS INVENTORY (format INI)
# ==============================================================
read_host_ip_from_ini_line() {
    local line="$1"
    local host="$2"
    local ip=""

    if [[ "${line}" =~ ^${host}[[:space:]]+ansible_host=([^[:space:]]+) ]]; then
        ip="${BASH_REMATCH[1]}"
        set_host_ip "${host}" "${ip}"
    fi
}

# ==============================================================
# BACA NILAI SAAT INI DARI inventory.yml (INI atau YAML)
# ==============================================================
parse_current_inventory() {
    if [ ! -f "${INVENTORY_FILE}" ]; then
        log_warn "File inventory belum ada: ${INVENTORY_FILE}"
        return 0
    fi

    local line user ip current_host=""
    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Format INI: mariadb_node_1 ansible_host=...
        read_host_ip_from_ini_line "${line}" "${HOST_NODE_1}"
        read_host_ip_from_ini_line "${line}" "${HOST_NODE_2}"
        read_host_ip_from_ini_line "${line}" "${HOST_NODE_3}"
        read_host_ip_from_ini_line "${line}" "${HOST_LB}"

        if [[ "${line}" =~ ansible_user=([^[:space:]]+) ]]; then
            user="${BASH_REMATCH[1]}"
            if [ -z "${SSH_USER}" ]; then
                SSH_USER="${user}"
            fi
        fi

        # Format YAML: blok host lalu ansible_host:
        if [[ "${line}" =~ ^[[:space:]]*(mariadb_node_[123]|haproxy_load_balancer):[[:space:]]*$ ]]; then
            current_host="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ -n "${current_host}" && "${line}" =~ ansible_host:[[:space:]]*(.+) ]]; then
            ip="$(echo "${BASH_REMATCH[1]}" | tr -d ' "')"
            set_host_ip "${current_host}" "${ip}"
        fi

        if [[ "${line}" =~ ansible_user:[[:space:]]*(.+) ]]; then
            user="$(echo "${BASH_REMATCH[1]}" | tr -d ' "')"
            if [ -z "${SSH_USER}" ]; then
                SSH_USER="${user}"
            fi
        fi
    done < "${INVENTORY_FILE}"
}

# ==============================================================
# PROMPT SATU IP DENGAN DEFAULT
# ==============================================================
prompt_ip() {
    local label="$1"
    local default_ip="$2"
    local __result_var="$3"
    local ip=""
    local current=""

    eval "current=\"\${${__result_var}}\""

    while true; do
        if [ -n "${current}" ]; then
            read -r -p "  IP ${label} [${current}]: " ip
            ip="${ip:-${current}}"
        elif [ -n "${default_ip}" ]; then
            read -r -p "  IP ${label} [${default_ip}]: " ip
            ip="${ip:-${default_ip}}"
        else
            read -r -p "  IP ${label}: " ip
        fi

        if is_valid_ip "${ip}"; then
            eval "${__result_var}=\"${ip}\""
            break
        fi
        log_error "  Format IP tidak valid: '${ip}'. Contoh: 192.168.10.2"
    done
}

# ==============================================================
# INPUT INTERAKTIF
# ==============================================================
collect_settings() {
    log_step "Konfigurasi IP & Username SSH"

    echo "Masukkan IP untuk tiap node. Tekan Enter untuk memakai nilai saat ini."
    echo "Hanya IP dan username yang bisa diubah (port tetap ${SSH_PORT})."
    echo ""

    prompt_ip "MariaDB Node 1 (${HOST_NODE_1})" "" "IP_NODE_1"
    prompt_ip "MariaDB Node 2 (${HOST_NODE_2})" "" "IP_NODE_2"
    prompt_ip "MariaDB Node 3 (${HOST_NODE_3})" "" "IP_NODE_3"
    prompt_ip "HAProxy Load Balancer (${HOST_LB})" "" "IP_LB"

    echo ""
    local default_user="${SSH_USER:-ubuntu}"
    while true; do
        read -r -p "Username SSH untuk semua host [${default_user}]: " input_user
        SSH_USER="${input_user:-${default_user}}"

        if is_valid_username "${SSH_USER}"; then
            break
        fi
        log_error "  Username tidak valid. Gunakan huruf, angka, titik, underscore, atau strip."
    done
}

# ==============================================================
# CEK IP DUPLIKAT
# ==============================================================
check_duplicate_ips() {
    local ips=("${IP_NODE_1}" "${IP_NODE_2}" "${IP_NODE_3}" "${IP_LB}")
    local hosts=("${HOST_NODE_1}" "${HOST_NODE_2}" "${HOST_NODE_3}" "${HOST_LB}")
    local i j

    for ((i = 0; i < ${#ips[@]}; i++)); do
        for ((j = i + 1; j < ${#ips[@]}; j++)); do
            if [ "${ips[i]}" = "${ips[j]}" ]; then
                log_warn "IP ${ips[i]} dipakai oleh ${hosts[i]} dan ${hosts[j]}."
                read -r -p "Lanjutkan meski IP duplikat? (y/N): " confirm
                if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
                    return 1
                fi
                return 0
            fi
        done
    done
    return 0
}

# ==============================================================
# RINGKASAN SEBELUM SIMPAN
# ==============================================================
show_summary() {
    log_step "Ringkasan Konfigurasi"

    echo ""
    printf "  %-28s %-18s %-10s %s\n" "HOST" "IP" "PORT" "USER"
    printf "  %-28s %-18s %-10s %s\n" "----" "--" "----" "----"
    printf "  %-28s %-18s %-10s %s\n" "${HOST_NODE_1}" "${IP_NODE_1}" "${SSH_PORT}" "${SSH_USER}"
    printf "  %-28s %-18s %-10s %s\n" "${HOST_NODE_2}" "${IP_NODE_2}" "${SSH_PORT}" "${SSH_USER}"
    printf "  %-28s %-18s %-10s %s\n" "${HOST_NODE_3}" "${IP_NODE_3}" "${SSH_PORT}" "${SSH_USER}"
    printf "  %-28s %-18s %-10s %s\n" "${HOST_LB}" "${IP_LB}" "${SSH_PORT}" "${SSH_USER}"
    echo ""
}

# ==============================================================
# TULIS BLOK HOST INVENTORY (format YAML)
# ==============================================================
write_inventory_host_yaml() {
    local host="$1"
    local ip="$2"
    cat <<EOF
        ${host}:
          ansible_host: ${ip}
          ansible_port: ${SSH_PORT}
          ansible_user: ${SSH_USER}
          interface_ip: ${ip}
EOF
}

# ==============================================================
# TULIS inventory.yml (format YAML, kompatibel Ansible 14+)
# ==============================================================
write_inventory() {
    local backup_file=""

    if [ -f "${INVENTORY_FILE}" ]; then
        backup_file="${INVENTORY_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp "${INVENTORY_FILE}" "${backup_file}"
        log_info "Backup dibuat: ${backup_file}"
    fi

    {
        cat <<'HEADER_EOF'
# inventory.yml — format YAML (kompatibel Ansible 14+)
# Dikonfigurasi oleh configure-inventory.sh
#
# Jika server memiliki LEBIH DARI SATU network interface (umum di
# VPS cloud: NIC publik + NIC privat/VPC), set interface_ip per host
# agar Galera & HAProxy bind ke IP yang benar.

HEADER_EOF
        echo "all:"
        echo "  children:"
        echo "    mariadb_cluster:"
        echo "      hosts:"
        write_inventory_host_yaml "${HOST_NODE_1}" "${IP_NODE_1}"
        write_inventory_host_yaml "${HOST_NODE_2}" "${IP_NODE_2}"
        write_inventory_host_yaml "${HOST_NODE_3}" "${IP_NODE_3}"
        echo "    load_balancer:"
        echo "      hosts:"
        write_inventory_host_yaml "${HOST_LB}" "${IP_LB}"
    } > "${INVENTORY_FILE}"

    log_success "File inventory berhasil diperbarui: ${INVENTORY_FILE}"
}

# ==============================================================
# MAIN
# ==============================================================
main() {
    log_step "Configure Inventory — MariaDB Galera Cluster"

    if [ ! -d "${SCRIPT_DIR}" ]; then
        log_error "Direktori script tidak ditemukan."
        exit 1
    fi

    parse_current_inventory
    collect_settings

    if ! check_duplicate_ips; then
        log_info "Konfigurasi dibatalkan."
        exit 0
    fi

    show_summary

    read -r -p "Simpan perubahan ke inventory.yml? (Y/n): " confirm_save
    if [[ "${confirm_save}" =~ ^[Nn]$ ]]; then
        log_info "Perubahan tidak disimpan."
        exit 0
    fi

    write_inventory

    echo ""
    echo -e "${YELLOW}Isi inventory.yml:${NC}"
    cat "${INVENTORY_FILE}"
    echo ""
    log_success "Selesai. Jalankan ansible-playbook dengan -i inventory.yml"
}

main "$@"
