use std::collections::HashMap;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::paths::ClusterPaths;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostEntry {
    pub ansible_host: String,
    pub ansible_port: u16,
    pub ansible_user: String,
    pub interface_ip: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostGroup {
    pub hosts: HashMap<String, HostEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InventoryChildren {
    pub mariadb_cluster: HostGroup,
    pub load_balancer: HostGroup,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InventoryAll {
    pub children: InventoryChildren,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InventoryRoot {
    pub all: InventoryAll,
}

#[derive(Debug, Clone)]
pub struct HostInfo {
    pub name: String,
    pub group: String,
    pub ip: String,
    pub user: String,
    pub port: u16,
}

impl InventoryRoot {
    pub fn load(paths: &ClusterPaths) -> Result<Self> {
        let raw = std::fs::read_to_string(paths.inventory()).context("baca inventory.yml")?;
        // Strip comments lines starting with # for serde_yaml robustness
        let cleaned: String = raw
            .lines()
            .filter(|l| !l.trim_start().starts_with('#'))
            .collect::<Vec<_>>()
            .join("\n");
        serde_yaml::from_str(&cleaned).context("parse inventory.yml")
    }

    pub fn save(&self, paths: &ClusterPaths) -> Result<()> {
        let yaml = serde_yaml::to_string(self)?;
        let header = "# inventory.yml — diubah via galera-tui\n\n";
        std::fs::write(paths.inventory(), format!("{header}{yaml}"))
            .context("tulis inventory.yml")
    }

    pub fn all_hosts(&self) -> Vec<HostInfo> {
        let mut out = Vec::new();
        for (name, h) in &self.all.children.mariadb_cluster.hosts {
            out.push(HostInfo {
                name: name.clone(),
                group: "mariadb_cluster".into(),
                ip: h.ansible_host.clone(),
                user: h.ansible_user.clone(),
                port: h.ansible_port,
            });
        }
        for (name, h) in &self.all.children.load_balancer.hosts {
            out.push(HostInfo {
                name: name.clone(),
                group: "load_balancer".into(),
                ip: h.ansible_host.clone(),
                user: h.ansible_user.clone(),
                port: h.ansible_port,
            });
        }
        out
    }

    pub fn db_nodes(&self) -> Vec<(String, HostEntry)> {
        self.all
            .children
            .mariadb_cluster
            .hosts
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    pub fn add_db_node(
        &mut self,
        hostname: &str,
        ip: &str,
        user: &str,
        port: u16,
    ) {
        self.all.children.mariadb_cluster.hosts.insert(
            hostname.to_string(),
            HostEntry {
                ansible_host: ip.to_string(),
                ansible_port: port,
                ansible_user: user.to_string(),
                interface_ip: ip.to_string(),
            },
        );
    }

    pub fn next_db_node_name(&self) -> String {
        let mut n = self.all.children.mariadb_cluster.hosts.len() + 1;
        loop {
            let name = format!("mariadb_node_{n}");
            if !self.all.children.mariadb_cluster.hosts.contains_key(&name) {
                return name;
            }
            n += 1;
        }
    }
}
