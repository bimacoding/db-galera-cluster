#!/usr/bin/env bash
# ==============================================================
# PREPARE & DEPLOY SCRIPT (VERSI DIPERBAIKI)
# MariaDB/MySQL Galera Cluster + HAProxy
# ==============================================================
# Mendukung:
#   - Ubuntu 20.04, 22.04, 24.04
#   - Debian 11, 12, 13
# ==============================================================
# PERBAIKAN dari versi asli:
#   - sed diganti pakai python3 untuk replace password agar AMAN
#     terhadap karakter spesial (&, /, \, |) yang sebelumnya bisa
#     merusak file YAML / membuat sed error.
#   - Validasi format IP address sebelum dipakai (cegah typo lolos).
#   - Firewall WAJIB membuka port Galera (4444,4567,4568) di node DB,
#     bukan opsional -- tanpa ini cluster pasti gagal sync.
#   - Tambah variabel mariadb_sst_password yang disinkronkan ke
#     playbook (dipakai wsrep_sst_auth).
#   - Pengecekan exit code lebih konsisten, set -E + trap error.
#   - Validasi paket per distro diperluas untuk Debian 12/13.
# ==============================================================
# Cara pakai:
#   chmod +x prepare-cluster.sh
#   ./prepare-cluster.sh
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
MYSQL_SST_PASSWORD=""
HAPROXY_STATS_PASSWORD=""
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

trap 'log_error "Script berhenti tidak terduga di baris $LINENO."' ERR

# ==============================================================
# FUNGSI: VALIDASI IP ADDRESS
# ==============================================================
is_valid_ip() {
    local ip="$1"
    local stat=1

    if [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}"
        if [[ "${o1}" -le 255 && "${o2}" -le 255 && "${o3}" -le 255 && "${o4}" -le 255 ]]; then
            stat=0
        fi
    fi
    return "${stat}"
}

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
                    log_success "Terdeteksi: Debian 12 (Bookworm)"
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
            log_error "Hanya Ubuntu 20.04/22.04/24.04 dan Debian 11/12/13 yang didukung."
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

    local targets=("1.1.1.1" "mirror.mariadb.org" "archive.ubuntu.com")
    local success=0

    for target in "${targets[@]}"; do
        if ping -c 2 -W 3 "${target}" &>/dev/null; then
            log_success "Koneksi ke ${target} OK"
            ((success++))
        else
            log_warn "Tidak dapat menjangkau ${target}"
        fi
    done

    if [ "${success}" -lt 1 ]; then
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
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

    log_success "Sistem berhasil di-update"
}

# ==============================================================
# FUNGSI: INSTALL DEPENDENCIES
# ==============================================================
install_dependencies() {
    log_step "4. Install Dependencies & Tools"

    local packages=()

    packages+=(
        python3
        python3-apt
        python3-pip
        python3-pymysql
        software-properties-common
        curl
        wget
        gnupg
        openssh-client
        ufw
        net-tools
        lsof
    )

    case "${OS_ID}" in
        ubuntu)
            packages+=(python3-venv python3-dev)
            ;;
        debian)
            packages+=(python3-dev)
            ;;
    esac

    log_info "Menginstall package: ${packages[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"

    log_info "Menginstall Ansible via pip..."
    pip3 install --user --upgrade pip --quiet
    if pip3 install --user "ansible-core>=2.15" --quiet 2>/dev/null; then
        :
    else
        log_warn "pip install gagal, mencoba via apt..."
        case "${OS_ID}" in
            ubuntu)
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible
                ;;
            debian)
                if [ "${OS_VERSION}" = "11" ]; then
                    echo "deb http://deb.debian.org/debian ${OS_CODENAME}-backports main" | sudo tee /etc/apt/sources.list.d/backports.list
                    sudo apt-get update -qq
                    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -t "${OS_CODENAME}-backports" ansible
                else
                    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible
                fi
                ;;
        esac
    fi

    export PATH="${HOME}/.local/bin:${PATH}"

    if command -v ansible &>/dev/null; then
        log_success "Ansible $(ansible --version | head -1)"
    else
        log_error "Ansible gagal diinstall."
        exit 1
    fi

    if ! command -v sshpass &>/dev/null; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass 2>/dev/null || true
    fi

    # Install collection community.mysql -- WAJIB, tanpa ini modul
    # mysql_user/mysql_db di playbook akan gagal "module not found".
    log_info "Menginstall Ansible collection community.mysql & community.general..."
    if [ -f "${SCRIPT_DIR}/mariadb-galera-cluster/requirements.yml" ]; then
        ansible-galaxy collection install -r "${SCRIPT_DIR}/mariadb-galera-cluster/requirements.yml" --force-with-deps || \
            log_warn "Gagal install collection otomatis. Jalankan manual: ansible-galaxy collection install community.mysql community.general"
    else
        ansible-galaxy collection install community.mysql community.general || \
            log_warn "Gagal install collection otomatis. Jalankan manual: ansible-galaxy collection install community.mysql community.general"
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

    echo ""
    echo "Apakah server INI adalah node DATABASE cluster?"
    echo "  a) Ya - buka port database & Galera (3306, 4444, 4567, 4568)"
    echo "  b) Tidak - hanya buka port SSH (mis. load balancer)"
    read -r -p "Pilihan (a/b) [b]: " is_db_node
    is_db_node="${is_db_node:-b}"

    local ports=(22)

    if [[ "${is_db_node}" == "a" ]]; then
        # PERBAIKAN: port Galera (4444 SST, 4567 gcomm, 4568 IST) kini
        # SELALU dibuka untuk node database, bukan opsional. Tanpa
        # port ini cluster Galera tidak bisa sync sama sekali.
        ports+=(3306 4444 4567 4568)
        log_info "Port database + Galera akan dibuka: 3306, 4444, 4567, 4568"
    else
        ports+=(8404)
        log_info "Port HAProxy stats (8404) juga akan dibuka untuk node load balancer."
    fi

    log_info "Mengatur UFW rules..."

    sudo ufw --force reset &>/dev/null
    sudo ufw default deny incoming &>/dev/null
    sudo ufw default allow outgoing &>/dev/null

    for port in "${ports[@]}"; do
        case "${port}" in
            4567)
                sudo ufw allow "${port}/tcp" &>/dev/null
                sudo ufw allow "${port}/udp" &>/dev/null
                log_info "  Port ${port}/tcp+udp -> OK"
                ;;
            *)
                sudo ufw allow "${port}/tcp" &>/dev/null
                log_info "  Port ${port}/tcp -> OK"
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

    for server in "${servers[@]}"; do
        if ! is_valid_ip "${server}"; then
            log_error "IP tidak valid: ${server} -- dilewati."
        fi
    done

    read -r -p "Username SSH [ubuntu]: " ssh_user
    ssh_user="${ssh_user:-ubuntu}"

    read -r -s -p "Password SSH (opsional, kosongkan jika pakai key saja): " password
    echo ""

    for server in "${servers[@]}"; do
        is_valid_ip "${server}" || continue
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
    unset password
}

# ==============================================================
# FUNGSI: PILIH JENIS PLAYBOOK
# ==============================================================
select_playbook() {
    log_step "8. Pilih Jenis Cluster"

    echo "Pilih jenis database yang akan di-deploy:"
    echo "  a) MariaDB 10.11 Galera Cluster (RECOMMENDED - support sampai 2028)"
    echo ""
    read -r -p "Pilihan (a) [a]: " db_choice
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
# FUNGSI: INPUT IP DENGAN VALIDASI
# ==============================================================
prompt_ip() {
    local prompt_text="$1"
    local ip=""
    while true; do
        read -r -p "${prompt_text}" ip
        if is_valid_ip "${ip}"; then
            echo "${ip}"
            return 0
        fi
        log_error "  Format IP tidak valid: '${ip}'. Coba lagi (contoh: 192.168.10.2)."
    done
}

# ==============================================================
# FUNGSI: KOLEKSI INFORMASI SERVER
# ==============================================================
collect_server_info() {
    CLUSTER_NODES=()
    LB_NODE=""

    log_step "9. Input Informasi Server Cluster"

    echo "Masukkan informasi server cluster MariaDB."
    echo "Minimal 3 node database + 1 node load balancer."
    echo ""

    local node_count=0
    while [ "${node_count}" -lt 3 ]; do
        echo ""
        echo "--- Node Database ke-$((node_count + 1)) ---"
        node_ip="$(prompt_ip '  IP Address        : ')"
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

    echo ""
    echo "--- Node Load Balancer (HAProxy) ---"
    lb_ip="$(prompt_ip '  IP Address        : ')"
    read -r -p "  SSH Port [22]     : " lb_port
    lb_port="${lb_port:-22}"
    read -r -p "  SSH User [ubuntu] : " lb_user
    lb_user="${lb_user:-ubuntu}"
    LB_NODE="haproxy_load_balancer|${lb_ip}|${lb_port}|${lb_user}"

    echo ""
    echo "--- Kredensial Database ---"
    read -r -p "  Nama Cluster [galera_cluster]: " CLUSTER_NAME
    CLUSTER_NAME="${CLUSTER_NAME:-galera_cluster}"

    read -r -s -p "  Root Password (kosongkan untuk generate otomatis): " MYSQL_ROOT_PASSWORD
    echo ""
    if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
        MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c20)"
        log_info "Root password auto-generate (alfanumerik agar aman untuk semua tool)."
    fi

    MYSQL_SST_PASSWORD="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c20)"
    log_info "SST (mariabackup) password auto-generate."

    HAPROXY_STATS_PASSWORD="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c16)"
    log_info "HAProxy stats password auto-generate."

    log_warn "CATAT semua password ini! Akan disimpan di file credentials, tapi sebaiknya dipindah ke vault."

    local first_node="${CLUSTER_NODES[0]}"
    SSH_USER="$(echo "${first_node}" | cut -d'|' -f4)"
}

# ==============================================================
# FUNGSI: TEST KONEKSI SSH
# ==============================================================
test_ssh_connections() {
    log_step "10. Test Koneksi SSH ke Semua Server"

    local all_ok=true

    for node in "${CLUSTER_NODES[@]}"; do
        local ip port user
        ip="$(echo "${node}" | cut -d'|' -f2)"
        port="$(echo "${node}" | cut -d'|' -f3)"
        user="$(echo "${node}" | cut -d'|' -f4)"

        log_info "Test SSH ke ${user}@${ip}:${port}..."
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "${port}" "${user}@${ip}" "hostname" &>/dev/null; then
            log_success "  ${user}@${ip}:${port} -> Terhubung"
        else
            log_error "  ${user}@${ip}:${port} -> GAGAL terhubung!"
            all_ok=false
        fi
    done

    local lb_ip lb_port lb_user
    lb_ip="$(echo "${LB_NODE}" | cut -d'|' -f2)"
    lb_port="$(echo "${LB_NODE}" | cut -d'|' -f3)"
    lb_user="$(echo "${LB_NODE}" | cut -d'|' -f4)"

    log_info "Test SSH ke ${lb_user}@${lb_ip}:${lb_port}..."
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "${lb_port}" "${lb_user}@${lb_ip}" "hostname" &>/dev/null; then
        log_success "  ${lb_user}@${lb_ip}:${lb_port} -> Terhubung"
    else
        log_error "  ${lb_user}@${lb_ip}:${lb_port} -> GAGAL terhubung!"
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

    if [ -f "${INVENTORY_FILE}" ]; then
        cp "${INVENTORY_FILE}" "${INVENTORY_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "Backup inventory lama dibuat"
    fi

    {
        echo "# Inventory generated by prepare-cluster.sh"
        echo "# $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# interface_ip ditambahkan eksplisit agar Galera/HAProxy tidak"
        echo "# salah pilih interface pada server multi-NIC."
        echo ""
        echo "[${CLUSTER_GROUP}]"
        for node in "${CLUSTER_NODES[@]}"; do
            local label ip port user
            label="$(echo "${node}" | cut -d'|' -f1)"
            ip="$(echo "${node}" | cut -d'|' -f2)"
            port="$(echo "${node}" | cut -d'|' -f3)"
            user="$(echo "${node}" | cut -d'|' -f4)"
            echo "${label} ansible_host=${ip} ansible_port=${port} ansible_user=${user} interface_ip=${ip}"
        done
        echo ""
        echo "[load_balancer]"
        local lb_label lb_ip lb_port lb_user
        lb_label="$(echo "${LB_NODE}" | cut -d'|' -f1)"
        lb_ip="$(echo "${LB_NODE}" | cut -d'|' -f2)"
        lb_port="$(echo "${LB_NODE}" | cut -d'|' -f3)"
        lb_user="$(echo "${LB_NODE}" | cut -d'|' -f4)"
        echo "${lb_label} ansible_host=${lb_ip} ansible_port=${lb_port} ansible_user=${lb_user} interface_ip=${lb_ip}"
    } > "${INVENTORY_FILE}"

    log_success "Inventory file berhasil dibuat!"
    echo ""
    echo -e "${YELLOW}Isi inventory:${NC}"
    cat "${INVENTORY_FILE}"
}

# ==============================================================
# FUNGSI: UPDATE VARIABEL PLAYBOOK (pakai python3, bukan sed)
# ==============================================================
update_playbook_vars() {
    log_step "12. Update Variabel Playbook"

    if [ ! -f "${DEPLOY_FILE}" ]; then
        log_error "File playbook tidak ditemukan: ${DEPLOY_FILE}"
        return
    fi

    log_info "Mengupdate variabel di ${DEPLOY_FILE}..."

    cp "${DEPLOY_FILE}" "${DEPLOY_FILE}.bak.$(date +%Y%m%d%H%M%S)"

    # PERBAIKAN KRITIS: sed dengan delimiter "/" akan RUSAK atau error
    # jika password hasil openssl mengandung karakter seperti "/",
    # "&", atau "\". Pakai python3 untuk replace yang aman terhadap
    # karakter apapun (replace literal, bukan regex).
    CLUSTER_NAME="${CLUSTER_NAME}" \
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    MYSQL_SST_PASSWORD="${MYSQL_SST_PASSWORD}" \
    DEPLOY_FILE="${DEPLOY_FILE}" \
    python3 - <<'PYEOF'
import os
import re

deploy_file = os.environ["DEPLOY_FILE"]
cluster_name = os.environ["CLUSTER_NAME"]
root_password = os.environ["MYSQL_ROOT_PASSWORD"]
sst_password = os.environ["MYSQL_SST_PASSWORD"]

with open(deploy_file, "r", encoding="utf-8") as f:
    content = f.read()

def yaml_single_quote(value: str) -> str:
    """
    Bungkus string sebagai YAML single-quoted scalar.
    Single-quote di YAML TIDAK memproses backslash sebagai escape sama
    sekali (berbeda dengan double-quote, yang membuat parser YAML error
    "found unknown escape character" jika password mengandung backslash
    diikuti huruf seperti \\S). Satu-satunya aturan single-quote adalah
    apostrof '' -> '. Ini membuat password dengan karakter apapun
    (backslash, dolar, hash, ampersand, garis miring) aman ditulis
    literal tanpa merusak parsing YAML maupun replacement regex.
    """
    return "'" + value.replace("'", "''") + "'"

# PENTING: replacement string pada re.sub() JUGA memproses backslash
# sebagai escape sequence Python (mis. "\S" akan error "bad escape").
# Karena password bisa berisi karakter apapun termasuk backslash,
# replacement HARUS lewat lambda agar diperlakukan sebagai string
# literal, bukan template regex.
content = re.sub(
    r"mariadb_cluster_name:.*",
    lambda _m: f"mariadb_cluster_name: {cluster_name}",
    content,
    count=1,
)
content = re.sub(
    r'mariadb_root_password:.*',
    lambda _m: f"mariadb_root_password: {yaml_single_quote(root_password)}",
    content,
    count=1,
)
content = re.sub(
    r'mariadb_sst_password:.*',
    lambda _m: f"mariadb_sst_password: {yaml_single_quote(sst_password)}",
    content,
    count=1,
)

with open(deploy_file, "w", encoding="utf-8") as f:
    f.write(content)

print("OK: playbook variables updated safely.")
PYEOF

    # Update juga stats password HAProxy lewat extra-vars file terpisah
    # daripada menyuntik ke template (lebih aman & tidak perlu sed juga).
    cat > "${PLAYBOOK_DIR}/group_vars_haproxy.yml" <<EOF
---
# Extra vars untuk HAProxy stats, dipisah dari deploy file utama.
# Pakai dengan: ansible-playbook ... -e @group_vars_haproxy.yml
haproxy_stats_user: admin
haproxy_stats_password: "${HAPROXY_STATS_PASSWORD}"
EOF
    chmod 600 "${PLAYBOOK_DIR}/group_vars_haproxy.yml"

    log_success "Variabel playbook berhasil diupdate (aman terhadap karakter spesial password)"
}

# ==============================================================
# FUNGSI: RUN ANSIBLE PLAYBOOK
# ==============================================================
run_ansible() {
    log_step "13. Deploy Cluster dengan Ansible"

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

    cd "${PLAYBOOK_DIR}"

    local extra_vars_file="group_vars_haproxy.yml"
    local extra_args=()
    if [ -f "${extra_vars_file}" ]; then
        extra_args+=(-e "@${extra_vars_file}")
    fi

    case "${action}" in
        a|A)
            log_info "Menjalankan deploy full cluster..."
            echo ""
            log_warn "Proses ini akan menginstall ulang cluster. Data LAMA akan TERHAPUS."
            read -r -p "Yakin ingin melanjutkan? (y/N): " confirm
            if [[ "${confirm}" =~ ^[Yy]$ ]]; then
                ansible-playbook --fork=1 "${DEPLOY_FILE}" -i "${INVENTORY_FILE}" "${extra_args[@]}"
            else
                log_info "Dibatalkan."
            fi
            ;;
        b|B)
            log_info "Start/bootstrap cluster..."
            ansible-playbook --fork=1 "${DEPLOY_FILE}" -i "${INVENTORY_FILE}" "${extra_args[@]}" --tags "start_cluster"
            ;;
        c|C)
            log_info "Stop cluster..."
            ansible-playbook --fork=1 "${DEPLOY_FILE}" -i "${INVENTORY_FILE}" "${extra_args[@]}" --tags "stop_cluster"
            ;;
        d|D)
            log_info "Test ping semua host..."
            ansible all -i "${INVENTORY_FILE}" -m ping
            ;;
        e|E)
            log_info "Skip eksekusi. Inventory sudah siap di ${INVENTORY_FILE}"
            echo "Jalankan manual nanti:"
            echo "  cd ${PLAYBOOK_DIR}"
            echo "  ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE} -e @${extra_vars_file}"
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
        echo " MariaDB Galera Cluster Credentials"
        echo " Generated: $(date)"
        echo "========================================="
        echo ""
        echo " Cluster Type        : ${CLUSTER_TYPE}"
        echo " Cluster Name        : ${CLUSTER_NAME}"
        echo " Root Password       : ${MYSQL_ROOT_PASSWORD}"
        echo " SST/mariabackup Pwd : ${MYSQL_SST_PASSWORD}"
        echo " HAProxy Stats Pwd   : ${HAPROXY_STATS_PASSWORD}"
        echo ""
        echo " Node Database:"
        for node in "${CLUSTER_NODES[@]}"; do
            local label ip
            label="$(echo "${node}" | cut -d'|' -f1)"
            ip="$(echo "${node}" | cut -d'|' -f2)"
            echo "   - ${label} (${ip})"
        done
        echo ""
        echo " Load Balancer HAProxy:"
        local lb_ip
        lb_ip="$(echo "${LB_NODE}" | cut -d'|' -f2)"
        echo "   IP: ${lb_ip}:3306"
        echo "   Stats: http://${lb_ip}:8404/"
        echo ""
        echo "========================================="
        echo " PENTING: Pindahkan password ini ke vault/secret"
        echo " manager, lalu HAPUS file ini setelah dicatat!"
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
    echo -e "${CYAN}+----------------------------------------------------------+${NC}"
    echo -e "${CYAN}|       MariaDB Galera Cluster Setup Script (Fixed)        |${NC}"
    echo -e "${CYAN}|            Ansible + HAProxy Automated                  |${NC}"
    echo -e "${CYAN}+----------------------------------------------------------+${NC}"
    echo ""

    detect_os
    check_internet
    update_system
    install_dependencies
    configure_firewall
    setup_ssh_key

    echo ""
    echo -e "${YELLOW}Apakah Anda ingin men-copy SSH key ke server lain sekarang?${NC}"
    read -r -p "Copy SSH key? (y/N): " do_copy_ssh
    if [[ "${do_copy_ssh}" =~ ^[Yy]$ ]]; then
        copy_ssh_keys
    fi

    select_playbook
    collect_server_info
    test_ssh_connections
    generate_inventory
    update_playbook_vars
    save_credentials

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
        echo "  ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE} -e @group_vars_haproxy.yml"
    fi

    echo ""
    echo -e "${GREEN}+----------------------------------------------------------+${NC}"
    echo -e "${GREEN}|                   SETUP COMPLETE!                        |${NC}"
    echo -e "${GREEN}+----------------------------------------------------------+${NC}"
    echo ""
    echo -e "  Cluster Type : ${CYAN}${CLUSTER_TYPE}${NC}"
    echo -e "  Inventory    : ${CYAN}${INVENTORY_FILE}${NC}"
    echo -e "  Playbook     : ${CYAN}${DEPLOY_FILE}${NC}"
    echo -e "  Credentials  : ${YELLOW}cek file .credentials-*.txt${NC}"
    echo ""
    echo "  Untuk deploy manual:"
    echo "    cd ${PLAYBOOK_DIR}"
    echo "    ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE} -e @group_vars_haproxy.yml"
    echo ""
    echo "  Untuk stop cluster:"
    echo "    ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE} -e @group_vars_haproxy.yml --tags stop_cluster"
    echo ""
    echo "  Untuk start cluster:"
    echo "    ansible-playbook --fork=1 ${DEPLOY_FILE} -i ${INVENTORY_FILE} -e @group_vars_haproxy.yml --tags start_cluster"
    echo ""
}

main "$@"
