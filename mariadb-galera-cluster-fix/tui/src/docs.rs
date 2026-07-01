use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::paths::ClusterPaths;

#[derive(Debug, Clone)]
pub struct DocEntry {
    pub name: String,
    pub path: PathBuf,
    pub title: String,
}

fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("md") || e.eq_ignore_ascii_case("markdown"))
}

pub fn list_docs(paths: &ClusterPaths) -> Result<Vec<DocEntry>> {
    let docs_dir = paths.docs_dir();
    let mut entries = collect_md_in_dir(&docs_dir)?;

    // Fallback: file .md di root cluster jika docs/ kosong
    if entries.is_empty() {
        entries = collect_md_in_dir(&paths.root)?;
    }

    entries.sort_by(|a, b| {
        let rank = |n: &str| match n.to_uppercase().as_str() {
            "MULAI-DISINI.MD" => 0,
            "README.MD" => 1,
            _ => 2,
        };
        rank(&a.name)
            .cmp(&rank(&b.name))
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(entries)
}

fn collect_md_in_dir(dir: &Path) -> Result<Vec<DocEntry>> {
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut entries: Vec<DocEntry> = fs::read_dir(dir)?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_file() && is_markdown(&e.path()))
        .map(|e| {
            let path = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            let title = title_from_md(&path).unwrap_or_else(|| name.clone());
            DocEntry { name, path, title }
        })
        .collect();
    Ok(entries)
}

fn title_from_md(path: &Path) -> Option<String> {
    let first = fs::read_to_string(path).ok()?;
    for line in first.lines().take(8) {
        let t = line.trim();
        if let Some(h) = t.strip_prefix("# ") {
            return Some(h.to_string());
        }
    }
    None
}

pub fn read_doc(path: &Path) -> Result<Vec<String>> {
    let raw = fs::read_to_string(path).with_context(|| format!("baca {}", path.display()))?;
    Ok(raw.lines().map(String::from).collect())
}

#[derive(Debug, Clone, Default)]
pub struct SetupChecklist {
    pub ansible_installed: bool,
    pub collection_installed: bool,
    pub secrets_yml: bool,
    pub haproxy_yml: bool,
    pub inventory_configured: bool,
}

impl SetupChecklist {
    pub fn evaluate(paths: &ClusterPaths) -> Self {
        let ansible_bin = if cfg!(windows) {
            "ansible.exe"
        } else {
            "ansible"
        };
        let ansible_installed = std::process::Command::new(ansible_bin)
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        let collection_installed = std::process::Command::new(if cfg!(windows) {
            "ansible-galaxy.exe"
        } else {
            "ansible-galaxy"
        })
        .args(["collection", "list", "community.mysql"])
        .output()
        .map(|o| {
            o.status.success() && String::from_utf8_lossy(&o.stdout).contains("community.mysql")
        })
        .unwrap_or(false);

        Self {
            ansible_installed,
            collection_installed,
            secrets_yml: paths.secrets().is_file(),
            haproxy_yml: paths.haproxy_vars().is_file(),
            inventory_configured: inventory_looks_configured(paths),
        }
    }

    pub fn is_complete(&self) -> bool {
        self.ansible_installed
            && self.collection_installed
            && self.secrets_yml
            && self.haproxy_yml
            && self.inventory_configured
    }

    pub fn pending_count(&self) -> usize {
        [
            self.ansible_installed,
            self.collection_installed,
            self.secrets_yml,
            self.haproxy_yml,
            self.inventory_configured,
        ]
        .iter()
        .filter(|&&ok| !ok)
        .count()
    }
}

fn inventory_looks_configured(paths: &ClusterPaths) -> bool {
    let Ok(raw) = fs::read_to_string(paths.inventory()) else {
        return false;
    };
    !raw.contains("10.0.0.50") && !raw.contains("GANTI")
}

pub fn welcome_lines(check: &SetupChecklist) -> Vec<String> {
    let m = |ok: bool| if ok { "[v]" } else { "[ ]" };
    vec![
        "PANDUAN SETUP — Penerima Paket Galera Cluster".into(),
        String::new(),
        "Selesaikan langkah berikut sebelum deploy:".into(),
        String::new(),
        format!(
            "  {} 1. Install Ansible          →  brew install ansible",
            m(check.ansible_installed)
        ),
        format!(
            "  {} 2. Install collection        →  ansible-galaxy collection install -r requirements.yml",
            m(check.collection_installed)
        ),
        format!(
            "  {} 3. Atur inventory           →  ./configure-inventory.sh",
            m(check.inventory_configured)
        ),
        format!(
            "  {} 4. Buat secrets.yml         →  cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml",
            m(check.secrets_yml)
        ),
        format!(
            "  {} 5. Buat group_vars_haproxy   →  cp group_vars_haproxy.yml.example group_vars_haproxy.yml",
            m(check.haproxy_yml)
        ),
        "  [ ] 6. Tes SSH                   →  ansible all -m ping".into(),
        "  [ ] 7. Jalankan deploy           →  ./run-deploy.sh".into(),
        String::new(),
        format!(
            "Status: {} dari 5 prasyarat otomatis belum selesai",
            check.pending_count()
        ),
        String::new(),
        "Enter = menu utama    d = dokumentasi    r = refresh    q = keluar".into(),
    ]
}
