//! Главная раскладка UI.

pub mod clock;
pub mod config_dialog;
pub mod confirm;
pub mod dialog;
pub mod log;
pub mod remaining_time;
pub mod selector;
pub mod status;
pub mod timeline;

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Style;
use ratatui::text::Span;
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::app::App;

pub fn draw(f: &mut Frame, app: &App) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0), Constraint::Length(1)])
        .split(f.area());

    let menu_bar = outer[0];
    let main_area = outer[1];
    let status_bar = outer[2];

    // main: левая | (центр + timeline) | (часы + статус)
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length(24),
            Constraint::Min(40),
            Constraint::Length(23),
        ])
        .split(main_area);

    // средняя колонка: лог сверху, timeline снизу
    let mid_rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(10)])
        .split(cols[1]);

    // правая колонка: часы сверху, ETE, ETA, статус снизу
    let right_rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Length(6), Constraint::Length(1), Constraint::Length(1), Constraint::Length(1), Constraint::Min(0)])
        .split(cols[2]);

    selector::draw(f, app, cols[0]);
    log::draw(f, app, mid_rows[0]);
    timeline::draw(f, app, mid_rows[1]);
    clock::draw(f, app, right_rows[1]);
    remaining_time::draw(f, app, right_rows[2]);
    status::draw(f, app, right_rows[5]);

    draw_menu_bar(f, app, menu_bar);
    draw_status_bar(f, app, status_bar);

    // Диалоги — рендерим поверх всего остального. Приоритет: stop > config > check.
    if app.stop_confirm_pending {
        confirm::draw_stop_confirm(f);
    } else if app.config_dialog_open {
        config_dialog::draw(f, app);
    } else {
        dialog::draw(f, app);
    }
}

fn draw_menu_bar(f: &mut Frame, _app: &App, area: Rect) {
    let style = Style::default()
        .bg(ratatui::style::Color::Rgb(55, 63, 67))
        .fg(ratatui::style::Color::Gray);

    let dots = "·".repeat(area.width.saturating_sub(22) as usize);
    let text = format!(" 🗿 Chaos MD · v0.5.1  {}", dots);

    let p = Paragraph::new(ratatui::text::Line::from(text))
        .style(style);
    f.render_widget(p, area);
}

fn draw_status_bar(f: &mut Frame, app: &App, area: Rect) {
    use crate::theme;
    use ratatui::style::{Color, Modifier};

    // Особый случай: ждём ответа «выйти?». Перекрашиваем весь статус-бар.
    if app.quit_pending {
        let line = ratatui::text::Line::from(vec![
            Span::styled(
                " Выйти из приложения? ",
                Style::default()
                    .bg(theme::ERR)
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw("  "),
            Span::styled(
                " y ",
                Style::default()
                    .bg(theme::OK)
                    .fg(Color::Black)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" подтвердить    "),
            Span::styled(
                " Esc / любая ",
                Style::default()
                    .bg(theme::CYBER_GRAY)
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" отмена"),
        ]);
        let p = Paragraph::new(line).style(
            Style::default()
                .bg(theme::STATUS_BG_DARK)
                .fg(Color::White),
        );
        f.render_widget(p, area);
        return;
    }

    let style = Style::default()
        .bg(theme::STATUS_BG_DARK)
        .fg(theme::DIM);

    // Подсказки зависят от состояния.
    let mut parts: Vec<(&str, &str)> = vec![
        ("Tab", "Фокус"),
        ("↑↓", "Навигация"),
    ];
    match app.focus {
        crate::app::Focus::Selector => {
            parts.push(("Space/Enter", "Выбрать"));
        }
        crate::app::Focus::Log | crate::app::Focus::Timeline => {
            parts.push(("PgUp/PgDn", "Скролл"));
        }
    }
    parts.push(("c", "Проверка"));
    parts.push(("i", "Конфиг"));
    if app.is_running() {
        parts.push(("S", "Стоп!"));
    } else {
        parts.push(("S", "Запуск"));
    }
    parts.push(("q", "Выход"));

    let mut left_spans = Vec::new();
    for (k, v) in parts {
        left_spans.push(Span::styled(
            format!(" {k} "),
            Style::default()
                .bg(theme::CYBER_GRAY)
                .fg(theme::OK)
                .add_modifier(Modifier::BOLD),
        ));
        left_spans.push(Span::styled(
            format!(" {v}  "),
            Style::default()
                .bg(theme::STATUS_BG_DARK)
                .fg(Color::White),
        ));
    }

    let right_text = " YDB · 2026 ";
    let right_style = Style::default()
        .bg(theme::STATUS_BG_DARK)
        .fg(theme::DIM)
        .add_modifier(Modifier::BOLD);
    let right_p = Paragraph::new(ratatui::text::Line::from(right_text))
        .style(right_style)
        .alignment(ratatui::layout::Alignment::Right);

    let left_p = Paragraph::new(ratatui::text::Line::from(left_spans)).style(style);

    let layout = Layout::default()
        .direction(ratatui::layout::Direction::Horizontal)
        .constraints([
            ratatui::layout::Constraint::Min(0),
            ratatui::layout::Constraint::Length(right_text.len() as u16),
        ])
        .split(area);

    f.render_widget(left_p, layout[0]);
    f.render_widget(right_p, layout[1]);
}
