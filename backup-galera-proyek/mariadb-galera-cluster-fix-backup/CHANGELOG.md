# Changelog Perbaikan

Daftar lengkap temuan dari review file asli, dikelompokkan per file.

## deploy-mariadb-cluster.yml

| # | Masalah | Dampak | Perbaikan |
|---|---------|--------|-----------|
| 1 | Modul `apt_key` dipakai untuk import GPG key | Deprecated/dihapus di Ansible modern; gagal di Ubuntu 22.04/24.04 | Diganti `get_url` + repo `signed-by=/usr/share/keyrings/...` |
| 2 | Modul `mysql_user`/`mysql_db` dipakai tanpa menyebut prasyarat collection | Task gagal "couldn't resolve module/action" jika `community.mysql` tidak terinstall | Tambah `requirements.yml`, auto-install di `prepare-cluster.sh` |
| 3 | `mysql_user` login root pakai `login_password: ""` | Gagal autentikasi pada run kedua setelah password sudah diset sebelumnya | Pakai `login_unix_socket: /run/mysqld/mysqld.sock` untuk root |
| 4 | Urutan: set password dieksekusi jauh setelah start cluster, hanya diberi `pause` statis 10s | SST besar bisa >10s, task setelahnya gagal connect | Ganti `pause` jadi `wait_for: port 3306` dengan timeout adaptif (60-300s) |
| 5 | `ansible_default_ipv4` dipakai tanpa opsi override | Salah pilih interface di server multi-NIC (umum di cloud VPS) | Tambah var `interface_ip` yang bisa di-override per host, fallback ke `ansible_default_ipv4` |
| 6 | Bootstrap SST user lewat `mysqld --skip-grant-tables` sementara, lalu `ignore_errors: yes` | Kalau gagal start, lanjut diam-diam tanpa SST user — gagal terdeteksi belakangan saat sync | Dipindah ke task normal setelah cluster benar-benar up, tanpa `ignore_errors` |
| 7 | SST user hanya dibuat di node pertama, bukan semua node | Donor lain selain node pertama tidak punya user mariabackup | Task `mariabackup` user sekarang `when: "'mariadb_cluster' in group_names"` (semua node) |
| 8 | Tidak ada `wsrep_sst_auth` di config | **Bug paling kritis** — SST/IST selalu gagal autentikasi | Ditambahkan di `mariadb-cluster-config.j2` |
| 9 | Password root default plaintext `"ChangeMe!123"` di file | Risiko jika ter-commit ke git | Diganti placeholder `CHANGE_ME_BEFORE_DEPLOY`, didorong ke vault |
| 10 | `with_items` dipakai bukan `loop` | Deprecated style, bukan fatal | Diganti `loop` |
| 11 | Task pembuatan user HAProxy untuk "semua node" tapi host masih hardcode IP load balancer | Membingungkan, redundant | Disederhanakan dan diberi privilege minimal `USAGE` |
| 12 | `wsrep_provider_options` pakai `pc.announce_timeout=15.0` (bukan format durasi standar) | Ambigu di parser Galera versi baru | Diganti `PT15S` (ISO-8601), konsisten dengan opsi lain |
| 13 | Tidak ada retry pada test SSH ping awal sebelum mysql_user dijalankan | False negative kalau mariadb baru saja restart | Ditambah `wait_for` sebelum task user |

## haproxy-config.j2

| # | Masalah | Dampak | Perbaikan |
|---|---------|--------|-----------|
| 14 | `bind {{ ansible_default_ipv4.address }}:8404` dan `:3306` | Salah bind di server multi-NIC, service tidak bisa diakses | Diganti `bind 0.0.0.0:PORT`, batasi akses lewat firewall |
| 15 | `option mysql-check user haproxy` | Sering tidak akurat di MariaDB 10.5+ karena perubahan handshake | Diganti `option tcp-check` + `tcp-check connect port 3306` |
| 16 | `stats auth admin:admin123` hardcoded | Password default lemah & publik di file | Diparameterisasi via `haproxy_stats_user`/`haproxy_stats_password`, di-generate random oleh `prepare-cluster.sh` |

## mariadb-cluster-config.j2

| # | Masalah | Dampak | Perbaikan |
|---|---------|--------|-----------|
| 17 | `wsrep_sst_auth` tidak ada sama sekali | SST selalu gagal otentikasi | Ditambahkan, mengambil dari var `mariadb_sst_password` |
| 18 | `innodb_buffer_pool_size=1G` hardcoded | Bisa terlalu besar/kecil tergantung RAM VM | Diparameterisasi `{{ mariadb_innodb_buffer_pool_size | default('1G') }}` |
| 19 | `max_connections=500` hardcoded | Tidak fleksibel untuk cluster kecil/besar | Diparameterisasi `{{ mariadb_max_connections | default('500') }}` |
| 20 | `wsrep_cluster_address` pakai `ansible_default_ipv4.address` langsung | Sama dengan #5 (salah interface di multi-NIC) | Pakai `interface_ip` dengan fallback |

## prepare-cluster.sh

| # | Masalah | Dampak | Perbaikan |
|---|---------|--------|-----------|
| 21 | `sed -i "s/.../.../"` untuk inject password ke YAML | Password dengan `&`, `/`, `\` merusak command sed atau hasil YAML (terverifikasi lewat pengujian — error nyata) | Diganti skrip Python dengan **YAML single-quote escaping** (diuji eksplisit dengan password berisi `& / \ # $ '`, hasil round-trip 100% sesuai) |
| 22 | Tidak ada validasi format IP saat input | Typo IP lolos ke Ansible, gagal di tengah proses | Ditambah fungsi `is_valid_ip()` + `prompt_ip()` yang mengulang input sampai valid |
| 23 | Firewall Galera port (4444/4567/4568) opsional | User bisa pilih "tidak" dan cluster gagal sync | Port ini sekarang otomatis dibuka untuk node database (tidak ditanya lagi opsional) |
| 24 | Password SST dan HAProxy stats tidak pernah digenerate/disinkronkan ke playbook | `wsrep_sst_auth` & `stats auth` di template menjadi tidak terisi/manual | Ditambah generate otomatis `MYSQL_SST_PASSWORD` & `HAPROXY_STATS_PASSWORD`, ditulis ke `group_vars_haproxy.yml` & `deploy-mariadb-cluster.yml` |
| 25 | Tidak ada `set -E` / trap error | Error di dalam function kadang tidak terlihat jelas baris mana yang gagal | Ditambah `trap 'log_error ...' ERR` |
| 26 | Daftar paket Debian belum mencakup 12 secara eksplisit | Minor gap dukungan OS | Ditambahkan deteksi & dukungan Debian 12 (Bookworm) |
| 27 | Opsi pilihan "MySQL 5.7 Galera (EOL)" masih ada di menu | Mengarahkan user ke opsi yang sudah dianggap usang/berisiko oleh skrip aslinya sendiri | Dihapus, hanya menyisakan opsi MariaDB yang didukung penuh paket ini |

## Pengujian yang Dilakukan

- ✅ `bash -n prepare-cluster.sh` — syntax valid
- ✅ Parsing YAML penuh `deploy-mariadb-cluster.yml` via `yaml.safe_load_all` — valid, 43 task terbaca
- ✅ Parsing Jinja2 untuk `haproxy-config.j2` dan `mariadb-cluster-config.j2` — valid
- ✅ Simulasi replace password dengan kombinasi karakter `& / \ # $ '` melalui blok Python yang sama persis dengan isi script — hasil di-parse ulang via YAML dan **identik 100%** dengan input asli (tidak ada karakter hilang/rusak)
