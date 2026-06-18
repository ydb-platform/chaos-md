//! Маленький модальный диалог-подтверждение для остановки и других важных действий.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};
use ratatui::Frame;

use crate::theme;

pub fn draw_stop_confirm(f: &mut Frame) {
    let area = centered_rect_fixed(f.area(), 62, 7);
    f.render_widget(Clear, area);

    let block = Block::default()
        .title(Line::from(vec![
            Span::raw(" "),
            Span::styled(
                "Остановить хаос?",
                Style::default()
                    .fg(theme::DIALOG_TITLE)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" "),
        ]))
        .borders(Borders::ALL)
        .border_style(Style::default().fg(theme::ERR))
        .style(Style::default().bg(Color::Rgb(40, 0, 20)).fg(Color::White));

    let inner = block.inner(area);
    f.render_widget(block, area);

    let lines = vec![
        Line::raw(""),
        Line::from(Span::raw(
            " Шаг прервётся, при необходимости запустится teardown.",
        )),
        Line::raw(""),
        Line::from(vec![
            Span::raw(" "),
            Span::styled(
                " y / Enter ",
                Style::default()
                    .bg(theme::ERR)
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" остановить    "),
            Span::styled(
                " Esc / n ",
                Style::default()
                    .bg(theme::CYBER_GRAY)
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" отмена"),
        ]),
    ];

    f.render_widget(Paragraph::new(lines), inner);
}

fn centered_rect_fixed(area: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(area.width);
    let h = h.min(area.height);
    let v = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length((area.height.saturating_sub(h)) / 2),
            Constraint::Length(h),
            Constraint::Min(0),
        ])
        .split(area);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length((area.width.saturating_sub(w)) / 2),
            Constraint::Length(w),
            Constraint::Min(0),
        ])
        .split(v[1])[1]
}
