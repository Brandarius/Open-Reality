use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph};

use crate::state::{AppState, BuildMode, BuildStatus, ProcessStatus};
use crate::ui::log_panel;

pub fn render(frame: &mut Frame, state: &AppState, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(28), Constraint::Min(0)])
        .split(area);

    // Left panel
    let left_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(0),
            Constraint::Length(6),
        ])
        .split(chunks[0]);

    // Mode selector bar
    let mode_spans: Vec<Span> = BuildMode::ALL
        .iter()
        .map(|m| {
            if *m == state.build_mode {
                Span::styled(
                    format!(" {} ", m.label()),
                    Style::default().fg(Color::Black).bg(Color::Cyan).bold(),
                )
            } else {
                Span::styled(
                    format!(" {} ", m.label()),
                    Style::default().fg(Color::DarkGray),
                )
            }
        })
        .collect();
    let mode_bar = Paragraph::new(Line::from(mode_spans))
        .block(Block::default().borders(Borders::ALL).title(" Mode "));
    frame.render_widget(mode_bar, left_chunks[0]);

    // Main selector area
    match state.build_mode {
        BuildMode::Backend => {
            let items: Vec<ListItem> = state
                .backends
                .iter()
                .enumerate()
                .map(|(i, bs)| {
                    let marker = if i == state.build_selected {
                        "> "
                    } else {
                        "  "
                    };
                    let style = match &bs.build_status {
                        BuildStatus::Built { .. } | BuildStatus::NotNeeded => {
                            Style::default().fg(Color::Green)
                        }
                        BuildStatus::Building => Style::default().fg(Color::Yellow),
                        BuildStatus::BuildFailed { .. } => Style::default().fg(Color::Red),
                        BuildStatus::NotBuilt => Style::default().fg(Color::White),
                    };
                    ListItem::new(format!("{marker}{}", bs.backend.label())).style(style)
                })
                .collect();

            let list = List::new(items).block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(" Backend ")
                    .border_style(Style::default().fg(Color::Cyan)),
            );
            frame.render_widget(list, left_chunks[1]);
        }
        other => {
            let info_lines = match other {
                BuildMode::Desktop => vec![
                    Line::raw("Build standalone executable"),
                    Line::raw(""),
                    Line::raw("CLI: orcli build desktop"),
                    Line::raw("  <entry.jl> [--platform]"),
                    Line::raw("  [--output] [--release]"),
                ],
                BuildMode::Web => vec![
                    Line::raw("Build for web (WASM+ORSB)"),
                    Line::raw(""),
                    Line::raw("CLI: orcli build web"),
                    Line::raw("  <scene.jl> [--output]"),
                    Line::raw("  [--release]"),
                ],
                BuildMode::Mobile => vec![
                    Line::raw("Build for mobile (WebView)"),
                    Line::raw(""),
                    Line::raw("CLI: orcli build mobile"),
                    Line::raw("  <scene.jl> --platform"),
                    Line::raw("  <android|ios> [--output]"),
                ],
                BuildMode::Export => vec![
                    Line::raw("Export scene to file"),
                    Line::raw(""),
                    Line::raw("CLI: orcli export"),
                    Line::raw("  <scene.jl> -o <out>"),
                    Line::raw("  [-f orsb|gltf]"),
                    Line::raw("  [--physics]"),
                ],
                BuildMode::Package => vec![
                    Line::raw("Package for distribution"),
                    Line::raw(""),
                    Line::raw("CLI: orcli package desktop"),
                    Line::raw("  or: orcli package web"),
                ],
                _ => vec![],
            };
            let info = Paragraph::new(info_lines).block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(format!(" {} ", other.label()))
                    .border_style(Style::default().fg(Color::Cyan)),
            );
            frame.render_widget(info, left_chunks[1]);
        }
    }

    // Hint box
    let process_hint = match &state.build_process {
        ProcessStatus::Running => "Building...",
        ProcessStatus::Finished { exit_code } => {
            if *exit_code == Some(0) {
                "Build OK"
            } else {
                "Build FAILED"
            }
        }
        ProcessStatus::Idle => "Idle",
        ProcessStatus::Failed { .. } => "Error",
    };

    let hints = vec![
        Line::styled(format!("Status: {process_hint}"), Style::default().bold()),
        Line::raw(""),
        Line::raw("[a/d/w/m/x/p] Switch mode"),
        Line::raw("[Enter/b] Build"),
        Line::raw("[g/G] Top/Bottom"),
    ];
    let hint_box = Paragraph::new(hints).block(Block::default().borders(Borders::ALL));
    frame.render_widget(hint_box, left_chunks[2]);

    // Right: build log
    log_panel::render(frame, &state.build_log, chunks[1], " Build Log ");
}
