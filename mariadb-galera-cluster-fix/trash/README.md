# Folder Trash — Arsip File Lama

File di sini **tidak dipakai** dalam alur operasional terbaru (deploy dari MacBook via Ansible).
Disimpan sebagai referensi arsip; boleh dihapus permanen jika sudah tidak diperlukan.

| File | Alasan dipindah | Pengganti |
|------|-----------------|-----------|
| `STEP.md` | Dokumentasi 1900+ baris, referensi `prepare-cluster.sh` & flow lama | `OPERASI.md` |
| `prepare-cluster.sh` | Script all-in-one untuk **Linux di server**, tidak jalan di Mac | `configure-inventory.sh` + `run-deploy.sh` |
| `README.md` (lama) | Quick start mengarah ke `prepare-cluster.sh` | `README.md` (baru di root folder) |

**Alur operasional saat ini:** lihat `../OPERASI.md` dan `../README.md`.
