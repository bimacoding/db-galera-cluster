use std::sync::mpsc;

use anyhow::Result;
use ratatui::widgets::ListState;
use tui_textarea::TextArea;

use crate::ansible::{self, AnsibleJob};
use crate::docs::{self, DocEntry, SetupChecklist};
use crate::inventory::{HostInfo, InventoryRoot};
use crate::paths::ClusterPaths;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    WelcomeSetup,
    MainMenu,
    Dashboard,
    Output,
    Editor,
    AddNode,
    Confirm,
    DocsList,
    DocView,
}

#[derive(Debug, Clone)]
pub struct MenuItem {
    pub label: &'static str,
    pub description: &'static str,
    pub job: Option<AnsibleJob>,
    pub action: MenuAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    ShowDashboard,
    RunJob,
    EditInventory,
    EditMariadbVars,
    AddNode,
    SetupCheck,
    ShowWelcome,
    ShowDocs,
    Quit,
}

pub const MENU: &[MenuItem] = &[
    MenuItem {
        label: "Panduan Setup (Penerima Paket)",
        description: "Checklist langkah awal sebelum deploy",
        job: None,
        action: MenuAction::ShowWelcome,
    },
    MenuItem {
        label: "Dokumentasi (.md)",
        description: "Baca docs/MULAI-DISINI, OPERASI, ARSITEKTUR",
        job: None,
        action: MenuAction::ShowDocs,
    },
    MenuItem {
        label: "Dashboard / Status",
        description: "Lihat status SSH & Galera semua node",
        job: None,
        action: MenuAction::ShowDashboard,
    },
    MenuItem {
        label: "Start Cluster",
        description: "Bootstrap + join node (tag start_cluster)",
        job: Some(AnsibleJob::StartCluster),
        action: MenuAction::RunJob,
    },
    MenuItem {
        label: "Stop Cluster",
        description: "Stop MariaDB di semua node (tag stop_cluster)",
        job: Some(AnsibleJob::StopCluster),
        action: MenuAction::RunJob,
    },
    MenuItem {
        label: "Deploy Playbook",
        description: "Deploy penuh via ansible-playbook",
        job: Some(AnsibleJob::Deploy),
        action: MenuAction::RunJob,
    },
    MenuItem {
        label: "Reset + Full Deploy",
        description: "Stop paksa, wipe slave, bootstrap ulang",
        job: Some(AnsibleJob::ResetAndDeploy),
        action: MenuAction::RunJob,
    },
    MenuItem {
        label: "Apply Config",
        description: "Deploy mariadb-cluster-config.j2 + rolling restart",
        job: Some(AnsibleJob::ApplyConfig),
        action: MenuAction::RunJob,
    },
    MenuItem {
        label: "Check Network",
        description: "Ping semua host via Ansible",
        job: Some(AnsibleJob::CheckNetwork),
        action: MenuAction::RunJob,
    },
    MenuItem {
        label: "Setup / Prerequisites",
        description: "Cek ansible, file config, secrets",
        job: Some(AnsibleJob::SetupCheck),
        action: MenuAction::SetupCheck,
    },
    MenuItem {
        label: "Edit Inventory",
        description: "Edit inventory.yml (IP, user, node)",
        job: None,
        action: MenuAction::EditInventory,
    },
    MenuItem {
        label: "Edit MariaDB Tuning",
        description: "Edit group_vars/all/mariadb.yml",
        job: None,
        action: MenuAction::EditMariadbVars,
    },
    MenuItem {
        label: "Tambah Node DB",
        description: "Form tambah node ke mariadb_cluster",
        job: None,
        action: MenuAction::AddNode,
    },
    MenuItem {
        label: "Keluar",
        description: "Tutup galera-tui",
        job: None,
        action: MenuAction::Quit,
    },
];

pub struct NodeStatus {
    pub host: HostInfo,
    pub ssh: String,
    pub mariadb: String,
    pub cluster_size: String,
    pub state: String,
}

pub struct AddNodeForm {
    pub hostname: String,
    pub ip: String,
    pub user: String,
    pub port: String,
    pub field: usize,
}

pub struct App {
    pub paths: ClusterPaths,
    pub inventory: InventoryRoot,
    pub screen: Screen,
    pub menu_index: usize,
    pub should_quit: bool,
    pub output_lines: Vec<String>,
    pub output_scroll: usize,
    pub output_title: String,
    pub running: bool,
    pub pending_job: Option<AnsibleJob>,
    pub confirm_message: String,
    pub status_rows: Vec<NodeStatus>,
    pub status_message: String,
    pub editor: TextArea<'static>,
    pub editor_path: String,
    pub editor_title: String,
    pub add_node: AddNodeForm,
    pub add_node_message: String,
    pub error_message: Option<String>,
    pub setup_check: SetupChecklist,
    pub welcome_lines: Vec<String>,
    pub doc_entries: Vec<DocEntry>,
    pub doc_index: usize,
    pub doc_lines: Vec<String>,
    pub doc_scroll: usize,
    pub doc_title: String,
    pub docs_list_state: ListState,
    pub docs_hint: String,
    job_rx: Option<mpsc::Receiver<Result<Vec<String>>>>,
}

impl App {
    pub fn new() -> Result<Self> {
        let paths = ClusterPaths::discover()?;
        let inventory = InventoryRoot::load(&paths)?;
        let setup_check = SetupChecklist::evaluate(&paths);
        let welcome_lines = docs::welcome_lines(&setup_check);
        let doc_entries = docs::list_docs(&paths).unwrap_or_default();
        Ok(Self {
            paths,
            inventory,
            screen: Screen::WelcomeSetup,
            menu_index: 0,
            should_quit: false,
            output_lines: Vec::new(),
            output_scroll: 0,
            output_title: String::new(),
            running: false,
            pending_job: None,
            confirm_message: String::new(),
            status_rows: Vec::new(),
            status_message: "Tekan [r] refresh".into(),
            editor: TextArea::default(),
            editor_path: String::new(),
            editor_title: String::new(),
            add_node: AddNodeForm {
                hostname: String::new(),
                ip: String::new(),
                user: "vta".into(),
                port: "22".into(),
                field: 0,
            },
            add_node_message: String::new(),
            error_message: None,
            setup_check,
            welcome_lines,
            doc_entries,
            doc_index: 0,
            doc_lines: Vec::new(),
            doc_scroll: 0,
            doc_title: String::new(),
            docs_list_state: ListState::default(),
            docs_hint: String::new(),
            job_rx: None,
        })
    }

    pub fn refresh_setup(&mut self) {
        self.setup_check = SetupChecklist::evaluate(&self.paths);
        self.welcome_lines = docs::welcome_lines(&self.setup_check);
        self.doc_entries = docs::list_docs(&self.paths).unwrap_or_default();
    }

    pub fn open_docs_list(&mut self) {
        self.doc_entries = docs::list_docs(&self.paths).unwrap_or_default();
        self.doc_index = 0;
        self.docs_list_state.select(if self.doc_entries.is_empty() {
            None
        } else {
            Some(0)
        });
        let docs_path = self.paths.docs_dir();
        self.docs_hint = if self.doc_entries.is_empty() {
            format!(
                "Tidak ada file .md di:\n  {}\n\nPastikan folder docs/ ada. Jalankan ./start.sh dari galera-cluster-dist.",
                docs_path.display()
            )
        } else {
            format!(
                "{} file — folder: {}",
                self.doc_entries.len(),
                docs_path.display()
            )
        };
        self.screen = Screen::DocsList;
    }

    pub fn open_doc_at_selection(&mut self) {
        let idx = self
            .docs_list_state
            .selected()
            .unwrap_or(self.doc_index);
        self.doc_index = idx;
        self.open_doc(idx);
    }

    pub fn open_doc(&mut self, index: usize) {
        if let Some(entry) = self.doc_entries.get(index) {
            self.doc_title = entry.title.clone();
            self.doc_lines = docs::read_doc(&entry.path).unwrap_or_else(|e| {
                vec![format!("Gagal baca: {e:#}")]
            });
            self.doc_scroll = 0;
            self.screen = Screen::DocView;
        }
    }

    pub fn start_job(&mut self, job: AnsibleJob) {
        self.running = true;
        self.output_title = job.label().into();
        self.output_lines = vec![format!("Menjalankan: {}...", job.label())];
        self.output_scroll = 0;
        self.screen = Screen::Output;
        let paths = self.paths.clone();
        self.job_rx = Some(ansible::run_job_async(paths, job));
    }

    pub fn poll_job(&mut self) {
        let done = if let Some(rx) = &self.job_rx {
            if let Ok(result) = rx.try_recv() {
                match result {
                    Ok(lines) => self.output_lines = lines,
                    Err(e) => self.output_lines = vec![format!("ERROR: {e:#}")],
                }
                self.running = false;
                self.job_rx = None;
                true
            } else {
                false
            }
        } else {
            false
        };
        if done {
            self.output_scroll = self.output_scroll.saturating_sub(0);
            if self.output_title.contains("Status") || self.output_title.contains("Dashboard") {
                self.parse_status_from_output();
            }
        }
    }

    pub fn refresh_dashboard(&mut self) {
        self.status_message = "Refreshing...".into();
        self.start_job(AnsibleJob::ClusterStatus);
        self.output_title = "Dashboard Status".into();
    }

    fn parse_status_from_output(&mut self) {
        self.status_rows.clear();
        if let Ok(inv) = InventoryRoot::load(&self.paths) {
            self.inventory = inv;
        }
        for host in self.inventory.all_hosts() {
            self.status_rows.push(NodeStatus {
                host: host.clone(),
                ssh: "-".into(),
                mariadb: "-".into(),
                cluster_size: "-".into(),
                state: "-".into(),
            });
        }
        // Parse simple patterns from ansible output
        for line in &self.output_lines {
            for row in &mut self.status_rows {
                if line.contains(&row.host.name) || line.contains(&row.host.ip) {
                    if line.contains("SUCCESS") || line.contains("pong") {
                        row.ssh = "OK".into();
                    }
                    if line.contains("active") {
                        row.mariadb = "active".into();
                    }
                    if line.contains("inactive") || line.contains("failed") {
                        row.mariadb = "down".into();
                    }
                    if line.contains("Synced") {
                        row.state = "Synced".into();
                    }
                }
                if line.chars().all(|c| c.is_ascii_digit()) && line.len() <= 2 {
                    row.cluster_size = line.clone();
                }
            }
        }
        self.status_message = format!(
            "Updated {} | {}",
            chrono::Local::now().format("%H:%M:%S"),
            self.paths.root.display()
        );
    }

    pub fn open_editor(&mut self, path: std::path::PathBuf, title: &str) -> Result<()> {
        let content = if path.is_file() {
            ansible::read_text_file(&path)?
        } else {
            String::new()
        };
        self.editor = TextArea::from(content.lines());
        self.editor_path = path.to_string_lossy().into_owned();
        self.editor_title = title.to_string();
        self.screen = Screen::Editor;
        Ok(())
    }

    pub fn save_editor(&mut self) -> Result<()> {
        let content = self.editor.lines().join("\n");
        ansible::write_text_file(
            std::path::Path::new(&self.editor_path),
            &(content + "\n"),
        )?;
        self.inventory = InventoryRoot::load(&self.paths)?;
        self.error_message = Some(format!("Disimpan: {}", self.editor_path));
        Ok(())
    }

    pub fn init_add_node(&mut self) {
        let name = self.inventory.next_db_node_name();
        let user = self
            .inventory
            .db_nodes()
            .first()
            .map(|(_, h)| h.ansible_user.clone())
            .unwrap_or_else(|| "vta".into());
        self.add_node = AddNodeForm {
            hostname: name,
            ip: String::new(),
            user,
            port: "22".into(),
            field: 0,
        };
        self.add_node_message = "Isi IP node baru. Enter=field berikutnya, Ctrl+S=simpan".into();
        self.screen = Screen::AddNode;
    }

    pub fn save_add_node(&mut self) -> Result<()> {
        let port: u16 = self.add_node.port.parse().unwrap_or(22);
        if self.add_node.ip.is_empty() {
            anyhow::bail!("IP wajib diisi");
        }
        self.inventory.add_db_node(
            &self.add_node.hostname,
            &self.add_node.ip,
            &self.add_node.user,
            port,
        );
        self.inventory.save(&self.paths)?;
        self.add_node_message = format!("Node {} ditambahkan ke inventory.yml", self.add_node.hostname);
        Ok(())
    }

    pub fn request_confirm(&mut self, job: AnsibleJob) {
        let label = job.label().to_string();
        self.pending_job = Some(job);
        self.confirm_message = format!(
            "Jalankan \"{label}\"?\nEnter=Ya  Esc=Batal"
        );
        self.screen = Screen::Confirm;
    }
}
