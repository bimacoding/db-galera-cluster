Jalankan script
bashchmod +x prepare-cluster.sh
./prepare-cluster.sh
3. Ikuti alur interaktifnya
Script akan menuntun kamu lewat tahapan ini secara berurutan:
TahapYang ditanya/dilakukan1-4Otomatis: deteksi OS, cek internet, update sistem, install Ansible + collection5Firewall — ditanya apakah server ini node DATABASE atau bukan. Jawab a untuk 3 node DB, jawab b untuk node load balancer6-7Generate SSH key, lalu opsional copy key itu ke semua server tujuan (jawab y kalau server lain belum punya key-mu)8Pilih jenis cluster (otomatis a = MariaDB)9Input IP, port, user SSH untuk 3 node DB + 1 load balancer, nama cluster, dan password root (boleh dikosongkan untuk auto-generate)10Tes koneksi SSH ke semua server11-12Generate inventory.yml otomatis + suntik password ke playbook dengan aman13Simpan kredensial ke file .credentials-*.txt — catat ini, lalu hapus filenya nanti14Ditanya mau langsung jalankan Ansible atau tidak
4. Kalau pilih jalankan Ansible
Akan muncul submenu:
a) Deploy cluster BARU (full)
b) START cluster saja
c) STOP cluster saja
d) Test koneksi Ansible saja (ping)
e) Batal, jalankan manual nanti
Untuk instalasi pertama kali, pilih a.
5. Kalau mau jalankan manual (tanpa script)
bashcd mariadb-galera-cluster
ansible-playbook --fork=1 deploy-mariadb-cluster.yml \
  -i inventory.yml \
  -e @group_vars_haproxy.yml
6. Verifikasi setelah selesai
Di akhir run, playbook akan menampilkan info koneksi otomatis (jumlah node aktif, connection string, URL stats HAProxy). Kamu juga bisa cek manual:
bashmysql -h <IP_LOAD_BALANCER> -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size'"
Harus muncul angka 3 (tiga node).

Satu hal penting: pastikan semua 4 server sudah bisa SSH dari mesin tempat kamu jalankan script ini (baik pakai key atau password) sebelum mulai — kalau belum, siapkan IP, user, dan password/SSH key-nya dulu. Mau saya bantu siapkan langkah SSH key-nya dulu, atau langsung lanjut jalankan?