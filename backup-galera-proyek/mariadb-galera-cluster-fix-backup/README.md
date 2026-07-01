# MariaDB Galera Cluster + HAProxy — Quick Start

Deploy dari **MacBook / mesin administrator** via Ansible SSH ke VM Proxmox.

## Prasyarat

```bash
brew install ansible
cd mariadb-galera-cluster-fix
ansible-galaxy collection install -r requirements.yml
```

## Setup Awal (sekali)

```bash
# 1. SSH key ke semua server (opsional)
./setup-ssh.sh

# 2. Atur IP & username SSH
./configure-inventory.sh

# 3. Password sudo Linux (user vta)
cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml
# edit: ansible_become_password

# 4. Password HAProxy stats — edit group_vars_haproxy.yml
```

## Deploy

```bash
./run-deploy.sh              # deploy normal
./run-full-deploy.sh         # reset cluster + deploy penuh
```

## Operasi & Troubleshooting

**Baca lengkap:** [`OPERASI.md`](OPERASI.md)

- Menambah/mengubah config MariaDB permanen → `./apply-config.sh`
- Daftar error & solusi (SST, bind-address, MAC duplikat, dll.)
- Verifikasi cluster & HAProxy

## Struktur Folder

```
mariadb-galera-cluster-fix/
├── deploy-mariadb-cluster.yml   # Playbook utama
├── mariadb-cluster-config.j2    # Template config MariaDB/Galera
├── haproxy-config.j2            # Template HAProxy
├── inventory.yml                # Host & IP
├── apply-config.sh              # Apply config + rolling restart
├── run-deploy.sh                # Deploy dengan pre-flight
├── run-full-deploy.sh           # Reset + deploy
├── reset-galera-cluster.sh      # Stop paksa + wipe slave
├── check-cluster-network.sh     # Cek SSH, ping, MAC duplikat
├── fix-sudo-on-server.sh        # NOPASSWD sudo (jalankan di server)
├── configure-inventory.sh       # Setup IP inventory interaktif
├── group_vars/all/
│   ├── mariadb.yml              # Tuning (max_allowed_packet, dll.)
│   ├── secrets.yml              # Password sudo (gitignored)
│   └── ansible.yml
├── OPERASI.md                   # Panduan operasi lengkap
├── ARSITEKTUR.md                # Diagram & migrasi
├── CHANGELOG.md                 # Daftar bug fix dari versi asli
└── trash/                       # Arsip file lama (STEP.md, prepare-cluster.sh)
```

## Koneksi Database

```bash
mysql -h <IP_HAPROXY> -u root -p
# Stats: http://<IP_HAPROXY>:8404/
```

## Dokumentasi Lain

| File | Isi |
|------|-----|
| `OPERASI.md` | Troubleshooting, apply config, perintah harian |
| `ARSITEKTUR.md` | Skema Proxmox, migrasi, firewall |
| `CHANGELOG.md` | 22 bug fix dari versi asli |
