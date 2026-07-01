use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;

use anyhow::{Context, Result};

use crate::paths::ClusterPaths;

#[derive(Debug, Clone)]
pub enum AnsibleJob {
    PingAll,
    ClusterStatus,
    StartCluster,
    StopCluster,
    Deploy,
    ResetAndDeploy,
    ApplyConfig,
    CheckNetwork,
    SetupCheck,
    Custom { label: String, program: String, args: Vec<String> },
}

impl AnsibleJob {
    pub fn label(&self) -> &str {
        match self {
            Self::PingAll => "Ping All Hosts",
            Self::ClusterStatus => "Cluster Status",
            Self::StartCluster => "Start Cluster",
            Self::StopCluster => "Stop Cluster",
            Self::Deploy => "Deploy Playbook",
            Self::ResetAndDeploy => "Reset + Full Deploy",
            Self::ApplyConfig => "Apply Config",
            Self::CheckNetwork => "Check Network",
            Self::SetupCheck => "Setup / Prerequisites",
            Self::Custom { label, .. } => label,
        }
    }
}

pub fn ansible_bin(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    }
}

pub fn run_job(paths: &ClusterPaths, job: AnsibleJob) -> Result<Vec<String>> {
    match job {
        AnsibleJob::ResetAndDeploy => {
            let reset_out = run_reset(paths)?;
            let playbook = ansible_bin("ansible-playbook");
            let mut deploy_args = vec![
                "--fork=1".into(),
                paths.deploy_playbook().to_string_lossy().into_owned(),
                "-e".into(),
                format!("@{}", paths.haproxy_vars().display()),
            ];
            let deploy_out = run_capture(&playbook, &deploy_args, Some(&paths.root))?;
            let mut combined = reset_out;
            combined.push("--- DEPLOY ---".into());
            combined.extend(deploy_out);
            Ok(combined)
        }
        AnsibleJob::SetupCheck => check_prerequisites(paths),
        _ => {
            let (program, args) = build_command(paths, &job)?;
            run_capture(&program, &args, Some(&paths.root))
        }
    }
}

pub fn run_job_async(
    paths: ClusterPaths,
    job: AnsibleJob,
) -> mpsc::Receiver<Result<Vec<String>>> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = run_job(&paths, job);
        let _ = tx.send(result);
    });
    rx
}

fn build_command(paths: &ClusterPaths, job: &AnsibleJob) -> Result<(String, Vec<String>)> {
    let ansible = ansible_bin("ansible");
    let playbook = ansible_bin("ansible-playbook");
    let haproxy_extra = vec![
        "-e".into(),
        format!("@{}", paths.haproxy_vars().display()),
    ];

    match job {
        AnsibleJob::PingAll => Ok((
            ansible,
            vec!["all".into(), "-m".into(), "ping".into()],
        )),
        AnsibleJob::ClusterStatus => {
            let pw = paths.extract_playbook_passwords()?.0;
            Ok((
                ansible,
                vec![
                    "mariadb_cluster".into(),
                    "-m".into(),
                    "shell".into(),
                    "--become".into(),
                    "-a".into(),
                    format!(
                        "echo -n \"{{{{ inventory_hostname }}}}: \"; \
                         systemctl is-active mariadb 2>&1; \
                         mysql -uroot -p{pw} -N -e \
                         \"SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS \
                         WHERE VARIABLE_NAME='wsrep_cluster_size' LIMIT 1; \
                         SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS \
                         WHERE VARIABLE_NAME='wsrep_local_state_comment' LIMIT 1;\" 2>&1"
                    ),
                ],
            ))
        }
        AnsibleJob::StartCluster => {
            let mut args = vec![
                "--fork=1".into(),
                paths.deploy_playbook().to_string_lossy().into_owned(),
            ];
            args.extend(haproxy_extra.clone());
            args.extend(["--tags".into(), "start_cluster".into()]);
            Ok((playbook, args))
        }
        AnsibleJob::StopCluster => {
            let mut args = vec![
                "--fork=1".into(),
                paths.deploy_playbook().to_string_lossy().into_owned(),
            ];
            args.extend(haproxy_extra.clone());
            args.extend(["--tags".into(), "stop_cluster".into()]);
            Ok((playbook, args))
        }
        AnsibleJob::Deploy => {
            let mut args = vec![
                "--fork=1".into(),
                paths.deploy_playbook().to_string_lossy().into_owned(),
            ];
            args.extend(haproxy_extra.clone());
            Ok((playbook, args))
        }
        AnsibleJob::ApplyConfig => {
            let (root_pw, sst_pw) = paths.extract_playbook_passwords()?;
            Ok((
                playbook,
                vec![
                    paths.apply_playbook().to_string_lossy().into_owned(),
                    format!("-emariadb_root_password={root_pw}"),
                    format!("-emariadb_sst_password={sst_pw}"),
                ],
            ))
        }
        AnsibleJob::CheckNetwork => Ok((
            ansible,
            vec![
                "all".into(),
                "-m".into(),
                "ping".into(),
                "-f".into(),
                "4".into(),
            ],
        )),
        AnsibleJob::SetupCheck | AnsibleJob::ResetAndDeploy => {
            unreachable!("handled in run_job")
        }
        AnsibleJob::Custom { program, args, .. } => Ok((program.clone(), args.clone())),
    }
}

fn run_reset(paths: &ClusterPaths) -> Result<Vec<String>> {
    let ansible = ansible_bin("ansible");
    let bash_extra = vec!["-e".into(), "ansible_shell_executable=/bin/bash".into()];
    let mut out = Vec::new();
    out.push("[RESET] Ping all".into());
    out.extend(run_capture(&ansible, &["all".into(), "-m".into(), "ping".into()], Some(&paths.root))?);

    let stop_script = r"
systemctl unmask mariadb 2>/dev/null || true
timeout 20 systemctl stop mariadb 2>/dev/null || true
systemctl kill -s SIGKILL mariadb 2>/dev/null || true
pkill -9 mariadbd 2>/dev/null || true
pkill -9 -f wsrep_sst 2>/dev/null || true
systemctl reset-failed mariadb 2>/dev/null || true
pgrep mariadbd >/dev/null 2>&1 && echo STILL_RUNNING || echo STOPPED
";
    out.push("[RESET] Stop MariaDB".into());
    let mut stop_args = vec![
        "mariadb_cluster".into(),
        "-m".into(),
        "shell".into(),
        "--become".into(),
        "-a".into(),
        stop_script.into(),
    ];
    stop_args.extend(bash_extra.clone());
    out.extend(run_capture(&ansible, &stop_args, Some(&paths.root))?);

    out.push("[RESET] Wipe slave node 2 & 3".into());
    let mut wipe_args = vec![
        "mariadb_node_2,mariadb_node_3".into(),
        "-m".into(),
        "shell".into(),
        "--become".into(),
        "-a".into(),
        "find /var/lib/mysql -mindepth 1 -maxdepth 1 -exec rm -rf {} + && echo WIPED".into(),
    ];
    wipe_args.extend(bash_extra.clone());
    out.extend(run_capture(&ansible, &wipe_args, Some(&paths.root))?);

    out.push("[RESET] safe_to_bootstrap primary".into());
    let grastate_script = r#"
GRASTATE="/var/lib/mysql/grastate.dat"
if [ -f "${GRASTATE}" ]; then
  sed -i "s/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/" "${GRASTATE}"
else
  cat > "${GRASTATE}" <<EOF
# GALERA saved state
version: 2.1
uuid:    00000000-0000-0000-0000-000000000000
seqno:   -1
safe_to_bootstrap: 1
EOF
fi
chown mysql:mysql "${GRASTATE}"
chmod 660 "${GRASTATE}"
cat "${GRASTATE}"
"#;
    let mut bootstrap_args = vec![
        "mariadb_node_1".into(),
        "-m".into(),
        "shell".into(),
        "--become".into(),
        "-a".into(),
        grastate_script.into(),
    ];
    bootstrap_args.extend(bash_extra);
    out.extend(run_capture(&ansible, &bootstrap_args, Some(&paths.root))?);
    out.push("[RESET] Selesai".into());
    Ok(out)
}

fn check_prerequisites(paths: &ClusterPaths) -> Result<Vec<String>> {
    let mut lines = vec!["=== Setup / Prerequisites ===".into()];

    for bin in ["ansible", "ansible-playbook", "ansible-galaxy"] {
        let name = ansible_bin(bin);
        let ok = Command::new(&name).arg("--version").output().is_ok();
        lines.push(format!(
            "{}: {}",
            bin,
            if ok { "OK" } else { "MISSING — install ansible" }
        ));
    }

    let files = [
        ("inventory.yml", paths.inventory()),
        ("deploy-mariadb-cluster.yml", paths.deploy_playbook()),
        ("group_vars_haproxy.yml", paths.haproxy_vars()),
        ("group_vars/all/mariadb.yml", paths.mariadb_vars()),
        ("group_vars/all/secrets.yml", paths.secrets()),
    ];
    for (label, p) in files {
        lines.push(format!("{label}: {}", if p.is_file() { "OK" } else { "MISSING" }));
    }

    if paths.secrets().is_file() {
        lines.push("secrets.yml: ada (sudo password)".into());
    } else {
        lines.push("secrets.yml: MISSING — cp secrets.yml.example & isi sudo password".into());
    }

    Ok(lines)
}

fn run_capture(program: &str, args: &[String], cwd: Option<&Path>) -> Result<Vec<String>> {
    let mut cmd = Command::new(program);
    cmd.args(args);
    if let Some(c) = cwd {
        cmd.current_dir(c);
    }
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

    let mut child = cmd.spawn().with_context(|| format!("spawn {program}"))?;
    let stderr = child.stderr.take();
    let stdout = child.stdout.take();

    let mut lines = Vec::new();
    lines.push(format!("$ {program} {}", args.join(" ")));

    if let Some(out) = stdout {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            lines.push(line);
        }
    }
    if let Some(err) = stderr {
        for line in BufReader::new(err).lines().map_while(Result::ok) {
            lines.push(format!("[stderr] {line}"));
        }
    }

    let status = child.wait().context("wait process")?;
    lines.push(format!(
        "--- exit code: {} ---",
        status.code().unwrap_or(-1)
    ));
    Ok(lines)
}

pub fn read_text_file(path: &Path) -> Result<String> {
    std::fs::read_to_string(path).with_context(|| format!("baca {}", path.display()))
}

pub fn write_text_file(path: &Path, content: &str) -> Result<()> {
    std::fs::write(path, content).with_context(|| format!("tulis {}", path.display()))
}
