# Galera TUI — MariaDB Galera Cluster Controller

Terminal UI (Rust) untuk mengontrol cluster dari **Windows, Linux, dan macOS**.

## Fitur

- **Dashboard** — status SSH, MariaDB, Galera (`wsrep_cluster_size`) per node
- **Start / Stop** cluster (Ansible tags)
- **Deploy** & **Reset + Deploy** penuh
- **Apply Config** — deploy template + rolling restart
- **Check Network** — ping semua host
- **Setup** — cek prasyarat (ansible, collection, file config)
- **Edit** — `inventory.yml`, `group_vars/all/mariadb.yml`
- **Tambah Node** — form tambah node DB ke inventory
- **Output panel** — scroll log perintah Ansible

## Prasyarat

- [Rust](https://rustup.rs/) 1.70+
- [Ansible](https://docs.ansible.com/) terinstall & ada di `PATH`
- SSH key / sudo sudah dikonfigurasi (lihat `../OPERASI.md`)

```bash
ansible-galaxy collection install -r ../requirements.yml
```

## Build

```bash
cd tui
cargo build --release
```

Binary: `target/release/galera-tui` (Linux/macOS) atau `galera-tui.exe` (Windows)

## Jalankan

Dari folder `mariadb-galera-cluster-fix` atau `galera-cluster-dist`:

```bash
./start.sh
# atau
./tui/target/release/galera-tui
```

**Saat pertama dibuka**, TUI menampilkan **Panduan Setup Penerima Paket** dengan checklist
langkah (Ansible, secrets, inventory, dll.). Tekan `Enter` untuk menu utama.

Menu **Dokumentasi (.md)** — baca file di folder `docs/` (MULAI-DISINI, OPERASI, dll.).

Atau set path cluster manual:

```bash
GALERA_CLUSTER_DIR=/path/to/mariadb-galera-cluster-fix galera-tui
```

## Kontrol Keyboard

| Tombol | Aksi |
|--------|------|
| `↑` / `↓` | Navigasi menu |
| `Enter` | Pilih / konfirmasi |
| `Esc` | Kembali / batal |
| `r` | Refresh status (dashboard) |
| `PgUp` / `PgDn` | Scroll output |
| `Ctrl+S` | Simpan editor |
| `q` | Keluar (menu utama) |

## Cross-Platform

TUI memanggil `ansible` / `ansible-playbook` langsung (bukan script `.sh`),
sehingga berjalan di Windows tanpa WSL selama Ansible terinstall.

Di Windows, install Ansible via:

```powershell
pip install ansible
# atau
choco install ansible
```
