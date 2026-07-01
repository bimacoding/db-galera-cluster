use ratatui::prelude::*;
use ratatui::widgets::*;

use crate::app::{App, Screen, MENU};

pub fn draw(f: &mut Frame, app: &mut App) {
    match app.screen {
        Screen::WelcomeSetup => draw_welcome(f, app),
        Screen::MainMenu => draw_main(f, app),
        Screen::Dashboard => draw_dashboard(f, app),
        Screen::Output => draw_output(f, app),
        Screen::Editor => draw_editor(f, app),
        Screen::AddNode => draw_add_node(f, app),
        Screen::Confirm => draw_confirm(f, app),
        Screen::DocsList => draw_docs_list(f, app),
        Screen::DocView => draw_doc_view(f, app),
    }
}

fn draw_welcome(f: &mut Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(2)])
        .split(f.area());

    let title = if app.setup_check.is_complete() {
        " Setup Selesai — siap deploy ".to_string()
    } else {
        " Setup Awal — baca sebelum deploy ".to_string()
    };
    f.render_widget(header(title), chunks[0]);

    let lines: Vec<Line> = app
        .welcome_lines
        .iter()
        .map(|l| {
            let style = if l.starts_with("  [v]") {
                Style::default().fg(Color::Green)
            } else if l.starts_with("  [ ]") {
                Style::default().fg(Color::Yellow)
            } else if l.starts_with("PANDUAN") {
                Style::default().add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            Line::from(Span::styled(l.clone(), style))
        })
        .collect();

    f.render_widget(
        Paragraph::new(lines).block(
            Block::default()
                .title(format!(" {}", app.paths.root.display()))
                .borders(Borders::ALL),
        ),
        chunks[1],
    );
    f.render_widget(
        footer("Enter=menu  d=dokumentasi  r=refresh  q=keluar".to_string()),
        chunks[2],
    );
}

fn draw_docs_list(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(2)])
        .split(f.area());

    f.render_widget(header(" Dokumentasi ".to_string()), chunks[0]);

    if app.doc_entries.is_empty() {
        f.render_widget(
            Paragraph::new(app.docs_hint.clone())
                .wrap(Wrap { trim: true })
                .block(Block::default().borders(Borders::ALL).title(" docs/ ")),
            chunks[1],
        );
    } else {
        let items: Vec<ListItem> = app
            .doc_entries
            .iter()
            .map(|d| ListItem::new(format!("  {} — {}", d.name, d.title)))
            .collect();
        let list = List::new(items)
            .block(
                Block::default()
                    .title(format!(" {} ", app.docs_hint))
                    .borders(Borders::ALL),
            )
            .highlight_style(
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            )
            .highlight_symbol("▸ ");
        f.render_stateful_widget(list, chunks[1], &mut app.docs_list_state);
    }
    f.render_widget(
        footer("↑↓ pilih  Enter=baca  Esc=kembali".to_string()),
        chunks[2],
    );
}

fn draw_doc_view(f: &mut Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(2)])
        .split(f.area());

    f.render_widget(
        header(format!(" {} ({}/{}) ", app.doc_title, app.doc_index + 1, app.doc_entries.len())),
        chunks[0],
    );

    let visible = chunks[1].height.saturating_sub(2) as usize;
    let text: String = app
        .doc_lines
        .iter()
        .skip(app.doc_scroll)
        .take(visible)
        .cloned()
        .collect::<Vec<_>>()
        .join("\n");

    f.render_widget(
        Paragraph::new(text)
            .wrap(Wrap { trim: false })
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(format!(" baris {}+ ", app.doc_scroll + 1)),
            ),
        chunks[1],
    );
    f.render_widget(
        footer(format!(
            "↑↓/PgUp/PgDn scroll ({}/{})  Esc=kembali",
            app.doc_scroll.saturating_add(1),
            app.doc_lines.len()
        )),
        chunks[2],
    );
}

fn header(title: String) -> Paragraph<'static> {
    Paragraph::new(title)
        .style(
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(Color::DarkGray)),
        )
}

fn footer(text: String) -> Paragraph<'static> {
    Paragraph::new(text).style(Style::default().fg(Color::DarkGray))
}

fn draw_main(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(10),
            Constraint::Length(3),
            Constraint::Length(2),
        ])
        .split(f.area());

    f.render_widget(
        header(" Galera TUI — MariaDB Galera Cluster Controller ".to_string()),
        chunks[0],
    );

    let items: Vec<ListItem> = MENU
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let style = if i == app.menu_index {
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Cyan)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            ListItem::new(format!("  {}  {}", m.label, m.description)).style(style)
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .title(format!(" Menu  |  {}", app.paths.root.display()))
            .borders(Borders::ALL),
    );
    f.render_widget(list, chunks[1]);

    // Host summary
    let hosts: Vec<Line> = app
        .inventory
        .all_hosts()
        .iter()
        .map(|h| {
            Line::from(format!(
                "  {} ({}) — {}@{}:{}",
                h.name, h.group, h.user, h.ip, h.port
            ))
        })
        .collect();
    f.render_widget(
        Paragraph::new(hosts).block(
            Block::default()
                .title(" Hosts ")
                .borders(Borders::ALL),
        ),
        chunks[2],
    );

    let hint = if let Some(err) = &app.error_message {
        format!("↑↓ navigasi  Enter pilih  q keluar  |  {err}")
    } else {
        "↑↓ navigasi  Enter pilih  q keluar".into()
    };
    f.render_widget(footer(hint), chunks[3]);
}

fn draw_dashboard(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(2)])
        .split(f.area());

    f.render_widget(header(" Dashboard / Cluster Status ".to_string()), chunks[0]);

    let header_row = Row::new(vec!["Host", "IP", "SSH", "MariaDB", "Size", "State"]);
    let rows: Vec<Row> = app
        .status_rows
        .iter()
        .map(|r| {
            Row::new(vec![
                r.host.name.clone(),
                r.host.ip.clone(),
                r.ssh.clone(),
                r.mariadb.clone(),
                r.cluster_size.clone(),
                r.state.clone(),
            ])
        })
        .collect();

    let table = Table::new(rows, [
        Constraint::Length(18),
        Constraint::Length(16),
        Constraint::Length(6),
        Constraint::Length(10),
        Constraint::Length(6),
        Constraint::Length(10),
    ])
    .header(header_row.style(Style::default().add_modifier(Modifier::BOLD)))
    .block(
        Block::default()
            .title(format!(" {} ", app.status_message))
            .borders(Borders::ALL),
    );

    f.render_widget(table, chunks[1]);
    f.render_widget(
        footer("r refresh  Esc kembali  (status di-update dari output Ansible)".to_string()),
        chunks[2],
    );
}

fn draw_output(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(2)])
        .split(f.area());

    let title = if app.running {
        format!(" {} [RUNNING...] ", app.output_title)
    } else {
        format!(" {} ", app.output_title)
    };
    f.render_widget(header(title), chunks[0]);

    let visible_height = chunks[1].height.saturating_sub(2) as usize;
    let lines: Vec<Line> = app
        .output_lines
        .iter()
        .skip(app.output_scroll)
        .take(visible_height)
        .map(|l| {
            let style = if l.contains("ERROR") || l.contains("FAILED") {
                Style::default().fg(Color::Red)
            } else if l.contains("SUCCESS") || l.contains("OK") {
                Style::default().fg(Color::Green)
            } else {
                Style::default()
            };
            Line::from(Span::styled(l.clone(), style))
        })
        .collect();

    f.render_widget(
        Paragraph::new(lines).block(Block::default().borders(Borders::ALL)),
        chunks[1],
    );

    let hint = if app.running {
        "Menunggu Ansible selesai..."
    } else {
        "PgUp/PgDn scroll  Esc/Enter kembali"
    };
    f.render_widget(footer(hint.to_string()), chunks[2]);
}

fn draw_editor(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(5), Constraint::Length(2)])
        .split(f.area());

    f.render_widget(
        header(format!(" {} — {} ", app.editor_title, app.editor_path)),
        chunks[0],
    );

    app.editor.set_block(
        Block::default()
            .borders(Borders::ALL)
            .title(" Editor "),
    );
    f.render_widget(&app.editor, chunks[1]);
    f.render_widget(footer("Ctrl+S simpan  Esc batal".to_string()), chunks[2]);
}

fn draw_add_node(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(8), Constraint::Length(2)])
        .split(f.area());

    f.render_widget(header(" Tambah Node Database ".to_string()), chunks[0]);

    let fields = [
        ("Hostname", &app.add_node.hostname, app.add_node.field == 0),
        ("IP Address", &app.add_node.ip, app.add_node.field == 1),
        ("SSH User", &app.add_node.user, app.add_node.field == 2),
        ("SSH Port", &app.add_node.port, app.add_node.field == 3),
    ];

    let mut lines = vec![Line::from(app.add_node_message.clone()), Line::from("")];
    for (label, val, active) in fields {
        let style = if active {
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
        } else {
            Style::default()
        };
        lines.push(Line::from(vec![
            Span::styled(format!("{label}: "), style),
            Span::raw(val.clone()),
            if active {
                Span::styled("_", Style::default().fg(Color::Yellow))
            } else {
                Span::raw("")
            },
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(
        "Setelah simpan, jalankan Deploy atau Start Cluster agar node join.",
    ));

    f.render_widget(
        Paragraph::new(lines).block(Block::default().borders(Borders::ALL)),
        chunks[1],
    );
    f.render_widget(
        footer("Tab/Enter field berikutnya  Ctrl+S simpan  Esc batal".to_string()),
        chunks[2],
    );
}

fn draw_confirm(f: &mut Frame, app: &mut App) {
    let area = centered_rect(60, 30, f.area());
    f.render_widget(Clear, area);
    f.render_widget(
        Paragraph::new(app.confirm_message.clone())
            .block(
                Block::default()
                    .title(" Konfirmasi ")
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(Color::Yellow)),
            )
            .wrap(Wrap { trim: true })
            .alignment(Alignment::Center),
        area,
    );
}

fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}
