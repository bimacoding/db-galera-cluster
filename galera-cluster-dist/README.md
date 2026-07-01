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

Binary yang tersedia saat pack: **darwin-aarch64**
