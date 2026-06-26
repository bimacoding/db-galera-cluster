# MariaDB Galera Cluster + HAProxy — Versi Diperbaiki

Paket ini adalah hasil koreksi dari skrip/playbook asli. Semua bug yang
ditemukan dijelaskan secara rinci di `CHANGELOG.md`. Ringkasan paling
kritis:

## 5 Bug Paling Berbahaya (akan membuat cluster gagal total)

1. **`wsrep_sst_auth` hilang** di `mariadb-cluster-config.j2`
   → SST/IST antar-node SELALU gagal autentikasi mariabackup, node baru
   tidak bisa join cluster. **Sudah diperbaiki**: ditambahkan
   `wsrep_sst_auth="mariabackup:{{ mariadb_sst_password }}"`.

2. **`apt_key` module** sudah dihapus dari Ansible modern
   → instalasi repo MariaDB gagal di Ubuntu 22.04/24.04.
   **Sudah diperbaiki**: pakai `get_url` + keyring `signed-by=`.

3. **Modul `mysql_user`/`mysql_db` butuh collection `community.mysql`**
   yang tidak pernah disebutkan sebagai prasyarat
   → seluruh task user/password gagal "module not found".
   **Sudah diperbaiki**: ditambahkan `requirements.yml` + auto-install
   di `prepare-cluster.sh`.

4. **Port Galera (4444/4567/4568) bersifat opsional** di firewall
   script asli → kalau user pilih "tidak", cluster tidak akan pernah
   bisa sync. **Sudah diperbaiki**: port ini sekarang wajib dibuka
   untuk node database.

5. **`sed` untuk inject password ke YAML** rentan rusak/error kalau
   password mengandung karakter seperti `&`, `/`, `\`
   → password auto-generate punya kemungkinan tinggi memicu bug ini.
   **Sudah diperbaiki**: pakai Python dengan YAML single-quote escaping
   yang sudah diuji eksplisit dengan karakter `& / \ # $ '`.

Lihat `CHANGELOG.md` untuk daftar lengkap (22 temuan).

## Cara Pakai

```bash
chmod +x prepare-cluster.sh
./prepare-cluster.sh
```

Script akan:
1. Deteksi OS, install dependencies (termasuk collection Ansible yang
   dibutuhkan)
2. Konfigurasi firewall (port Galera otomatis dibuka untuk node DB)
3. Setup SSH key & opsional copy ke server tujuan
4. Minta info node database (≥3) dan load balancer
5. Generate `inventory.yml`, update password di playbook dengan aman
6. Simpan kredensial ke file `.credentials-*.txt` (root password, SST
   password, HAProxy stats password — **pindahkan ke vault & hapus
   file ini setelah dicatat**)
7. Opsional langsung jalankan `ansible-playbook`

## Instalasi manual collection (jika tidak lewat prepare-cluster.sh)

```bash
ansible-galaxy collection install -r mariadb-galera-cluster/requirements.yml
```

## Menjalankan playbook manual

```bash
cd mariadb-galera-cluster
ansible-playbook --fork=1 deploy-mariadb-cluster.yml \
  -i inventory.yml \
  -e @group_vars_haproxy.yml
```

Tag yang tersedia: `start_cluster`, `stop_cluster`.

## Catatan Keamanan

- Jangan commit file `.credentials-*.txt` atau playbook dengan password
  asli ke git. Pertimbangkan `ansible-vault encrypt` untuk
  `deploy-mariadb-cluster.yml` setelah variabel terisi.
- `wsrep_provider_options` pakai format durasi ISO-8601 (`PT15S`, bukan
  `15.0`) — sudah dikonsistenkan di file ini agar tidak ambigu di
  parser Galera versi baru.
- Port stats HAProxy (8404) dan port database tetap harus dibatasi di
  level network/firewall cloud provider (security group), tidak cukup
  hanya UFW di OS.
