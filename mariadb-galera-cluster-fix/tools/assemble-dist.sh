#!/usr/bin/env bash
# ==============================================================
# assemble-dist.sh — Rakit folder galera-cluster-dist (tanpa build)
# Env:
#   SRC      — folder mariadb-galera-cluster-fix (default: parent tools/)
#   DIST     — output galera-cluster-dist (default: ../galera-cluster-dist)
#   BIN_ROOT — folder berisi subfolder per platform, mis.:
#              $BIN_ROOT/darwin-aarch64/galera-tui
#              $BIN_ROOT/windows-x86_64/galera-tui.exe
# ==============================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-${SCRIPT_DIR}/..}"
DIST="${DIST:-${SRC}/../galera-cluster-dist}"
BIN_ROOT="${BIN_ROOT:?BIN_ROOT wajib di-set (folder bin/<platform>/)}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
log() { echo -e "${BLUE}[assemble]${NC} $*"; }
ok()  { echo -e "${GREEN}[ok]${NC}  $*"; }
err() { echo -e "${RED}[err]${NC} $*" >&2; }

if [[ ! -d "${BIN_ROOT}" ]]; then
    err "BIN_ROOT tidak ditemukan: ${BIN_ROOT}"
    exit 1
fi

# Portable loop (macOS bash 3.2 tidak punya mapfile)
PLATFORMS=()
while IFS= read -r plat; do
    PLATFORMS+=("$plat")
done < <(find "${BIN_ROOT}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
if [[ ${#PLATFORMS[@]} -eq 0 ]]; then
    err "Tidak ada subfolder platform di ${BIN_ROOT}"
    exit 1
fi

log "Source: ${SRC}"
log "Output: ${DIST}"
log "Binaries: ${PLATFORMS[*]}"

# --- Recreate dist folder ---
log "Menyiapkan folder distribusi..."
rm -rf "${DIST}"
mkdir -p "${DIST}/group_vars/all"
mkdir -p "${DIST}/docs"

# --- Copy binaries ---
for plat in "${PLATFORMS[@]}"; do
    src_dir="${BIN_ROOT}/${plat}"
    dst_dir="${DIST}/bin/${plat}"
    mkdir -p "${dst_dir}"
    if [[ -f "${src_dir}/galera-tui.exe" ]]; then
        cp "${src_dir}/galera-tui.exe" "${dst_dir}/"
    elif [[ -f "${src_dir}/galera-tui" ]]; then
        cp "${src_dir}/galera-tui" "${dst_dir}/"
        chmod +x "${dst_dir}/galera-tui"
    else
        err "Binary tidak ditemukan di ${src_dir}/ (harus galera-tui atau galera-tui.exe)"
        exit 1
    fi
done

# --- Copy dokumentasi ke docs/ ---
DOC_FILES=(
    MULAI-DISINI.md
    README.md
    OPERASI.md
    ARSITEKTUR.md
    CHANGELOG.md
)
for f in "${DOC_FILES[@]}"; do
    if [[ -f "${SRC}/docs/${f}" ]]; then
        cp "${SRC}/docs/${f}" "${DIST}/docs/"
    elif [[ -f "${SRC}/${f}" ]]; then
        cp "${SRC}/${f}" "${DIST}/docs/"
    fi
done

# --- Copy Ansible & scripts ---
ANSIBLE_FILES=(
    deploy-mariadb-cluster.yml
    apply-config.yml
    apply-config.sh
    ansible.cfg
    mariadb-cluster-config.j2
    haproxy-config.j2
    requirements.yml
    configure-inventory.sh
    run-deploy.sh
    run-full-deploy.sh
    reset-galera-cluster.sh
    check-cluster-network.sh
    fix-sudo-on-server.sh
    setup-ssh.sh
)

for f in "${ANSIBLE_FILES[@]}"; do
    cp "${SRC}/${f}" "${DIST}/${f}"
    chmod +x "${DIST}/${f}" 2>/dev/null || true
done

cp "${SRC}/group_vars/all/ansible.yml" "${DIST}/group_vars/all/"
cp "${SRC}/group_vars/all/mariadb.yml" "${DIST}/group_vars/all/"
cp "${SRC}/group_vars/all/secrets.yml.example" "${DIST}/group_vars/all/"

cat > "${DIST}/inventory.yml" <<'YAML'
# inventory.yml — edit IP via ./configure-inventory.sh atau manual
all:
  children:
    mariadb_cluster:
      hosts:
        mariadb_node_1:
          ansible_host: 10.0.0.50
          ansible_port: 22
          ansible_user: ubuntu
          interface_ip: 10.0.0.50
        mariadb_node_2:
          ansible_host: 10.0.0.51
          ansible_port: 22
          ansible_user: ubuntu
          interface_ip: 10.0.0.51
        mariadb_node_3:
          ansible_host: 10.0.0.52
          ansible_port: 22
          ansible_user: ubuntu
          interface_ip: 10.0.0.52
    load_balancer:
      hosts:
        haproxy_load_balancer:
          ansible_host: 10.0.0.53
          ansible_port: 22
          ansible_user: ubuntu
          interface_ip: 10.0.0.53
YAML

cat > "${DIST}/group_vars_haproxy.yml.example" <<'YAML'
---
haproxy_stats_user: admin
haproxy_stats_password: "GANTI_PASSWORD_STATS_HAPROXY"
YAML

cat > "${DIST}/start.sh" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GALERA_CLUSTER_DIR="${ROOT}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${OS}-${ARCH}" in
    darwin-arm64|darwin-aarch64) PLAT="darwin-aarch64" ;;
    darwin-x86_64)               PLAT="darwin-x86_64" ;;
    linux-x86_64|linux-amd64)    PLAT="linux-x86_64" ;;
    linux-aarch64|linux-arm64)   PLAT="linux-aarch64" ;;
    *) echo "[ERROR] Platform ${OS}-${ARCH} — binary belum tersedia di bin/"; exit 1 ;;
esac

BIN="${ROOT}/bin/${PLAT}/galera-tui"
[[ -x "${BIN}" ]] || { echo "[ERROR] Binary tidak ada: ${BIN}"; echo "        Build di platform ini atau minta release binary ${PLAT}"; exit 1; }
exec "${BIN}"
LAUNCH
chmod +x "${DIST}/start.sh"

cat > "${DIST}/start.bat" <<'BAT'
@echo off
setlocal
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "GALERA_CLUSTER_DIR=%ROOT%"
set "BIN=%ROOT%\bin\windows-x86_64\galera-tui.exe"
if not exist "%BIN%" (
    echo [ERROR] Binary tidak ada: %BIN%
    echo Build di Windows: cd tui ^&^& cargo build --release
    exit /b 1
)
"%BIN%"
BAT

cat > "${DIST}/README.md" <<'README'
# Galera Cluster — Paket Distribusi Siap Pakai

Folder ini **terpisah** dari development (`mariadb-galera-cluster-fix`).
Berisi Ansible playbook + binary **galera-tui** untuk mengontrol cluster.

## Isi Paket

- **Ansible** — deploy MariaDB Galera + HAProxy
- **galera-tui** — TUI Rust (binary di `bin/<platform>/`)
- **start.sh** / **start.bat** — launcher otomatis

## Setup Awal (sekali)

### 1. Prasyarat

```bash
# macOS
brew install ansible

# Linux
sudo apt install ansible   # atau: pip install ansible

# Windows (PowerShell admin)
pip install ansible
```

```bash
ansible-galaxy collection install -r requirements.yml
```

### 2. Konfigurasi

Lihat checklist di TUI (`./start.sh`) atau baca `docs/MULAI-DISINI.md`:

```bash
./configure-inventory.sh          # atur IP & user SSH
cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml
cp group_vars_haproxy.yml.example group_vars_haproxy.yml
# edit kedua file password di atas
```

### 3. Jalankan TUI

```bash
./start.sh
```

TUI menampilkan **panduan setup** otomatis saat pertama dibuka.
Menu **Dokumentasi** membaca semua file `.md` di folder `docs/`.

Windows: double-click `start.bat` atau dari cmd:

```cmd
start.bat
```

## Binary per Platform

| Folder | Platform |
|--------|----------|
| `bin/darwin-aarch64/` | macOS Apple Silicon |
| `bin/darwin-x86_64/` | macOS Intel |
| `bin/linux-x86_64/` | Linux amd64 |
| `bin/linux-aarch64/` | Linux ARM64 |
| `bin/windows-x86_64/` | Windows amd64 |

Untuk platform lain, build dari source `mariadb-galera-cluster-fix/tui` lalu salin ke `bin/<platform>/`.

## Deploy tanpa TUI

```bash
./run-deploy.sh
./run-full-deploy.sh    # reset + deploy
./apply-config.sh       # apply config permanen
```

## Dokumentasi

Semua ada di folder **`docs/`**:

- `docs/MULAI-DISINI.md` — panduan penerima paket
- `docs/OPERASI.md` — troubleshooting
- `docs/ARSITEKTUR.md` — diagram cluster

## Keamanan

Jangan distribusikan `group_vars/all/secrets.yml` atau password asli.
README

platform_list="$(printf '%s, ' "${PLATFORMS[@]}")"
platform_list="${platform_list%, }"
echo "" >> "${DIST}/README.md"
echo "Binary yang tersedia: **${platform_list}**" >> "${DIST}/README.md"

cat > "${DIST}/.gitignore" <<'GI'
group_vars/all/secrets.yml
group_vars_haproxy.yml
.pass
.credentials-*.txt
GI

{
    git -C "${SRC}/.." rev-parse --short HEAD 2>/dev/null || echo "local"
    for plat in "${PLATFORMS[@]}"; do
        echo "${plat}"
    done
    date -u +"%Y-%m-%dT%H:%M:%SZ"
} > "${DIST}/VERSION"

ok "Selesai: ${DIST}"
for plat in "${PLATFORMS[@]}"; do
    ok "Binary: bin/${plat}/"
done
