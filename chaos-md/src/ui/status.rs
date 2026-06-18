//! Правая нижняя зона: текущий тест, scope, немезис, прогресс окна -t.

use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Gauge, Paragraph};
use ratatui::Frame;

use crate::app::{elapsed_since, fmt_hms, App, RunnerStatus};
use crate::catalog::CATALOG;
use crate::queue::Step;
use crate::theme;

pub fn draw(f: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .title(Span::styled(" ♦ Статус ", theme::block_title(false)))
        .borders(Borders::ALL)
        .border_style(theme::block_border(false));
    let inner = block.inner(area);
    f.render_widget(block, area);

    let mut lines: Vec<Line> = Vec::new();

    match &app.runner {
        RunnerStatus::Idle => {
            lines.push(Line::from(Span::styled(
                "ожидание старта",
                Style::default().fg(theme::DIM),
            )));
        }
        RunnerStatus::Finished { ok, .. } => {
            let (label, color) = if *ok {
                ("очередь завершена", theme::OK)
            } else {
                ("очередь оборвана", theme::ERR)
            };
            lines.push(Line::from(Span::styled(label, Style::default().fg(color))));
        }
        RunnerStatus::Running { step_idx, .. } => {
            let total = app.queue.len();
            let pos = step_idx + 1;
            let Some(step) = app.queue.get(*step_idx) else {
                lines.push(Line::from(Span::styled(
                    "(пустая очередь)",
                    Style::default().fg(theme::DIM),
                )));
                let p = Paragraph::new(lines);
                f.render_widget(p, inner);
                return;
            };

            lines.push(Line::from(Span::styled(
                format!("[{}/{}]", pos, total),
                Style::default().fg(theme::ACCENT).add_modifier(Modifier::BOLD),
            )));
            match step {
                Step::Run { test_idx, scope } => {
                    let e = &CATALOG[*test_idx];
                    lines.push(Line::from(format!("{} {}", e.id, e.title)));
                    lines.push(Line::from(format!("scope:   {}", scope.label())));
                    lines.push(Line::from(format!("немезис: {}", e.nemesis)));
                }
                Step::Teardown { test_idx } => {
                    let e = &CATALOG[*test_idx];
                    lines.push(Line::from(format!("{} teardown", e.id)));
                    lines.push(Line::from(format!("немезис: {}", e.nemesis)));
                }
                Step::Pause { seconds, .. } => {
                    lines.push(Line::from(Span::styled(
                        format!("пауза {} с", seconds),
                        Style::default().fg(theme::DIM),
                    )));
                }
            }

            // CHAOS_START — параметры
            if let Some(ev) = &app.current_event {
                lines.push(Line::raw(""));
                lines.push(Line::from(Span::styled(
                    "детали:",
                    Style::default().fg(theme::DIM),
                )));
                for tok in ev.raw_details.split_whitespace().skip(1) {
                    lines.push(Line::from(format!("  {tok}")));
                }
            }
        }
    }

    let p = Paragraph::new(lines);
    f.render_widget(p, inner);

    // Прогресс-бар окна -t — отдельно, в нижней строке inner-области.
    if let RunnerStatus::Running { .. } = &app.runner {
        if let Some(ev) = &app.current_event {
            if let (Some(timeout), Some(started)) = (ev.timeout_s, ev.started_wall) {
                if inner.height >= 3 {
                    let bar_area = Rect {
                        x: inner.x,
                        y: inner.y + inner.height - 1,
                        width: inner.width,
                        height: 1,
                    };
                    let elapsed = elapsed_since(started);
                    let percent = (elapsed.saturating_mul(100) / timeout.max(1)).min(100) as u16;
                    let label = format!(
                        "{} / {}",
                        fmt_hms(elapsed),
                        fmt_hms(timeout)
                    );
                    let g = Gauge::default()
                        .gauge_style(Style::default().fg(theme::ACCENT))
                        .percent(percent)
                        .label(label);
                    f.render_widget(g, bar_area);
                }
            }
        }
    }
}
