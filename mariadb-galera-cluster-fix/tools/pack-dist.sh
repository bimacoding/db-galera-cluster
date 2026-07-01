#!/usr/bin/env bash
# ==============================================================
# pack-dist.sh — Buat folder galera-cluster-dist siap distribusi
# Output: ../galera-cluster-dist/ (folder BARU, terpisah dari -fix)
# ==============================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/.."
DIST="${SRC}/../galera-cluster-dist"
TUI_SRC="${SRC}/tui"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
log() { echo -e "${BLUE}[pack]${NC} $*"; }
ok()  { echo -e "${GREEN}[ok]${NC}  $*"; }
err() { echo -e "${RED}[err]${NC} $*" >&2; }

# --- Deteksi platform build ---
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${OS}-${ARCH}" in
    darwin-arm64|darwin-aarch64) PLATFORM="darwin-aarch64" ;;
    darwin-x86_64)               PLATFORM="darwin-x86_64" ;;
    linux-x86_64|linux-amd64)    PLATFORM="linux-x86_64" ;;
    linux-aarch64|linux-arm64)   PLATFORM="linux-aarch64" ;;
    mingw*|msys*|cygwin*)        PLATFORM="windows-x86_64" ;;
    *) err "Platform tidak dikenali: ${OS}-${ARCH}"; exit 1 ;;
esac

log "Source: ${SRC}"
log "Output: ${DIST}"
log "Platform binary: ${PLATFORM}"

# --- Build TUI ---
log "Building galera-tui (release)..."
(cd "${TUI_SRC}" && cargo build --release) || { err "cargo build gagal"; exit 1; }

TUI_BIN="${TUI_SRC}/target/release/galera-tui"
if [[ "${PLATFORM}" == windows-x86_64 ]]; then
    TUI_BIN="${TUI_SRC}/target/release/galera-tui.exe"
fi
[[ -f "${TUI_BIN}" ]] || { err "Binary tidak ditemukan: ${TUI_BIN}"; exit 1; }

# --- Recreate dist folder ---
log "Menyiapkan folder distribusi..."
rm -rf "${DIST}"
mkdir -p "${DIST}/bin/${PLATFORM}"
mkdir -p "${DIST}/group_vars/all"
mkdir -p "${DIST}/docs"

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

# --- Copy Ansible & scripts (tanpa .md di root — ada di docs/) ---
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

# Inventory template (placeholder IP — edit via configure-inventory.sh)
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

# --- Copy binary ---
cp "${TUI_BIN}" "${DIST}/bin/${PLATFORM}/"
chmod +x "${DIST}/bin/${PLATFORM}/"* 2>/dev/null || true

# --- Launcher scripts ---
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

# --- README distribusi ---
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
echo "" >> "${DIST}/README.md"
echo "Binary yang tersedia saat pack: **${PLATFORM}**" >> "${DIST}/README.md"

# --- .gitignore untuk dist ---
cat > "${DIST}/.gitignore" <<'GI'
group_vars/all/secrets.yml
group_vars_haproxy.yml
.pass
.credentials-*.txt
GI

# --- VERSION stamp ---
git -C "${SRC}/.." rev-parse --short HEAD 2>/dev/null > "${DIST}/VERSION" || echo "local" > "${DIST}/VERSION"
echo "${PLATFORM}" >> "${DIST}/VERSION"
date -u +"%Y-%m-%dT%H:%M:%SZ" >> "${DIST}/VERSION"

ok "Selesai: ${DIST}"
ok "Binary: bin/${PLATFORM}/galera-tui"
ok "Jalankan: cd ${DIST} && ./start.sh"
echo ""
echo "  Langkah berikutnya:"
echo "    1. cd galera-cluster-dist"
echo "    2. ./configure-inventory.sh"
echo "    3. cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml"
echo "    4. cp group_vars_haproxy.yml.example group_vars_haproxy.yml"
echo "    5. ./start.sh"
