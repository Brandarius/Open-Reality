use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::state::{AppState, ProcessStatus};
use crate::ui::log_panel;

pub fn render(frame: &mut Frame, state: &AppState, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(30), Constraint::Min(0)])
        .split(area);

    // Left panel: info + hints
    let process_hint = match &state.test_process {
        ProcessStatus::Running => "Running...",
        ProcessStatus::Finished { exit_code } => {
            if *exit_code == Some(0) {
                "PASSED"
            } else {
                "FAILED"
            }
        }
        ProcessStatus::Idle => "Idle",
        ProcessStatus::Failed { .. } => "Error",
    };

    let status_style = match &state.test_process {
        ProcessStatus::Finished { exit_code } if *exit_code == Some(0) => {
            Style::default().fg(Color::Green).bold()
        }
        ProcessStatus::Finished { .. } | ProcessStatus::Failed { .. } => {
            Style::default().fg(Color::Red).bold()
        }
        ProcessStatus::Running => Style::default().fg(Color::Yellow).bold(),
        _ => Style::default().bold(),
    };

    let info = vec![
        Line::styled("Julia Test Suite", Style::default().bold().fg(Color::Cyan)),
        Line::raw(""),
        Line::from(vec![
            Span::raw("Status: "),
            Span::styled(process_hint, status_style),
        ]),
        Line::raw(""),
        Line::raw("Runs:"),
        Line::styled("  julia --project=.", Style::default().fg(Color::DarkGray)),
        Line::styled(
            "  -e 'using Pkg; Pkg.test()'",
            Style::default().fg(Color::DarkGray),
        ),
        Line::raw(""),
        Line::raw("[Enter/t] Run tests"),
        Line::raw("[g/G] Top/Bottom"),
        Line::raw("[PgUp/PgDn] Scroll"),
    ];

    let info_widget = Paragraph::new(info).block(
        Block::default()
            .borders(Borders::ALL)
            .title(" Tests ")
            .border_style(Style::default().fg(Color::Cyan)),
    );
    frame.render_widget(info_widget, chunks[0]);

    // Right: test log
    log_panel::render(frame, &state.test_log, chunks[1], " Test Output ");
}
