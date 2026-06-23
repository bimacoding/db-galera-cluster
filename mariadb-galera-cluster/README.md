# MariaDB Galera Cluster dengan HAProxy

Playbook Ansible untuk mendeploy **MariaDB 10.11 Galera Cluster** dengan **HAProxy** sebagai load balancer.

## Fitur

- MariaDB 10.11 LTS (support sampai 2028)
- Galera 4 dengan streaming replication
- SST method menggunakan `mariabackup` (non-blocking, tanpa kunci tabel)
- HAProxy sebagai load balancer dengan health check otomatis
- Dashboard monitoring HAProxy (port 8404)
- Security: hapus anonymous user & database test otomatis

---

## 1. Persyaratan Server

### Minimum Server

| Role | Jumlah | Spesifikasi Min |
|---|---|---|
| **MariaDB Cluster Node** | 3 node | 2 CPU, 4GB RAM, 20GB disk |
| **HAProxy Load Balancer** | 1 node | 1 CPU, 2GB RAM, 10GB disk |

### Sistem Operasi yang Didukung

| OS | Versi | Keterangan |
|---|---|---|
| Ubuntu | 20.04 LTS | **Direkomendasikan** |
| Ubuntu | 22.04 LTS | Support penuh |
| Ubuntu | 24.04 LTS | Support penuh |
| Debian | 11 / 12 | Support (belum diuji penuh) |

> **Catatan:** Playbook ini dioptimalkan untuk Ubuntu. Untuk Debian mungkin perlu penyesuaian nama paket.

---

## 2. Persiapan Sebelum Deployment

### 2.1 Di Setiap Server (Semua Node)

Jalankan perintah berikut di **semua server** (cluster node + HAProxy):

```bash
# Update sistem
sudo apt update && sudo apt upgrade -y

# Install Python 3 (wajib untuk Ansible)
sudo apt install -y python3 python3-apt

# Cek koneksi internet (pastikan bisa akses mirror mariadb)
ping -c 3 mirror.mariadb.org

# Cek hostname dan pastikan unik
hostnamectl
# Jika perlu ganti hostname:
# sudo hostnamectl set-hostname nama-unik-node

# Matikan firewall sementara (atau buka port yang diperlukan)
sudo ufw disable
# Atau buka port manual (lihat bagian port di bawah)
```

### 2.2 Port yang Harus Dibuka (Firewall)

Jika menggunakan firewall, buka port-port berikut di **setiap node cluster**:

| Port | Protocol | Fungsi |
|---|---|---|
| 3306 | TCP | MySQL/MariaDB client connection |
| 4444 | TCP | SST (State Snapshot Transfer) via mariabackup |
| 4567 | TCP/UDP | Galera replication traffic |
| 4568 | TCP | IST (Incremental State Transfer) |
| 22 | TCP | SSH (untuk Ansible) |

**Contoh perintah ufw:**
```bash
sudo ufw allow 3306/tcp
sudo ufw allow 4444/tcp
sudo ufw allow 4567/tcp
sudo ufw allow 4567/udp
sudo ufw allow 4568/tcp
sudo ufw allow 22/tcp
```

### 2.3 Di Mesin Kontrol (Tempat Ansible Diinstal)

```bash
# Install Ansible (macOS / Linux)
# macOS:
brew install ansible

# Ubuntu/Debian:
sudo apt update && sudo apt install -y ansible

# CentOS/RHEL:
sudo yum install -y epel-release && sudo yum install -y ansible

# Verifikasi instalasi
ansible --version
```

### 2.4 Setup SSH Key (Wajib)

Ansible membutuhkan akses SSH tanpa password ke semua server.

```bash
# 1. Generate SSH key (jika belum punya)
ssh-keygen -t ed25519 -C "ansible@kontrol"

# 2. Copy SSH public key ke setiap server
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.10.2
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.10.3
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.10.4
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.10.5

# 3. Test koneksi SSH (harus bisa login tanpa password)
ssh ubuntu@192.168.10.2 "hostname"
ssh ubuntu@192.168.10.3 "hostname"
ssh ubuntu@192.168.10.4 "hostname"
ssh ubuntu@192.168.10.5 "hostname"
```

### 2.5 Test Koneksi Ansible

Sebelum menjalankan playbook, test koneksi Ansible ke semua server:

```bash
# Masuk ke folder playbook
cd /path/to/mariadb-galera-cluster/

# Test ping semua host
ansible all -i inventory.yml -m ping -u ubuntu
```

Hasil yang diharapkan (semua node harus return `"ping": "pong"`):
```json
mariadb_node_1 | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter": "/usr/bin/python3"
    },
    "changed": false,
    "ping": "pong"
}
mariadb_node_2 | SUCCESS => {
    ...
    "ping": "pong"
}
mariadb_node_3 | SUCCESS => {
    ...
    "ping": "pong"
}
haproxy_load_balancer | SUCCESS => {
    ...
    "ping": "pong"
}
```

---

## 3. Konfigurasi Playbook

### 3.1 Edit File Inventory

Buka file `inventory.yml` dan sesuaikan dengan server Anda:

```ini
[mariadb_cluster]
mariadb_node_1 ansible_host=192.168.10.2 ansible_port=22 ansible_user=ubuntu
mariadb_node_2 ansible_host=192.168.10.3 ansible_port=22 ansible_user=ubuntu
mariadb_node_3 ansible_host=192.168.10.4 ansible_port=22 ansible_user=ubuntu

[load_balancer]
haproxy_load_balancer ansible_host=192.168.10.5 ansible_port=22 ansible_user=ubuntu
```

**Penjelasan parameter:**
- `mariadb_node_1` — Nama host (bisa diganti, tapi harus unik)
- `ansible_host` — IP address server
- `ansible_port` — Port SSH (default 22)
- `ansible_user` — User SSH untuk login (ubuntu, root, dll)

> **PENTING:** Jangan ubah nama grup `[mariadb_cluster]` dan `[load_balancer]` karena ada dependensi di dalam playbook.

### 3.2 Edit Variabel Playbook

Buka file `deploy-mariadb-cluster.yml` dan sesuaikan variabel di bagian `vars`:

```yaml
vars:
  mariadb_cluster_name: prod_mariadb_cluster   # Nama cluster (tanpa spasi)
  mariadb_root_password: "ChangeMe!123"        # Ganti dengan password kuat!
  mariadb_version: "10.11"                     # Versi MariaDB (10.11, 10.10, dll)
```

**Tips password kuat:**
```bash
# Generate password acak 20 karakter
openssl rand -base64 20
```

---

## 4. Menjalankan Playbook

### 4.1 Deploy Full Cluster

```bash
cd /path/to/mariadb-galera-cluster/

ansible-playbook --fork=1 deploy-mariadb-cluster.yml -i inventory.yml
```

**Penjelasan opsi:**
- `--fork=1` — Menonaktifkan eksekusi paralel untuk menjaga konsistensi data saat bootstrap cluster
- `-i inventory.yml` — Menentukan file inventory

### 4.2 Yang Terjadi Saat Deployment

```
Step 1  → Setup repository MariaDB di semua node cluster
Step 2  → Install paket: mariadb-server, galera-4, mariadb-backup
Step 3  → Buat user mariabackup untuk SST
Step 4  → Deploy konfigurasi Galera cluster
Step 5  → Hentikan semua node MySQL/MariaDB
Step 6  → Bootstrap primary node (galera_new_cluster)
Step 7  → Start slave node satu per satu
Step 8  → Install & konfigurasi HAProxy di load balancer
Step 9  → Set root password & hapus anonymous user
Step 10 → Buat user health check (haproxy)
Step 11 → Restart HAProxy
Step 12 → Verifikasi cluster
```

### 4.3 Durasi Deployment

| Tahap | Estimasi Waktu |
|---|---|
| Install paket (5 server) | 5-10 menit |
| Bootstrap cluster | 1-2 menit |
| Konfigurasi HAProxy | 1 menit |
| **Total** | **7-13 menit** |

Tergantung kecepatan internet dan spesifikasi server.

---

## 5. Perintah Lainnya

### 5.1 Hentikan Cluster (Safely)

```bash
ansible-playbook --fork=1 deploy-mariadb-cluster.yml -i inventory.yml --tags "stop_cluster"
```

Urutan stop: slave nodes → primary node (dengan jeda 20 detik untuk shutdown aman).

### 5.2 Mulai Ulang Cluster

```bash
ansible-playbook --fork=1 deploy-mariadb-cluster.yml -i inventory.yml --tags "start_cluster"
```

Urutan start: bootstrap primary node → slave nodes (dengan jeda 15 detik).

### 5.3 Deploy Tanpa Stop/Start (Konfigurasi Ulang)

Jika hanya ingin mengubah konfigurasi tanpa menghentikan cluster:

```bash
# Skip tag stop_cluster dan start_cluster
ansible-playbook --fork=1 deploy-mariadb-cluster.yml -i inventory.yml --skip-tags "stop_cluster,start_cluster"
```

---

## 6. Verifikasi Cluster

### 6.1 Melalui Output Playbook

Setelah playbook selesai, akan tampil informasi seperti ini:

```
ok: [haproxy_load_balancer] => {
    "msg": [
        "===========================================",
        " MariaDB Galera Cluster Setup Complete!",
        "===========================================",
        " Cluster Name      : prod_mariadb_cluster",
        " Active Nodes      : 3",
        " Cluster State     : Synced",
        "",
        " Connection String :",
        " mysql -h 192.168.10.5 -P 3306 -u root -p",
        "",
        " HAProxy Stats     :",
        " http://192.168.10.5:8404/",
        " Username: admin  Password: admin123",
        "==========================================="
    ]
}
```

### 6.2 Manual via Command Line

```bash
# Konek ke cluster melalui load balancer
mysql -h 192.168.10.5 -P 3306 -u root -p
# Masukkan password root

# Cek jumlah node aktif
SHOW STATUS LIKE 'wsrep_cluster_size';

# Cek status node
SHOW STATUS LIKE 'wsrep_local_state_comment';

# Cek koneksi cluster
SHOW STATUS LIKE 'wsrep_connected';

# Cek alamat cluster
SHOW STATUS LIKE 'wsrep_cluster_address';

# Cek method SST yang digunakan
SHOW VARIABLES LIKE 'wsrep_sst_method';
```

### 6.3 Melalui HAProxy Dashboard

Buka browser dan akses:
```
http://192.168.10.5:8404/
```
- **Username:** admin
- **Password:** admin123

Dashboard menunjukkan status setiap node cluster (UP/DOWN) secara real-time.

### 6.4 Cek di Setiap Node

Login ke setiap node cluster dan jalankan:

```bash
# Cek service status
sudo systemctl status mariadb

# Cek proses Galera
ps aux | grep galera

# Cek log untuk error replikasi
sudo tail -f /var/log/mysql/error.log
```

---

## 7. Troubleshooting

### 7.1 Gagal SSH / Ansible Error

```bash
# Test koneksi dulu
ansible all -i inventory.yml -m ping -u ubuntu

# Jika gagal, cek:
# 1. SSH key sudah di-copy? ssh-copy-id user@ip
# 2. Server bisa di-ping? ping ip-server
# 3. SSH port benar? (default 22)
```

### 7.2 Node Gagal Join Cluster

```bash
# Cek node apakah sudah terinstall dengan benar
sudo systemctl status mariadb

# Cek log error
sudo tail -100 /var/log/mysql/error.log | grep -i "galera\|wsrep\|error"

# Coba restart node
sudo systemctl restart mariadb

# Cek cluster size dari node lain
mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size'"
```

### 7.3 Semua Node Down (Cluster Crash)

Jika semua node mati dan perlu recovery:

```bash
# 1. Cari node dengan data terakhir (seqno tertinggi)
sudo cat /var/lib/mysql/grastate.dat
# Cari node dengan safe_to_bootstrap: 1

# 2. Di node yang safe_to_bootstrap:
sudo galera_new_cluster

# 3. Di node lain (start biasa):
sudo systemctl start mariadb
```

### 7.4 Port Bind Error

```bash
# Cek apakah port 3306 sudah digunakan
sudo netstat -tulpn | grep 3306

# Jika ada proses lain yang menggunakan, hentikan:
sudo systemctl stop mysql mariadb
sudo kill -9 $(lsof -ti:3306)
```

---

## 8. Informasi Tambahan

### 8.1 Default Credentials

| Service | Username | Password | Port |
|---|---|---|---|
| MariaDB Root | root | `mariadb_root_password` (di vars) | 3306 (via HAProxy) |
| HAProxy Stats | admin | admin123 | 8404 (HTTP) |
| HAProxy Health Check | haproxy | (tanpa password) | - |

### 8.2 Lokasi File Penting

| File | Lokasi di Server |
|---|---|
| Konfigurasi Galera | `/etc/mysql/conf.d/mariadb_galera_cluster.cnf` |
| Konfigurasi HAProxy | `/etc/haproxy/haproxy.cfg` |
| Log MariaDB | `/var/log/mysql/error.log` |
| Data Directory | `/var/lib/mysql/` |
| Galera State | `/var/lib/mysql/grastate.dat` |

### 8.3 Menambah Node ke Cluster

1. Tambahkan server baru di `inventory.yml`:
```yaml
[mariadb_cluster]
mariadb_node_4 ansible_host=192.168.10.6 ansible_port=22 ansible_user=ubuntu
```

2. Jalankan playbook lagi:
```bash
ansible-playbook --fork=1 deploy-mariadb-cluster.yml -i inventory.yml
```

Node baru akan otomatis melakukan SST dari node yang sudah ada.

### 8.4 Backup Cluster

```bash
# Backup via mariabackup (recommended)
mariabackup --backup \
  --target-dir=/backup/mariadb/$(date +%Y%m%d) \
  --user=root \
  --password=your_password

# Backup via mysqldump (alternatif)
mysqldump -h 192.168.10.5 -u root -p \
  --all-databases \
  --single-transaction \
  --triggers \
  --routines \
  --events \
  > backup_$(date +%Y%m%d).sql
```

---

## Referensi

- [MariaDB Galera Cluster Documentation](https://mariadb.com/kb/en/galera-cluster/)
- [HAProxy Documentation](https://www.haproxy.org/documentation/)
- [Galera Cluster Documentation](https://galeracluster.com/library/)