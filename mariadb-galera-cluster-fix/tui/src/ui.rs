mod draw;

use anyhow::Result;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use std::io;
use std::time::Duration;

use tui_textarea::Input;

use crate::ansible::AnsibleJob;
use crate::app::{App, MenuAction, Screen, MENU};

pub use draw::draw;

pub fn run() -> Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = App::new()?;
    let result = run_loop(&mut terminal, &mut app);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    result
}

fn run_loop(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
) -> Result<()> {
    loop {
        app.poll_job();
        terminal.draw(|f| draw(f, app))?;

        if event::poll(Duration::from_millis(120))? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                if handle_key(app, key.code, key.modifiers) {
                    break;
                }
            }
        }

        if app.should_quit {
            break;
        }
    }
    Ok(())
}

fn handle_key(app: &mut App, code: KeyCode, modifiers: KeyModifiers) -> bool {
    match app.screen {
        Screen::WelcomeSetup => handle_welcome(app, code),
        Screen::MainMenu => handle_main_menu(app, code, modifiers),
        Screen::Dashboard => handle_dashboard(app, code),
        Screen::Output => handle_output(app, code),
        Screen::Editor => handle_editor(app, code, modifiers),
        Screen::AddNode => handle_add_node(app, code, modifiers),
        Screen::Confirm => handle_confirm(app, code),
        Screen::DocsList => handle_docs_list(app, code),
        Screen::DocView => handle_doc_view(app, code),
    }
}

fn handle_welcome(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::Enter => {
            app.screen = Screen::MainMenu;
        }
        KeyCode::Char('d') | KeyCode::Char('D') => app.open_docs_list(),
        KeyCode::Char('r') | KeyCode::Char('R') => app.refresh_setup(),
        KeyCode::Char('q') => {
            app.should_quit = true;
            return true;
        }
        _ => {}
    }
    false
}

fn handle_docs_list(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::Up => {
            app.docs_list_state.select_previous();
            if let Some(i) = app.docs_list_state.selected() {
                app.doc_index = i;
            }
        }
        KeyCode::Down => {
            app.docs_list_state.select_next();
            if let Some(i) = app.docs_list_state.selected() {
                app.doc_index = i;
            }
        }
        KeyCode::Enter => {
            if !app.doc_entries.is_empty() {
                app.open_doc_at_selection();
            }
        }
        KeyCode::Esc | KeyCode::Char('q') => {
            app.screen = if app.setup_check.is_complete() {
                Screen::MainMenu
            } else {
                Screen::WelcomeSetup
            };
        }
        _ => {}
    }
    false
}

fn handle_doc_view(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::PageUp | KeyCode::Char('k') => {
            app.doc_scroll = app.doc_scroll.saturating_sub(15);
        }
        KeyCode::PageDown | KeyCode::Char('j') => {
            let max = app.doc_lines.len().saturating_sub(1);
            app.doc_scroll = (app.doc_scroll + 15).min(max);
        }
        KeyCode::Up => app.doc_scroll = app.doc_scroll.saturating_sub(1),
        KeyCode::Down => {
            let max = app.doc_lines.len().saturating_sub(1);
            if app.doc_scroll < max {
                app.doc_scroll += 1;
            }
        }
        KeyCode::Esc | KeyCode::Char('q') => app.screen = Screen::DocsList,
        _ => {}
    }
    false
}

fn handle_main_menu(app: &mut App, code: KeyCode, modifiers: KeyModifiers) -> bool {
    match code {
        KeyCode::Char('q') => {
            app.should_quit = true;
            return true;
        }
        KeyCode::Char('d') | KeyCode::Char('D') => {
            app.open_docs_list();
        }
        KeyCode::Up => {
            if app.menu_index > 0 {
                app.menu_index -= 1;
            }
        }
        KeyCode::Down => {
            if app.menu_index + 1 < MENU.len() {
                app.menu_index += 1;
            }
        }
        KeyCode::Enter => {
            let item = &MENU[app.menu_index];
            match item.action {
                MenuAction::Quit => {
                    app.should_quit = true;
                    return true;
                }
                MenuAction::ShowWelcome => {
                    app.refresh_setup();
                    app.screen = Screen::WelcomeSetup;
                }
                MenuAction::ShowDocs => app.open_docs_list(),
                MenuAction::ShowDashboard => {
                    app.screen = Screen::Dashboard;
                    app.refresh_dashboard();
                }
                MenuAction::RunJob | MenuAction::SetupCheck => {
                    if let Some(job) = &item.job {
                        if matches!(job, AnsibleJob::ResetAndDeploy | AnsibleJob::StopCluster) {
                            app.request_confirm(job.clone());
                        } else {
                            app.start_job(job.clone());
                        }
                    }
                }
                MenuAction::EditInventory => {
                    let p = app.paths.inventory();
                    let _ = app.open_editor(p, "Edit inventory.yml");
                }
                MenuAction::EditMariadbVars => {
                    let p = app.paths.mariadb_vars();
                    let _ = app.open_editor(p, "Edit mariadb.yml tuning");
                }
                MenuAction::AddNode => app.init_add_node(),
            }
        }
        KeyCode::Esc => {}
        _ => {}
    }
    false
}

fn handle_dashboard(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::Char('r') | KeyCode::Char('R') => app.refresh_dashboard(),
        KeyCode::Esc | KeyCode::Char('q') => app.screen = Screen::MainMenu,
        _ => {}
    }
    false
}

fn handle_output(app: &mut App, code: KeyCode) -> bool {
    if app.running {
        return false;
    }
    match code {
        KeyCode::PageUp | KeyCode::Char('k') => {
            app.output_scroll = app.output_scroll.saturating_sub(10);
        }
        KeyCode::PageDown | KeyCode::Char('j') => {
            let max = app.output_lines.len().saturating_sub(1);
            app.output_scroll = (app.output_scroll + 10).min(max);
        }
        KeyCode::Up => app.output_scroll = app.output_scroll.saturating_sub(1),
        KeyCode::Down => {
            let max = app.output_lines.len().saturating_sub(1);
            if app.output_scroll < max {
                app.output_scroll += 1;
            }
        }
        KeyCode::Esc | KeyCode::Enter | KeyCode::Char('q') => app.screen = Screen::MainMenu,
        _ => {}
    }
    false
}

fn handle_editor(app: &mut App, code: KeyCode, modifiers: KeyModifiers) -> bool {
    if code == KeyCode::Esc {
        app.screen = Screen::MainMenu;
        return false;
    }
    if code == KeyCode::Char('s') && modifiers.contains(KeyModifiers::CONTROL) {
        match app.save_editor() {
            Ok(()) => {
                app.error_message = Some(format!("Disimpan: {}", app.editor_path));
                app.screen = Screen::MainMenu;
            }
            Err(e) => app.error_message = Some(format!("Gagal simpan: {e:#}")),
        }
        return false;
    }
    use crossterm::event::KeyEvent as KE;
    let key = KE::new(code, modifiers);
    app.editor.input(Input::from(key));
    false
}

fn handle_add_node(app: &mut App, code: KeyCode, modifiers: KeyModifiers) -> bool {
    if code == KeyCode::Esc {
        app.screen = Screen::MainMenu;
        return false;
    }
    if code == KeyCode::Char('s') && modifiers.contains(KeyModifiers::CONTROL) {
        match app.save_add_node() {
            Ok(()) => {
                app.error_message = Some(app.add_node_message.clone());
                app.screen = Screen::MainMenu;
            }
            Err(e) => app.add_node_message = format!("Error: {e:#}"),
        }
        return false;
    }
    if code == KeyCode::Tab || code == KeyCode::Enter {
        app.add_node.field = (app.add_node.field + 1) % 4;
        return false;
    }
    match code {
        KeyCode::Backspace => {
            current_add_field(app).pop();
        }
        KeyCode::Char(c) => current_add_field(app).push(c),
        _ => {}
    }
    false
}

fn current_add_field(app: &mut App) -> &mut String {
    match app.add_node.field {
        0 => &mut app.add_node.hostname,
        1 => &mut app.add_node.ip,
        2 => &mut app.add_node.user,
        _ => &mut app.add_node.port,
    }
}

fn handle_confirm(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::Enter => {
            if let Some(job) = app.pending_job.take() {
                app.start_job(job);
            }
        }
        KeyCode::Esc | KeyCode::Char('n') => {
            app.pending_job = None;
            app.screen = Screen::MainMenu;
        }
        _ => {}
    }
    false
}
