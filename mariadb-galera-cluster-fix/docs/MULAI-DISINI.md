# Mulai Di Sini — Panduan Penerima Paket

Selamat datang di **Galera Cluster Dist**. Ikuti langkah berikut **sekali**
sebelum menggunakan TUI atau deploy cluster.

---

## Langkah 1 — Install Ansible

**macOS**
```bash
brew install ansible
```

**Linux (Debian/Ubuntu)**
```bash
sudo apt update && sudo apt install -y ansible
# atau: pip install ansible
```

**Windows (PowerShell)**
```powershell
pip install ansible
```

---

## Langkah 2 — Install Collection Ansible

Jalankan dari folder paket (`galera-cluster-dist`):

```bash
ansible-galaxy collection install -r requirements.yml
```

---

## Langkah 3 — Atur IP & User SSH

```bash
./configure-inventory.sh
```

Isi IP node MariaDB (min. 3) dan HAProxy sesuai environment Anda.

---

## Langkah 4 — Password Sudo Linux

```bash
cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml
```

Edit `group_vars/all/secrets.yml` — isi `ansible_become_password` (password **sudo**
user SSH, bukan password MariaDB).

Alternatif: jalankan `fix-sudo-on-server.sh` di setiap server sebagai root
(NOPASSWD sudo).

---

## Langkah 5 — Password HAProxy Stats

```bash
cp group_vars_haproxy.yml.example group_vars_haproxy.yml
```

Edit password dashboard HAProxy (`http://<IP_HAPROXY>:8404/`).

---

## Langkah 6 — SSH ke Semua Server

Pastikan SSH key sudah terpasang:

```bash
./setup-ssh.sh
# atau tes manual:
ansible all -m ping
```

---

## Langkah 7 — Jalankan TUI atau Deploy

**TUI (disarankan)**
```bash
./start.sh
```

**Deploy manual**
```bash
./run-deploy.sh
```

---

## Checklist Cepat

| # | Langkah | Perintah |
|---|---------|----------|
| 1 | Ansible terinstall | `ansible --version` |
| 2 | Collection terinstall | `ansible-galaxy collection list \| grep mysql` |
| 3 | Inventory diisi | `./configure-inventory.sh` |
| 4 | secrets.yml ada | `cp ... secrets.yml` + edit |
| 5 | group_vars_haproxy.yml ada | `cp ... group_vars_haproxy.yml` + edit |
| 6 | SSH OK | `ansible all -m ping` |
| 7 | Deploy / TUI | `./start.sh` |

---

## Dokumentasi Lain

Baca file di folder `docs/`:

- `OPERASI.md` — troubleshooting & operasi harian
- `ARSITEKTUR.md` — diagram & migrasi
- `CHANGELOG.md` — perbaikan dari versi asli
