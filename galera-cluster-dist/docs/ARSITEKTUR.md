# Catatan Arsitektur — Galera Cluster di 2 Bare Metal (Proxmox)

Dokumen ini merangkum skema deployment **MariaDB Galera Cluster + HAProxy** untuk lingkungan:

- **2 bare metal** dengan hypervisor **Proxmox**
- Saat ini masing-masing BM menjalankan **PHP + Python API + MySQL/MariaDB lokal**
- Data di **BM1 dan BM2 identik** (~200 MB)
- Target: pisah layer app dan database, migrasi ke Galera cluster

> Playbook dan panduan operasional: lihat `OPERASI.md`, `README.md`, dan `deploy-mariadb-cluster.yml`.

---

## Daftar Isi

1. [Ringkasan](#1-ringkasan)
2. [Artinya untuk Anda (Data Identik)](#2-artinya-untuk-anda-data-identik)
3. [Skema Final VM di Proxmox](#3-skema-final-vm-di-proxmox)
4. [Inventory Ansible (Contoh)](#4-inventory-ansible-contoh)
5. [Alur Migrasi](#5-alur-migrasi)
6. [Konfigurasi Aplikasi](#6-konfigurasi-aplikasi)
7. [Perilaku Setelah Migrasi](#7-perilaku-setelah-migrasi)
8. [Network & Firewall](#8-network--firewall)
9. [Sizing VM (200 MB Data)](#9-sizing-vm-200-mb-data)
10. [Checklist Singkat](#10-checklist-singkat)
11. [Kesimpulan](#11-kesimpulan)

---

## 1. Ringkasan

Kalau data di **BM1 dan BM2 identik**, migrasi ke Galera jauh lebih sederhana:

- **Tidak perlu merge** data antar server
- Cukup **ambil dump dari salah satu saja** (BM1 atau BM2)
- Semua aplikasi diarahkan ke **HAProxy** (bukan ke node Galera langsung)

```
                    ┌─────────────────────────────────┐
   app-bm1 ────────►│  HAProxy  10.0.1.20 :3306       │
   app-bm2 ────────►│  (satu titik koneksi database)  │
                    └───────────────┬─────────────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
        db-node-1              db-node-2              db-node-3
        10.0.1.11              10.0.1.12              10.0.1.13
        (BM1)                  (BM2)                  (BM1)
              ◄────────── Galera sync ──────────►
```

**Aturan emas:**


| Peran                                                        | Dijalankan di                                                 |
| ------------------------------------------------------------ | ------------------------------------------------------------- |
| `setup-ssh.sh`, `configure-inventory.sh`, `ansible-playbook` | **Mesin Administrator** (satu mesin — laptop/PC/VM manajemen) |
| MariaDB Galera, HAProxy                                      | **VM target** (di Proxmox)                                    |
| PHP + Python API                                             | **VM app** — konek ke HAProxy saja                            |


---

## 2. Artinya untuk Anda (Data Identik)


| Aspek                  | Implikasi                                                               |
| ---------------------- | ----------------------------------------------------------------------- |
| **Sumber data**        | Pilih **satu** (mis. BM1) sebagai sumber `mysqldump`                    |
| **BM2**                | Hanya dipakai untuk **verifikasi opsional**; tidak wajib di-import lagi |
| **Risiko data hilang** | **Rendah**, asalkan sebelum cutover **stop write** di kedua app         |
| **Ukuran 200 MB**      | Dump + restore ke cluster biasanya **beberapa menit**                   |


---

## 3. Skema Final VM di Proxmox

### 3.1 Topologi

```
BM1 (Proxmox)                          BM2 (Proxmox)
├─ VM app-bm1      10.0.1.101          ├─ VM app-bm2      10.0.1.102
│    PHP + Python API                 │    PHP + Python API
│    DB_HOST = 10.0.1.20              │    DB_HOST = 10.0.1.20
│                                     │
├─ VM db-node-1    10.0.1.11          ├─ VM db-node-2    10.0.1.12
├─ VM db-node-3    10.0.1.13          │
├─ VM haproxy-lb   10.0.1.20          │
   (atau HAProxy di BM2)                 (jangan node_2 + node_3 sama-sama di BM2)
```

### 3.2 Penempatan node_3 (Penting)

Karena **node_2** sudah di **BM2**, taruh **node_3 di BM1** (bersama node_1), **bukan di BM2**.


| Penempatan                                    | Jika 1 BM mati                   | Quorum cluster                    |
| --------------------------------------------- | -------------------------------- | --------------------------------- |
| node_1 + node_3 di **BM1**, node_2 di **BM2** | Maks. **1 node DB** hilang       | ✅ 2 suara tersisa — cluster hidup |
| node_2 + node_3 di **BM2** (hindari)          | Bisa **2 node** hilang sekaligus | ❌ Cluster mati                    |


### 3.3 Diagram Mermaid

```mermaid
graph TB
    subgraph BM1["Bare Metal 1 (Proxmox)"]
        APP1["app-bm1<br/>10.0.1.101<br/>PHP + Python"]
        DB1["db-node-1<br/>10.0.1.11"]
        DB3["db-node-3<br/>10.0.1.13"]
        HAP["haproxy-lb<br/>10.0.1.20"]
    end

    subgraph BM2["Bare Metal 2 (Proxmox)"]
        APP2["app-bm2<br/>10.0.1.102<br/>PHP + Python"]
        DB2["db-node-2<br/>10.0.1.12"]
    end

    APP1 --> HAP
    APP2 --> HAP
    HAP --> DB1
    HAP --> DB2
    HAP --> DB3
    DB1 <--> DB2
    DB2 <--> DB3
    DB3 <--> DB1

    style BM1 fill:#1e3a8a,stroke:#ffffff,stroke-width:2px,color:#ffffff
    style BM2 fill:#1e3a8a,stroke:#ffffff,stroke-width:2px,color:#ffffff
    style APP1 fill:#1e3a8a,stroke:#ffffff,stroke-width:2px,color:#ffffff
    style APP2 fill:#1e3a8a,stroke:#ffffff,stroke-width:2px,color:#ffffff
    style DB1 fill:#1e3a8a,stroke:#ffffff,stroke-width:2px,color:#ffffff
    style DB2 fill:#1e3a8a,stroke:#ffffff,stroke-width:2px,color:#ffffff
    style DB3 fill:#1e3a8a,stroke:#ffffff,stroke-width:2px,color:#ffffff
    style HAP fill:#1e3a8a,stroke:#ffffff,stroke-width:2px,color:#ffffff
```



---

## 4. Inventory Ansible (Contoh)

File `inventory.yml` — disesuaikan via `./configure-inventory.sh` atau edit manual:

```yaml
[mariadb_cluster]
mariadb_node_1 ansible_host=10.0.1.11 ansible_port=22 ansible_user=ubuntu interface_ip=10.0.1.11   # VM di BM1
mariadb_node_2 ansible_host=10.0.1.12 ansible_port=22 ansible_user=ubuntu interface_ip=10.0.1.12   # VM di BM2
mariadb_node_3 ansible_host=10.0.1.13 ansible_port=22 ansible_user=ubuntu interface_ip=10.0.1.13   # VM di BM1

[load_balancer]
haproxy_load_balancer ansible_host=10.0.1.20 ansible_port=22 ansible_user=ubuntu interface_ip=10.0.1.20   # VM di BM1
```

Deploy dari **Mesin Administrator**:

```bash
cd mariadb-galera-cluster-fix
ansible-playbook --fork=1 deploy-mariadb-cluster.yml \
  -i inventory.yml \
  -e @group_vars_haproxy.yml
```

---

## 5. Alur Migrasi

### Fase 1 — Siapkan VM (tanpa ganggu produksi)

1. Buat VM di Proxmox: **2 app**, **3 DB**, **1 HAProxy** (subnet `10.0.1.0/24`)
2. Setup SSH key ke semua VM (`setup-ssh.sh` dari Mesin Administrator)
3. Deploy Galera + HAProxy via Ansible — cluster kosong harus jalan
4. Verifikasi:

```bash
mysql -h 10.0.1.20 -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Harus: 3

mysql -h 10.0.1.20 -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
# Harus: Synced
```

### Fase 2 — Import data (maintenance singkat)

Dijalankan dari **Mesin Administrator** (atau VM yang bisa akses BM1 lama dan HAProxy):

```bash
# 1. Dump dari BM1 (satu sumber saja — data identik)
mysqldump -h <IP_MYSQL_LAMA_BM1> -u root -p \
  --all-databases \
  --single-transaction \
  --routines --triggers --events \
  | gzip > backup-pre-galera.sql.gz

# 2. Restore ke cluster via HAProxy
gunzip -c backup-pre-galera.sql.gz | mysql -h 10.0.1.20 -u root -p

# 3. Verifikasi
mysql -h 10.0.1.20 -u root -p -e "SHOW DATABASES;"
mysql -h 10.0.1.20 -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Harus: 3
```

**Opsional:** bandingkan jumlah baris di 1–2 tabel penting antara BM1 lama dan cluster — seharusnya sama.

### Fase 3 — Cutover aplikasi (~5–15 menit)

1. **Stop write:** matikan PHP/Python di **BM1 dan BM2** (maintenance mode / stop service)
2. **Dump ulang (opsional tapi aman):** jika ada write kecil setelah dump pertama, dump sekali lagi dari BM1 → import ke cluster. Jika benar-benar tidak ada write sejak dump pertama, langkah ini bisa dilewati
3. **Ubah config app** di VM app (atau sementara masih di bare metal):

```env
DB_HOST=10.0.1.20
DB_PORT=3306
```

1. **Start app** → test login, API, insert/update
2. **Matikan MySQL lokal** di BM1 & BM2 — **jangan dual-write** ke DB lama

```mermaid
sequenceDiagram
    participant BM1 as BM1 (DB + App lama)
    participant BM2 as BM2 (DB + App lama)
    participant Cluster as Galera via HAProxy
    participant App as App VM baru

    Note over BM1,Cluster: Fase 2: Import (satu sumber)
    BM1->>Cluster: mysqldump → restore ke 10.0.1.20

    Note over BM1,App: Fase 3: Cutover
    BM1->>BM1: Stop app + stop write
    BM2->>BM2: Stop app + stop write
    App->>Cluster: DB_HOST = 10.0.1.20
    App->>Cluster: Test read/write
    BM1->>BM1: Matikan MySQL lokal
    BM2->>BM2: Matikan MySQL lokal
```



---

## 6. Konfigurasi Aplikasi

**app-bm1** dan **app-bm2** memakai **host yang sama** (`10.0.1.20`). Galera memastikan data di ketiga node DB identik; HAProxy mendistribusikan koneksi TCP.

### PHP (`.env` / config)

```env
DB_HOST=10.0.1.20
DB_PORT=3306
DB_DATABASE=nama_database
DB_USERNAME=app_user
DB_PASSWORD=...
```

### Python

```python
DATABASE_URL = "mysql+pymysql://app_user:password@10.0.1.20:3306/nama_database"
```

### User database untuk aplikasi (bukan root)

Jalankan sekali di cluster (via HAProxy):

```sql
CREATE USER IF NOT EXISTS 'app_user'@'%' IDENTIFIED BY 'password_kuat';
GRANT ALL PRIVILEGES ON nama_database.* TO 'app_user'@'%';
FLUSH PRIVILEGES;
```

**Yang tidak boleh lagi:**

```text
DB_HOST=127.0.0.1
DB_HOST=localhost
DB_HOST=10.0.1.101   # IP VM app sendiri
DB_HOST=10.0.1.11    # IP node Galera langsung
```

---

## 7. Perilaku Setelah Migrasi


| Situasi                                                   | Yang terjadi                                                                                   |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| User hit **app-bm1**                                      | Write/read → HAProxy → salah satu node Galera → replikasi ke 2 node lain                       |
| User hit **app-bm2**                                      | Sama — **database yang sama**                                                                  |
| **BM1 mati** (app + db-node-1 + node_3 + mungkin HAProxy) | App BM2 tetap jalan; cluster hidup jika quorum OK (**node_2** + sisa node di BM2 atau witness) |
| **BM2 mati** (app + db-node-2)                            | App BM1 tetap jalan; cluster hidup (**node_1 + node_3** di BM1)                                |
| **HAProxy mati**                                          | Semua app gagal konek DB — pertimbangkan **HAProxy kedua + VIP** (Keepalived) nanti            |


---

## 8. Network & Firewall

Subnet contoh: **10.0.1.0/24** (VLAN private di Proxmox).


| Dari                | Ke                   | Port                               | Keterangan                   |
| ------------------- | -------------------- | ---------------------------------- | ---------------------------- |
| App VM (101, 102)   | HAProxy (20)         | 3306/tcp                           | Koneksi aplikasi ke database |
| HAProxy (20)        | Node DB (11, 12, 13) | 3306/tcp                           | Health check + proxy         |
| Node DB ↔ Node DB   | antar 11/12/13       | 3306, 4444, 4567/tcp+udp, 4568/tcp | Replikasi Galera             |
| Mesin Administrator | Semua VM             | 22/tcp                             | SSH / Ansible                |
| Admin (browser)     | HAProxy              | 8404/tcp                           | Stats dashboard — batasi IP  |


Aplikasi **tidak perlu** akses langsung ke port Galera (4567, 4444, 4568) — hanya antar node DB.

---

## 9. Sizing VM (200 MB Data)


| VM                    | vCPU | RAM  | Disk      | Catatan                 |
| --------------------- | ---- | ---- | --------- | ----------------------- |
| **app-bm1 / app-bm2** | 2    | 4 GB | 40 GB     | PHP + Python API        |
| **db-node-1/2/3**     | 2    | 4 GB | 30 GB SSD | Data 200 MB + ruang SST |
| **haproxy-lb**        | 1    | 1 GB | 10 GB     | TCP proxy + stats       |


Default playbook: `innodb_buffer_pool_size=1G` — sudah lebih dari cukup untuk 200 MB data.

---

## 10. Checklist Singkat

- [ ] VM: **app×2**, **db×3**, **haproxy×1** — node_1 & node_3 di **BM1**, node_2 di **BM2**
- [ ] SSH passwordless dari Mesin Administrator ke semua VM
- [ ] Firewall: port Galera terbuka antar node DB
- [ ] Deploy cluster (Ansible) — `wsrep_cluster_size = 3`, state `Synced`
- [ ] Dump **hanya dari BM1** → restore ke **10.0.1.20**
- [ ] Stop app BM1 & BM2 → ubah `DB_HOST` → start app
- [ ] Matikan MySQL lokal di BM1 & BM2
- [ ] Buat user `**app_user`** di cluster (bukan root untuk app)
- [ ] Hapus / arsip file `.credentials-*.txt` setelah dicatat

---

## 11. Kesimpulan

**Data identik** = tidak perlu rekonsiliasi BM1 vs BM2.

Alur singkat:

1. **Deploy cluster** (Ansible dari Mesin Administrator)
2. **Import** dari satu sumber (BM1)
3. **Semua app** ke HAProxy **10.0.1.20**
4. **Matikan DB lokal** di BM1 & BM2

Dengan **200 MB**, maintenance window bisa sangat pendek (orde **5–15 menit** untuk cutover aplikasi).

---

## Referensi


| File                         | Isi                                            |
| ---------------------------- | ---------------------------------------------- |
| `OPERASI.md`                 | Panduan operasi, troubleshooting, apply config |
| `README.md`                  | Ringkasan paket & bug fix                      |
| `inventory.yml`              | Template inventory Ansible                     |
| `deploy-mariadb-cluster.yml` | Playbook deployment                            |
| `CHANGELOG.md`               | Daftar perbaikan dari versi asli               |


