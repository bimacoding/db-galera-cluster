use std::env;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

/// Root folder cluster (mariadb-galera-cluster-fix atau galera-cluster-dist).
#[derive(Debug, Clone)]
pub struct ClusterPaths {
    pub root: PathBuf,
}

impl ClusterPaths {
    pub fn discover() -> Result<Self> {
        if let Ok(dir) = env::var("GALERA_CLUSTER_DIR") {
            return Self::from_root(PathBuf::from(dir));
        }

        let mut candidates: Vec<PathBuf> = Vec::new();

        if let Ok(cwd) = env::current_dir() {
            candidates.push(cwd.clone());
            if let Some(name) = cwd.file_name().and_then(|n| n.to_str()) {
                if name == "tui" {
                    if let Some(p) = cwd.parent() {
                        candidates.push(p.to_path_buf());
                    }
                }
            }
            candidates.push(cwd.join("mariadb-galera-cluster-fix"));
            candidates.push(cwd.join("galera-cluster-dist"));
        }

        if let Some(from_exe) = Self::root_from_exe() {
            candidates.push(from_exe);
        }

        for c in candidates {
            if Self::looks_valid(&c) {
                return Self::from_root(c);
            }
        }

        anyhow::bail!(
            "Folder cluster tidak ditemukan.\n\
             Set: export GALERA_CLUSTER_DIR=/path/to/galera-cluster-dist\n\
             Lalu jalankan: ./start.sh"
        );
    }

    /// Naik dari lokasi binary (mis. bin/darwin-aarch64/) sampai ketemu playbook.
    fn root_from_exe() -> Option<PathBuf> {
        let mut dir = env::current_exe().ok()?.parent()?.to_path_buf();
        for _ in 0..8 {
            if Self::looks_valid(&dir) {
                return Some(dir);
            }
            dir = dir.parent()?.to_path_buf();
        }
        None
    }

    fn looks_valid(p: &Path) -> bool {
        p.join("deploy-mariadb-cluster.yml").is_file() && p.join("inventory.yml").is_file()
    }

    fn from_root(root: PathBuf) -> Result<Self> {
        let root = root.canonicalize().unwrap_or(root);
        if !Self::looks_valid(&root) {
            anyhow::bail!("Bukan folder cluster valid: {}", root.display());
        }
        Ok(Self { root })
    }

    pub fn docs_dir(&self) -> PathBuf {
        self.root.join("docs")
    }

    pub fn inventory(&self) -> PathBuf {
        self.root.join("inventory.yml")
    }

    pub fn mariadb_vars(&self) -> PathBuf {
        self.root.join("group_vars/all/mariadb.yml")
    }

    pub fn secrets(&self) -> PathBuf {
        self.root.join("group_vars/all/secrets.yml")
    }

    pub fn haproxy_vars(&self) -> PathBuf {
        self.root.join("group_vars_haproxy.yml")
    }

    pub fn deploy_playbook(&self) -> PathBuf {
        self.root.join("deploy-mariadb-cluster.yml")
    }

    pub fn apply_playbook(&self) -> PathBuf {
        self.root.join("apply-config.yml")
    }

    pub fn ansible_cfg(&self) -> PathBuf {
        self.root.join("ansible.cfg")
    }

    pub fn requirements(&self) -> PathBuf {
        self.root.join("requirements.yml")
    }

    pub fn extract_playbook_passwords(&self) -> Result<(String, String)> {
        let content = std::fs::read_to_string(self.deploy_playbook())
            .context("baca deploy-mariadb-cluster.yml")?;
        let root_re = regex::Regex::new(r#"mariadb_root_password:\s*"([^"]+)""#)?;
        let sst_re = regex::Regex::new(r#"mariadb_sst_password:\s*"([^"]+)""#)?;
        let root = root_re
            .captures(&content)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .context("mariadb_root_password tidak ditemukan")?;
        let sst = sst_re
            .captures(&content)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .context("mariadb_sst_password tidak ditemukan")?;
        Ok((root, sst))
    }
}
