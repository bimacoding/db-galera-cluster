mod ansible;
mod app;
mod docs;
mod inventory;
mod paths;
mod ui;

fn main() {
    if let Err(e) = ui::run() {
        eprintln!("galera-tui error: {e:#}");
        std::process::exit(1);
    }
}
