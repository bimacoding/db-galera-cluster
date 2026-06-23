#!/usr/bin/env bash
# ==============================================================
# PREPARE & DEPLOY SCRIPT
# MariaDB/MySQL Galera Cluster + HAProxy
# ==============================================================
# Mendukung:
#   - Ubuntu 20.04, 22.04, 24.04
#   - Debian 11, 13
# ==============================================================
# Cara pakai:
#   chmod +x prepare-cluster.sh
#   ./prepare-cluster.sh
# ==============================================================

set -euo pipefail

# ==============================================================
# WARNA OUTPUT
# ==============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==============================================================
# KONFIGURASI DEFAULT
# ==============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_DIR=""
INVENTORY_FILE=""
DEPLOY_FILE=""
CLUSTER_GROUP=""
CLUSTER_TYPE=""
CLUSTER_NODES=()
LB_NODE=""
SSH_USER=""
SSH_PORT=22
MYSQL_ROOT_PASSWORD=""
CLUSTER_NAME=""
OS_ID=""
OS_VERSION=""
OS_CODENAME=""

# ==============================================================
# FUNGSI: LOG & OUTPUT
# ==============================================================
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo ""; echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"; }

# ==============================================================
# FUNGSI: DETEKSI OS
# ==============================================================
detect_os() {
    log_step "1. Deteksi Sistem Operasi"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID,,}"
        OS_VERSION="${VERSION_ID}"
        OS_CODENAME="${VERSION_CODENAME,,}"
    else
        log_error "Tidak dapat mendeteksi OS. File /etc/os-release tidak ditemukan."
        exit 1
    fi

    # Mapping OS
    case "${OS_ID}" in
        ubuntu)
            case "${OS_VERSION}" in
                20.04|22.04|24.04)
                    log_success "Terdeteksi: Ubuntu ${OS_VERSION} (${OS_CODENAME})"
                    ;;
                *)
                    log_warn "Ubuntu ${OS_VERSION} belum diuji secara resmi. Tetap melanjutkan..."
                    ;;
            esac
            ;;
        debian)
            case "${OS_VERSION}" in
                11)
                    log_success "Terdeteksi: Debian 11 (Bullseye)"
                    OS_CODENAME="bullseye"
                    ;;
                12)
                    log_warn "Debian 12 (Bookworm) belum diuji resmi. Tetap melanjutkan..."
                    OS_CODENAME="bookworm"
                    ;;
                13)
                    log_success "Terdeteksi: Debian 13 (Trixie)"
                    OS_CODENAME="trixie"
                    ;;
                *)
                    log_warn "Debian ${OS_VERSION} belum diuji secara resmi. Tetap melanjutkan..."
                    ;;
            esac
            ;;
        *)
            log_error "OS tidak didukung: ${OS_ID} ${OS_VERSION}"
            log_error "Hanya Ubuntu 20.04/22.04/24.04 dan Debian 11/13 yang didukung."
            exit 1
            ;;
    esac

    log_info "Architecture: $(uname -m)"
    log_info "Kernel: $(uname -r)"
}

# ==============================================================
# FUNGSI: CEK KONEKSI INTERNET
# ==============================================================
check_internet() {
    log_step "2. Cek Koneksi Internet"

    local targets=("google.com" "mirror.mariadb.org" "keyserver.ubuntu.com" "archive.ubuntu.com")
    local success=0

    for target in "${targets[@]}"; do
        if ping -c 2 -W 3 "${target}" &>/dev/null; then
            log_success "Koneksi ke ${target} OK"
            ((success++))
        else
            log_warn "Tidak dapat menjangkau ${target}"
        fi
    done

    if [ "${success}" -lt 2 ]; then
        log_warn "Koneksi internet terbatas. Beberapa package mungkin gagal di-download."
        read -r -p "Lanjutkan? (y/N): " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# ==============================================================
# FUNGSI: UPDATE SISTEM
# ==============================================================
update_system() {
    log_step "3. Update Sistem Operasi"

    log_info "Memperbarui daftar package..."
    sudo apt-get update -qq

    log_info "Meng-upgrade package yang sudah ada..."
    sudo apt-get upgrade -y -qq

    log_success "Sistem berhasil di-update"
}

# ==============================================================
# FUNGSI: INSTALL DEPENDENCIES
# ==============================================================
install_dependencies() {
    log_step "4. Install Dependencies & Tools"

    local packages=()

    # Package umum untuk semua OS
    packages+=(
        python3
        python3-apt
        python3-pip
        python3-mysqldb
        software-properties-common
        curl
        wget
        gnupg
        openssh-client
        ufw
        net-tools
        lsof
    )

    # Package spesifik per OS
    case "${OS_ID}" in
        ubuntu)
            packages+=(python3-venv python3-dev)
            if [ "${OS_VERSION}" = "20.04" ] || [ "${OS_VERSION}" = "22.04" ]; then
                packages+=(python-mysqldb)
            fi
            ;;
        debian)
            packages+=(python3-dev)
            if [ "${OS_VERSION}" = "11" ]; then
                packages+=(python-mysqldb)
            fi
            ;;
    esac

    log_info "Menginstall package: ${packages[*]}"
    sudo apt-get install -y -qq "${packages[@]}"

    # Install Ansible via pip (versi terbaru)
    log_info "Menginstall Ansible via pip..."
    pip3 install --user --upgrade pip
    pip3 install --user ansible ansible-core 2>/dev/null || {
        log_warn "pip install gagal, mencoba via apt..."
        case "${OS_ID}" in
            ubuntu)
                sudo apt-get install -y -qq ansible
                ;;
            debian)
                if [ "${OS_VERSION}" = "11" ]; then
                    echo "deb http://deb.debian.org/debian ${OS_CODENAME}-backports main" | sudo tee /etc/apt/sources.list.d/backports.list
                    sudo apt-get update -qq
                    sudo apt-get install -y -qq -t "${OS_CODENAME}-backports" ansible
                else
                    sudo apt-get install -y -qq ansible
                fi
                ;;
        esac
    }

    # Pastikan ansible ada di PATH
    export PATH="${HOME}/.local/bin:${PATH}"

    if command -v ansible &>/dev/null; then
        log_success "Ansible $(ansible --version | head -1)"
    else
        log_error "Ansible gagal diinstall."
        exit 1
    fi

    # Install sshpass untuk SSH non-interaktif (opsional)
    if ! command -v sshpass &>/dev/null; then
        sudo apt-get install -y -qq sshpass 2>/dev/null || true
    fi
}

# ==============================================================
# FUNGSI: KONFIGURASI FIREWALL
# ==============================================================
configure_firewall() {
    log_step "5. Konfigurasi Firewall (UFW)"

    if ! command -v ufw &>/dev/null; then
        log_warn "UFW tidak terinstall. Melewati konfigurasi firewall."
        return
    fi

    # Cek apakah ini node database atau load balancer
    echo ""
    echo "Apakah server INI adalah node DATABASE cluster?"
    echo "  a) Ya - buka port database (3306, 4444, 4567, 4568)"
    echo "  b) Tidak - hanya buka port SSH"
    read -r -p "Pilihan (a/b) [b]: " is_db_node
    is_db_node="${is_db_node:-b}"

    # Port dasar
    local ports=(22)

    if [[ "${is_db_node}" == "a" ]]; then
        ports+=(3306 4444 4567 4568)
    fi

    log_info "Mengatur UFW rules..."

    # Set default
    sudo ufw --force reset &>/dev/null
    sudo ufw default deny incoming &>/dev/null
    sudo ufw default allow outgoing &>/dev/null

    for port in "${ports[@]}"; do
        case "${port}" in
            4567)
                sudo ufw allow "${port}/tcp" &>/dev/null
                sudo ufw allow "${port}/udp" &>/dev/null
                log_info "  Port ${port}/tcp+udp → OK"
                ;;
            22)
                sudo ufw allow "${port}/tcp" &>/dev/null
                log_info "  Port ${port}/tcp → OK"
                ;;
            *)
                sudo ufw allow "${port}/tcp" &>/dev/null
                log_info "  Port ${port}/tcp → OK"
                ;;
        esac
    done

    sudo ufw --force enable &>/dev/null
    log_success "Firewall dikonfigurasi dengan port: ${ports[*]}"
}

# ==============================================================
# FUNGSI: SETUP SSH KEY
# ==============================================================
setup_ssh_key() {
    log_step "6. Setup SSH Key"

    local ssh_key="${HOME}/.ssh/id_ed25519"

    # Generate SSH key jika belum ada
    if [ ! -f "${ssh_key}" ]; then
        log_info "Membuat SSH key ed25519 baru..."
        ssh-keygen -t ed25519 -f "${ssh_key}" -N "" -C "galera-cluster@$(hostname)"
        log_success "SSH key dibuat: ${ssh_key}.pub"
    else
        log_success "SSH key sudah ada: ${ssh_key}.pub"
    fi

    echo ""
    echo -e "${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}  PUBLIC KEY ANDA:${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    cat "${ssh_key}.pub"
    echo -e "${YELLOW}====================================================${NC}"
    echo ""
    echo "Anda perlu men-copy public key di atas ke SEMUA server tujuan."
    echo ""
}

# ==============================================================
# FUNGSI: COPY SSH KEY KE SERVER
# ==============================================================
copy_ssh_keys() {
    log_step "7. Copy SSH Key ke Semua Server"

    local servers=()
    local password=""

    echo "Masukkan IP address server-server tujuan (pisahkan dengan spasi)"
    echo "Contoh: 192.168.10.2 192.168.10.3 192.168.10.4 192.168.10.5"
    read -r -p "Server IPs: " -a servers

    if [ ${#servers[@]} -eq 0 ]; then
        log_warn "Tidak ada server dimasukkan. Lewati step ini."
        return
    fi

    read -r -p "Username SSH [ubuntu]: " ssh_user
    ssh_user="${ssh_user:-ubuntu}"

    read -r -s -p "Password SSH (opsional, kosongkan jika pakai key saja): " password
    echo ""

    for server in "${servers[@]}"; do
        log_info "Copy key ke ${ssh_user}@${server}..."
        if [ -n "${password}" ]; then
            if command -v sshpass &>/dev/null; then
                sshpass -p "${password}" ssh-copy-id -o StrictHostKeyChecking=accept-new -i "${HOME}/.ssh/id_ed25519.pub" "${ssh_user}@${server}" 2>/dev/null && {
                    log_success "Key ter-copy ke ${server} (via sshpass)"
                } || {
                    log_warn "Gagal copy key ke ${server}. Coba manual:"
                    echo "  ssh-copy-id ${ssh_user}@${server}"
                }
            else
                log_warn "sshpass tidak tersedia. Silakan copy manual:"
                echo "  ssh-copy-id ${ssh_user}@${server}"
            fi
        else
            ssh-copy-id -o StrictHostKeyChecking=accept-new -i "${HOME}/.ssh/id_ed25519.pub" "${ssh_user}@${server}" 2>/dev/null && {
                log_success "Key ter-copy ke ${server}"
            } || {
                log_warn "Gagal copy key ke ${server}. Silakan coba manual:"
                echo "  ssh-copy-id ${ssh_user}@${server}"
            }
        fi
    done
}

# ==============================================================
# FUNGSI: PILIH JENIS PLAYBOOK
# ==============================================================
select_playbook() {
    log_step "8. Pilih Jenis Cluster"

    echo "Pilih jenis database yang akan di-deploy:"
    echo "  a) MariaDB 10.11 Galera Cluster (RECOMMENDED - support sampai 2028)"
    echo "  b) MySQL 5.7 Galera Cluster (LEGACY - sudah EOL)"
    echo ""
    read -r -p "Pilihan (a/b) [a]:: " db_choice
    db_choice="${db_choice:-a}"

    case "${db_choice}" in
        a|A)
            CLUSTER_TYPE="mariadb"
            PLAYBOOK_DIR="${SCRIPT_DIR}/mariadb-galera-cluster"
            INVENTORY_FILE="${PLAYBOOK_DIR}/inventory.yml"
            DEPLOY_FILE="${PLAYBOOK_DIR}/deploy-mariadb-cluster.yml"
            CLUSTER_GROUP="mariadb_cluster"
            log_success "Dipilih: MariaDB 10.11 Galera Cluster"
            ;;
        b|B)
            CLUSTER_TYPE="mysql"
            PLAYBOOK_DIR="${SCRIPT_DIR}/mysql-5_7-galera-cluster"
            INVENTORY_FILE="${PLAYBOOK_DIR}/inventory.yml"
            DEPLOY_FILE="${PLAYBOOK_DIR}/deploy-mysql-cluster.yml"
            CLUSTER_GROUP="mysql_cluster"
            log_warn "Dipilih: MySQL 5.7 Galera Cluster (EOL - tidak disarankan)"
            ;;
        *)
            log_error "Pilihan tidak valid."
            exit 1
            ;;
    esac

    if [ ! -d "${PLAYBOOK_DIR}" ]; then
        log_error "Folder playbook tidak ditemukan: ${PLAYBOOK_DIR}"
        exit 1
    fi
}

# ==============================================================
# FUNGSI: KOLEKSI INFORMASI SERVER
# ==============================================================
collect_server_info() {
    CLUSTER_NODES=()
    LB_NODE=""

    log_step "9. Input Informasi Server Cluster"

    echo "Masukkan informasi server cluster MariaDB/MySQL."
    echo "Minimal 3 node database + 1 node load balancer."
    echo ""

    # --- Cluster Nodes ---
    local node_count=0
    while [ "${node_count}" -lt 3 ]; do
        echo ""
        echo "--- Node Database ke-$((node_count + 1)) ---"
        read -r -p "  IP Address        : " node_ip
        read -r -p "  SSH Port [22]     : " node_port
        node_port="${node_port:-22}"
        read -r -p "  SSH User [ubuntu] : " node_user
        node_user="${node_user:-ubuntu}"
        read -r -p "  Hostname label    : " node_label
        node_label="${node_label:-${CLUSTER_TYPE}_node_$((node_count + 1))}"

        CLUSTER_NODES+=("${node_label}|${node_ip}|${node_port}|${node_user}")
        ((node_count++)) || true

        if [ "${node_count}" -ge 3 ]; then
            read -r -p "Tambah node lagi? (y/N): " add_more
            if [[ "${add_more}" =~ ^[Yy]$ ]]; then
                continue
            fi
            break
        fi
    done

    # --- Load Balancer Node ---
    echo ""
    echo "--- Node Load Balancer (HAProxy) ---"
    read -r -p "  IP Address        : " lb_ip
    read -r -p "  SSH Port [22]     : " lb_port
    lb_port="${lb_port:-22}"
    read -r -p "  SSH User [ubuntu] : " lb_user
    lb_user="${lb_user:-ubuntu}"
    LB_NODE="haproxy_load_balancer|${lb_ip}|${lb_port}|${lb_user}"

    # --- Kredensial ---
    echo ""
    echo "--- Kredensial Database ---"
    read -r -p "  Nama Cluster [galera_cluster]: " CLUSTER_NAME
    CLUSTER_NAME="${CLUSTER_NAME:-galera_cluster}"
    read -r -s -p "  Root Password (biarkan kosong untuk generate otomatis): " MYSQL_ROOT_PASSWORD
    echo ""

    if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
        MYSQL_ROOT_PASSWORD="$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9!@#%^&*()_+-=' | head -c20)"
        log_info "Password auto-generate: ${MYSQL_ROOT_PASSWORD}"
        log_warn "CATAT password ini! Tidak akan ditampilkan lagi."
    fi

    # --- SSH User Default ---
    local first_node="${CLUSTER_NODES[0]}"
    SSH_USER="$(echo "${first_node}" | cut -d'|' -f4)"
}

# ==============================================================
# FUNGSI: TEST KONEKSI SSH
# ==============================================================
test_ssh_connections() {
    log_step "10. Test Koneksi SSH ke Semua Server"

    local all_ok=true

    # Test cluster nodes
    for node in "${CLUSTER_NODES[@]}"; do
        local ip="$(echo "${node}" | cut -d'|' -f2)"
        local port="$(echo "${node}" | cut -d'|' -f3)"
        local user="$(echo "${node}" | cut -d'|' -f4)"

        log_info "Test SSH ke ${user}@${ip}:${port}..."
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "${port}" "${user}@${ip}" "hostname" &>/dev/null; then
            log_success "  ${user}@${ip}:${port} → Terhubung"
        else
            log_error "  ${user}@${ip}:${port} → GAGAL terhubung!"
            all_ok=false
        fi
    done

    # Test load balancer node
    local lb_ip="$(echo "${LB_NODE}" | cut -d'|' -f2)"
    local lb_port="$(echo "${LB_NODE}" | cut -d'|' -f3)"
    local lb_user="$(echo "${LB_NODE}" | cut -d'|' -f4)"

    log_info "Test SSH ke ${lb_user}@${lb_ip}:${lb_port}..."
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "${lb_port}" "${lb_user}@${lb_ip}" "hostname" &>/dev/null; then
        log_success "  ${lb_user}@${lb_ip}:${lb_port} → Terhubung"
    else
        log_error "  ${lb_user}@${lb_ip}:${lb_port} → GAGAL terhubung!"
        all_ok=false
    fi

    if [ "${all_ok}" = false ]; then
        log_warn "Beberapa koneksi SSH gagal. Perbaiki sebelum melanjutkan."
        read -r -p "Tetap lanjutkan? (y/N): " force_continue
        if [[ ! "${force_continue}" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# ==============================================================
# FUNGSI: GENERATE INVENTORY YML
# ==============================================================
generate_inventory() {
    log_step "11. Generate File Inventory"

    log_info "Membuat inventory file: ${INVENTORY_FILE}"

    # Backup jika sudah ada
    if [ -f "${INVENTORY_FILE}" ]; then
        cp "${INVENTORY_FILE}" "${INVENTORY_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "Backup inventory lama dibuat"
    fi

    {
        echo "# Inventory generated by prepare-cluster.sh"
        echo "# $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "[${CLUSTER_GROUP}]"
        local idx=1
        for node in "${CLUSTER_NODES[@]}"; do
            local label="$(echo "${node}" | cut -d'|' -f1)"
            local ip="$(echo "${node}" | cut -d'|' -f2)"
            local port="$(echo "${node}" | cut -d'|' -f3)"
            local user="$(echo "${node}" | cut -d'|' -f4)"
            echo "${label} ansible_host=${ip} ansible_port=${port} ansible_user=${user}"
            ((idx++)) || true
        done
        echo ""
        echo "[load_balancer]"
        local lb_label="$(echo "${LB_NODE}" | cut -d'|' -f1)"
        local lb_ip="$(echo "${LB_NODE}" | cut -d'|' -f2)"
        local lb_port="$(echo "${LB_NODE}" | cut -d'|' -f3)"
        local lb_user="$(echo "${LB_NODE}" | cut -d'|' -f4)"
        echo "${lb_label} ansible_host=${lb_ip} ansible_port=${lb_port} ansible_user=${lb_user}"
    } > "${INVENTORY_FILE}"

    log_success "Inventory file berhasil dibuat!"
    echo ""
    echo -e "${YELLOW}Isi inventory:${NC}"
    cat "${INVENTORY_FILE}"
}

# ==============================================================
# FUNGSI: UPDATE VARIABEL PLAYBOOK
# ==============================================================
update_playbook_vars() {
    log_step "12. Update Variabel Playbook"

    if [ ! -f "${DEPLOY_FILE}" ]; then
        log_error "File playbook tidak ditemukan: ${DEPLOY_FILE}"
        return
    fi

    log_info "Mengupdate variabel di ${DEPLOY_FILE}..."

    # Backup
    cp "${DEPLOY_FILE}" "${DEPLOY_FILE}.bak.$(date +%Y%m%d%H%M%S)"

    # Update cluster name
    if [ "${CLUSTER_TYPE}" = "mariadb" ]; then
        sed -i "s/mariadb_cluster_name:.*/mariadb_cluster_name: ${CLUSTER_NAME}/" "${DEPLOY_FILE}"
        sed -i "s/mariadb_root_password:.*/mariadb_root_password: \"${MYSQL_ROOT_PASSWORD}\"/" "${DEPLOY_FILE}"
    else
        sed -i "s/mysql_cluster_name:.*/mysql_cluster_name: ${CLUSTER_NAME}/" "${DEPLOY_FILE}"
        sed -i "s/mysql_root_password:.*/mysql_root_password: \"${MYSQL_ROOT_PASSWORD}\"/" "${DEPLOY_FILE}"
    fi

    log_success "Variabel playbook berhasil diupdate"
}

# ==============================================================
# FUNGSI: RUN ANSIBLE PLAYBOOK
# ==============================================================
run_ansible() {
    log_step "13. Deploy Cluster dengan Ansible"

    # Cek ansible
    if ! command -v ansible &>/dev/null; then
        export PATH="${HOME}/.local/bin:${PATH}"
        if ! command -v ansible &>/dev/null; then
            log_error "Ansible tidak ditemukan. Install terlebih dahulu."
            return
        fi
    fi

    echo ""
    echo "Pilih aksi:"
    echo "  a) Deploy cluster BARU (full)"
    echo "  b) START cluster saja (bootstrap)"
    echo "  c) STOP cluster saja"
    echo "  d) Test koneksi Ansible saja (ping)"
    echo "  e) BATAL / jangan jalankan sekarang"
    echo ""
    read -r -p "Pilihan (a/b/c/d/e) [a]: " action
    action="${action:-a}"

    # Masuk ke folder playbook
    cd "${PLAYBOOK_DIR}"

    case "${action}" in
        a|A)
            log_info "Menjalankan deploy full cluster..."
            echo ""
            log_warn "Proses ini akan menginstall ulang cluster. Data LAMA akan TERHAPUS."
            read -r -p "Yakin ingin melanjutkan? (y/N): " confirm
            if [[ "${confirm}" =~ ^[Yy]$ ]]; then
                ansible-playbook --fork=1 "${DEPLOY_FILE}" -i "${INVENTORY_FILE}"
            else
                log_info "Dibatalkan."
            fi
            ;;
        b|B)
            log_info "Start/bootstrap cluster..."
            ansible-playbook --fork=1 "${DEPLOY_FILE}" -i "${INVENTORY_FILE}" --tags "start_cluster"
            ;;
        c|C)
            log_info "Stop cluster..."
            ansible-playbook --fork=1 "${DEPLOY_FILE}" -i "${INVENTORY_FILE}" --tags "stop_cluster"
            ;;
        d|D)
            log_info "Test ping semua host..."
            ansible all -i "${INVENTORY_FILE}" -m ping
            ;;
        e|E)
            log_info "Skip eksekusi. Inventory sudah siap di ${INVENTORY_FILE}"
            echo "Jalankan manual nanti:"
            echo "  cd ${PLAYBOOK_DIR}"
            echo "  ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE}"
            ;;
        *)
            log_error "Pilihan tidak valid."
            ;;
    esac

    cd "${SCRIPT_DIR}"
}

# ==============================================================
# FUNGSI: SAVE KREDENSIAL
# ==============================================================
save_credentials() {
    local cred_file="${SCRIPT_DIR}/.credentials-${CLUSTER_TYPE}-$(date +%Y%m%d%H%M%S).txt"

    {
        echo "========================================="
        echo " MariaDB/MySQL Galera Cluster Credentials"
        echo " Generated: $(date)"
        echo "========================================="
        echo ""
        echo " Cluster Type : ${CLUSTER_TYPE}"
        echo " Cluster Name : ${CLUSTER_NAME}"
        echo " Root Password: ${MYSQL_ROOT_PASSWORD}"
        echo ""
        echo " Node Database:"
        for node in "${CLUSTER_NODES[@]}"; do
            local label="$(echo "${node}" | cut -d'|' -f1)"
            local ip="$(echo "${node}" | cut -d'|' -f2)"
            echo "   - ${label} (${ip})"
        done
        echo ""
        echo " Load Balancer HAProxy:"
        local lb_ip="$(echo "${LB_NODE}" | cut -d'|' -f2)"
        echo "   IP: ${lb_ip}:3306"
        echo ""
        echo "========================================="
        echo " IMPORTANT: Delete this file after use!"
        echo "========================================="
    } > "${cred_file}"

    chmod 600 "${cred_file}"
    log_warn "Kredensial disimpan di: ${cred_file}"
    log_warn "HAPUS file ini setelah selesai!"
}

# ==============================================================
# MAIN FUNCTION
# ==============================================================
main() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       MariaDB/MySQL Galera Cluster Setup Script        ║${NC}"
    echo -e "${CYAN}║            Ansible + HAProxy Automated                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # ============================================
    # EKSEKUSI DI SERVER LOKAL (Mesin Kontrol)
    # ============================================
    detect_os
    check_internet
    update_system
    install_dependencies
    configure_firewall
    setup_ssh_key

    # ============================================
    # COPY SSH KEY (Opsional, Interaktif)
    # ============================================
    echo ""
    echo -e "${YELLOW}Apakah Anda ingin men-copy SSH key ke server lain sekarang?${NC}"
    echo "Jika server tujuan sudah siap, jawab 'y'."
    read -r -p "Copy SSH key? (y/N): " do_copy_ssh
    if [[ "${do_copy_ssh}" =~ ^[Yy]$ ]]; then
        copy_ssh_keys
    fi

    # ============================================
    # KONFIGURASI PLAYBOOK
    # ============================================
    select_playbook
    collect_server_info

    # ============================================
    # TEST & GENERATE INVENTORY
    # ============================================
    test_ssh_connections
    generate_inventory
    update_playbook_vars

    # ============================================
    # SIMPAN KREDENSIAL
    # ============================================
    save_credentials

    # ============================================
    # JALANKAN ANSIBLE
    # ============================================
    echo ""
    echo -e "${YELLOW}Apakah Anda ingin menjalankan Ansible playbook sekarang?${NC}"
    read -r -p "Jalankan Ansible? (y/N): " do_run_ansible
    if [[ "${do_run_ansible}" =~ ^[Yy]$ ]]; then
        run_ansible
    else
        log_info "Ansible tidak dijalankan. Anda bisa running manual nanti."
        echo ""
        echo "Cara manual:"
        echo "  cd ${PLAYBOOK_DIR}"
        echo "  ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE}"
    fi

    # ============================================
    # SELESAI
    # ============================================
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                   SETUP COMPLETE!                       ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Cluster Type : ${CYAN}${CLUSTER_TYPE}${NC}"
    echo -e "  Inventory    : ${CYAN}${INVENTORY_FILE}${NC}"
    echo -e "  Playbook     : ${CYAN}${DEPLOY_FILE}${NC}"
    echo -e "  Credentials  : ${YELLOW}cek file .credentials-*.txt${NC}"
    echo ""
    echo "  Untuk deploy manual:"
    echo "    cd ${PLAYBOOK_DIR}"
    echo "    ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE}"
    echo ""
    echo "  Untuk stop cluster:"
    echo "    ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE} --tags stop_cluster"
    echo ""
    echo "  Untuk start cluster:"
    echo "    ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE} --tags start_cluster"
    echo ""
}

# ==============================================================
# JALANKAN MAIN
# ==============================================================
main "$@"
