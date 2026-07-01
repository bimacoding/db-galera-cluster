#!/usr/bin/env bash
# ==============================================================
# setup-ssh.sh
# Setup SSH key (generate + copy ke banyak server sekaligus)
# untuk persiapan deploy MariaDB Galera Cluster.
# ==============================================================
# Jalankan ini DULUAN, sebelum configure-inventory.sh, supaya semua
# server tujuan sudah bisa diakses passwordless lewat SSH key.
# ==============================================================
# Cara pakai:
#   chmod +x setup-ssh.sh
#   ./setup-ssh.sh
#
# Mode input server bisa:
#   1) Diketik manual satu-satu (interaktif)
#   2) Dibaca dari file daftar (format: ip[,port[,user]] per baris)
# ==============================================================

set -Eeuo pipefail

# ==============================================================
# WARNA OUTPUT
# ==============================================================
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
SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"
SERVERS=()        # format tiap elemen: "ip|port|user"
RESULTS=()        # format tiap elemen: "ip|status"

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
# CEK / INSTALL PRASYARAT (ssh-keygen, ssh-copy-id, sshpass)
# ==============================================================
check_prerequisites() {
    log_step "1. Cek Prasyarat"

    if ! command -v ssh-keygen &>/dev/null || ! command -v ssh-copy-id &>/dev/null; then
        log_warn "openssh-client belum lengkap. Mencoba install..."
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-client
    fi
    log_success "ssh-keygen & ssh-copy-id tersedia"

    if ! command -v sshpass &>/dev/null; then
        log_warn "sshpass tidak ditemukan (dibutuhkan untuk login pakai password, opsional)."
        read -r -p "Install sshpass sekarang? (y/N): " install_sshpass
        if [[ "${install_sshpass}" =~ ^[Yy]$ ]]; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass || \
                log_warn "Gagal install sshpass. Mode password manual masih bisa dipakai (akan diminta password tiap server)."
        fi
    else
        log_success "sshpass tersedia"
    fi
}

# ==============================================================
# GENERATE SSH KEY (kalau belum ada)
# ==============================================================
generate_ssh_key() {
    log_step "2. Setup SSH Key Lokal"

    if [ -f "${SSH_KEY_PATH}" ]; then
        log_success "SSH key sudah ada: ${SSH_KEY_PATH}.pub"
    else
        log_info "Membuat SSH key ed25519 baru..."
        ssh-keygen -t ed25519 -f "${SSH_KEY_PATH}" -N "" -C "galera-cluster@$(hostname)-$(date +%Y%m%d)"
        log_success "SSH key dibuat: ${SSH_KEY_PATH}.pub"
    fi

    echo ""
    echo -e "${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}  PUBLIC KEY:${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    cat "${SSH_KEY_PATH}.pub"
    echo -e "${YELLOW}====================================================${NC}"
    echo ""
}

# ==============================================================
# INPUT DAFTAR SERVER -- MODE MANUAL
# ==============================================================
input_servers_manual() {
    log_step "3. Input Server Satu per Satu"

    echo "Masukkan informasi tiap server. Ketik 'selesai' di IP Address untuk berhenti."
    echo ""

    while true; do
        echo "--- Server ke-$((${#SERVERS[@]} + 1)) ---"
        read -r -p "  IP Address (atau 'selesai'): " ip

        if [[ "${ip}" == "selesai" || "${ip}" == "done" ]]; then
            break
        fi

        if ! is_valid_ip "${ip}"; then
            log_error "  Format IP tidak valid: '${ip}'. Coba lagi."
            continue
        fi

        read -r -p "  SSH Port [22]     : " port
        port="${port:-22}"
        read -r -p "  SSH User [ubuntu] : " user
        user="${user:-ubuntu}"

        SERVERS+=("${ip}|${port}|${user}")
        log_success "  Ditambahkan: ${user}@${ip}:${port}"
        echo ""
    done

    if [ ${#SERVERS[@]} -eq 0 ]; then
        log_warn "Tidak ada server yang dimasukkan."
    fi
}

# ==============================================================
# INPUT DAFTAR SERVER -- MODE FILE
# ==============================================================
input_servers_from_file() {
    log_step "3. Input Server dari File"

    echo "Format file: satu server per baris -> ip,port,user"
    echo "Contoh:"
    echo "  192.168.10.2,22,ubuntu"
    echo "  192.168.10.3,22,ubuntu"
    echo "  192.168.10.5,22,root"
    echo "(port dan user opsional, default 22 dan ubuntu)"
    echo ""
    read -r -p "Path file daftar server: " list_file

    if [ ! -f "${list_file}" ]; then
        log_error "File tidak ditemukan: ${list_file}"
        return 1
    fi

    local line_num=0
    while IFS=',' read -r ip port user || [ -n "${ip:-}" ]; do
        ((line_num++)) || true
        ip="$(echo "${ip}" | xargs)"   # trim whitespace
        [ -z "${ip}" ] && continue
        [[ "${ip}" =~ ^# ]] && continue  # skip komentar

        if ! is_valid_ip "${ip}"; then
            log_error "  Baris ${line_num}: IP tidak valid '${ip}', dilewati."
            continue
        fi

        port="$(echo "${port:-22}" | xargs)"
        port="${port:-22}"
        user="$(echo "${user:-ubuntu}" | xargs)"
        user="${user:-ubuntu}"

        SERVERS+=("${ip}|${port}|${user}")
        log_success "  Dibaca: ${user}@${ip}:${port}"
    done < "${list_file}"

    if [ ${#SERVERS[@]} -eq 0 ]; then
        log_warn "Tidak ada server valid yang terbaca dari file."
    fi
}

# ==============================================================
# COPY SSH KEY KE SATU SERVER
# ==============================================================
copy_key_to_server() {
    local ip="$1" port="$2" user="$3" password="$4"

    if [ -n "${password}" ] && command -v sshpass &>/dev/null; then
        sshpass -p "${password}" ssh-copy-id \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            -p "${port}" \
            -i "${SSH_KEY_PATH}.pub" \
            "${user}@${ip}" 2>/dev/null
        return $?
    fi

    # Tanpa sshpass: ssh-copy-id akan minta password interaktif kalau
    # key belum terpasang dan login password masih aktif.
    ssh-copy-id \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -p "${port}" \
        -i "${SSH_KEY_PATH}.pub" \
        "${user}@${ip}"
    return $?
}

# ==============================================================
# PROSES COPY KE SEMUA SERVER
# ==============================================================
copy_to_all_servers() {
    log_step "4. Copy SSH Key ke Semua Server"

    if [ ${#SERVERS[@]} -eq 0 ]; then
        log_warn "Tidak ada server untuk diproses."
        return
    fi

    echo "Server yang akan diproses:"
    for s in "${SERVERS[@]}"; do
        local ip port user
        ip="$(echo "${s}" | cut -d'|' -f1)"
        port="$(echo "${s}" | cut -d'|' -f2)"
        user="$(echo "${s}" | cut -d'|' -f3)"
        echo "  - ${user}@${ip}:${port}"
    done
    echo ""

    echo "Pilih metode autentikasi awal ke server (sebelum key terpasang):"
    echo "  a) Password SAMA untuk semua server (lebih cepat)"
    echo "  b) Password BERBEDA per server (akan ditanya satu-satu)"
    echo "  c) Sudah pakai key lain / passwordless (langsung copy tanpa password)"
    read -r -p "Pilihan (a/b/c) [a]: " auth_mode
    auth_mode="${auth_mode:-a}"

    local shared_password=""
    if [[ "${auth_mode}" == "a" ]]; then
        read -r -s -p "Masukkan password SSH (sama untuk semua server): " shared_password
        echo ""
    fi

    for s in "${SERVERS[@]}"; do
        local ip port user password
        ip="$(echo "${s}" | cut -d'|' -f1)"
        port="$(echo "${s}" | cut -d'|' -f2)"
        user="$(echo "${s}" | cut -d'|' -f3)"
        password=""

        case "${auth_mode}" in
            a) password="${shared_password}" ;;
            b)
                read -r -s -p "Password untuk ${user}@${ip}: " password
                echo ""
                ;;
            c) password="" ;;
        esac

        log_info "Memproses ${user}@${ip}:${port}..."

        if copy_key_to_server "${ip}" "${port}" "${user}" "${password}"; then
            log_success "  Key berhasil terpasang di ${ip}"
            RESULTS+=("${ip}|OK")
        else
            log_error "  Gagal pasang key di ${ip}. Coba manual:"
            echo "    ssh-copy-id -p ${port} ${user}@${ip}"
            RESULTS+=("${ip}|FAILED")
        fi
        echo ""
    done

    unset shared_password
}

# ==============================================================
# TEST KONEKSI SETELAH KEY TERPASANG
# ==============================================================
test_all_connections() {
    log_step "5. Tes Koneksi SSH Tanpa Password"

    if [ ${#SERVERS[@]} -eq 0 ]; then
        log_warn "Tidak ada server untuk ditest."
        return
    fi

    local all_ok=true

    for s in "${SERVERS[@]}"; do
        local ip port user
        ip="$(echo "${s}" | cut -d'|' -f1)"
        port="$(echo "${s}" | cut -d'|' -f2)"
        user="$(echo "${s}" | cut -d'|' -f3)"

        log_info "Test ${user}@${ip}:${port}..."
        if ssh -o ConnectTimeout=5 \
               -o BatchMode=yes \
               -o StrictHostKeyChecking=accept-new \
               -p "${port}" \
               -i "${SSH_KEY_PATH}" \
               "${user}@${ip}" "hostname && uptime -p 2>/dev/null || true" 2>/dev/null; then
            log_success "  ${ip} -> OK (passwordless berhasil)"
        else
            log_error "  ${ip} -> GAGAL (masih minta password / tidak bisa connect)"
            all_ok=false
        fi
    done

    echo ""
    if [ "${all_ok}" = true ]; then
        log_success "Semua server bisa diakses passwordless. Siap lanjut ke configure-inventory.sh"
    else
        log_warn "Sebagian server masih gagal. Cek koneksi/firewall/password sebelum lanjut deploy."
    fi
}

# ==============================================================
# RINGKASAN HASIL
# ==============================================================
print_summary() {
    log_step "Ringkasan"

    if [ ${#RESULTS[@]} -eq 0 ]; then
        log_info "Tidak ada proses copy key yang dijalankan (mungkin langsung ke tes koneksi)."
        return
    fi

    printf "%-20s %-10s\n" "IP" "STATUS"
    printf "%-20s %-10s\n" "--" "------"
    for r in "${RESULTS[@]}"; do
        local ip status
        ip="$(echo "${r}" | cut -d'|' -f1)"
        status="$(echo "${r}" | cut -d'|' -f2)"
        if [ "${status}" = "OK" ]; then
            printf "%-20s ${GREEN}%-10s${NC}\n" "${ip}" "${status}"
        else
            printf "%-20s ${RED}%-10s${NC}\n" "${ip}" "${status}"
        fi
    done
    echo ""
}

# ==============================================================
# MAIN
# ==============================================================
main() {
    clear
    echo ""
    echo -e "${CYAN}+----------------------------------------------------------+${NC}"
    echo -e "${CYAN}|            Setup SSH Key untuk Galera Cluster            |${NC}"
    echo -e "${CYAN}+----------------------------------------------------------+${NC}"
    echo ""
    echo "Jalankan ini sebelum configure-inventory.sh agar SSH ke semua"
    echo "node database + load balancer sudah siap passwordless."
    echo ""

    check_prerequisites
    generate_ssh_key

    log_step "3. Pilih Cara Input Server"
    echo "  a) Input manual satu per satu (interaktif)"
    echo "  b) Baca dari file daftar (ip,port,user per baris)"
    read -r -p "Pilihan (a/b) [a]: " input_mode
    input_mode="${input_mode:-a}"

    case "${input_mode}" in
        b|B) input_servers_from_file ;;
        *)   input_servers_manual ;;
    esac

    if [ ${#SERVERS[@]} -eq 0 ]; then
        log_warn "Tidak ada server yang valid. Keluar."
        exit 0
    fi

    copy_to_all_servers
    test_all_connections
    print_summary

    echo ""
    echo -e "${GREEN}Setup SSH selesai. Selanjutnya jalankan:${NC}"
    echo "  ./configure-inventory.sh"
    echo ""
}

main "$@"
