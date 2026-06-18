//! Центральная зона: PTY-вывод текущего теста + scrollbar + прогресс-бар текущего шага.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState, Wrap};
use ratatui::Frame;
use ratatui_braille_bar::BrailleBar;

use crate::ansi::parse_ansi_line;
use crate::app::{App, Focus, RunnerStatus};
use crate::queue::Step;
use crate::theme;

pub fn draw(f: &mut Frame, app: &App, area: Rect) {
    let focused = app.focus == Focus::Log;
    let title = if app.running_step().is_some() {
        format!(" ♦ Запуск ({}/{}) ", app.step_count().0, app.step_count().1)
    } else {
        " ♦ Запуск ".to_string()
    };
    let block = Block::default()
        .title(Span::styled(title, theme::block_title(focused)))
        .borders(Borders::ALL)
        .border_style(theme::block_border(focused));
    let inner = block.inner(area);
    f.render_widget(block, area);

    // Разделяем область: лог сверху, прогресс-бар снизу
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(1)])
        .split(inner);

    let log_area = chunks[0];
    let progress_area = chunks[1];

    // Собираем строки: история + (current_line, если есть)
    let mut lines: Vec<Line> = app.log_lines.iter().cloned().collect();
    if let Some(cur) = &app.log_current {
        lines.push(parse_ansi_line(cur));
    }

    let step_progress = compute_step_progress(app);

    if lines.is_empty() {
        draw_ready_art(f, log_area);
        f.render_widget(
            BrailleBar::new(step_progress, 1.0).fill_color(theme::ACCENT),
            progress_area,
        );
        return;
    }

    let total = lines.len();
    let viewport = log_area.height as usize;
    let scroll = app.log_scroll.min(total.saturating_sub(viewport));
    let bottom = total.saturating_sub(scroll);
    let top = bottom.saturating_sub(viewport);
    let visible = lines[top..bottom].to_vec();

    let p = Paragraph::new(visible).wrap(Wrap { trim: false });
    f.render_widget(p, log_area);

    if total > viewport {
        let mut state = ScrollbarState::new(total).position(top);
        let sb = Scrollbar::new(ScrollbarOrientation::VerticalRight)
            .begin_symbol(None)
            .end_symbol(None);
        f.render_stateful_widget(sb, log_area, &mut state);
    }

    f.render_widget(
        BrailleBar::new(step_progress, 1.0).fill_color(theme::ACCENT),
        progress_area,
    );
}

fn compute_step_progress(app: &App) -> f64 {
    match &app.runner {
        RunnerStatus::Running { started_at, step_idx, .. } => {
            let Some(step) = app.queue.get(*step_idx) else { return 0.0; };
            let duration = match step {
                Step::Run { .. } => app.time_test_s as f64,
                Step::Pause { seconds, .. } => *seconds as f64,
                Step::Teardown { .. } => 5.0,
            };
            let elapsed = started_at.elapsed().as_secs_f64();
            (elapsed / duration.max(1.0)).clamp(0.0, 1.0)
        }
        _ => 0.0,
    }
}

fn draw_ready_art(f: &mut Frame, area: Rect) {
    // Анимированная надпись ГОТОВ (шрифт Брайля)
    // Генератор: https://lazesoftware.com/en/tool/brailleaagen/
    let ready_art = [
        r#"⠘⣿⣷⡀⡀⡀⡀⣾⣿⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⢰⣿⣷⡀⣿⣿⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
        r#"⡀⢹⣿⣆⡀⡀⣸⣿⠇⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⠘⠛⠛⡀⠛⠛⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
        r#"⡀⡀⢿⣿⡀⢀⣿⡟⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
        r#"⡀⡀⠈⣿⣿⣿⣿⡀⡀⡀⡀⣶⣿⣿⣿⣿⡄⡀⡀⢀⣾⣿⣿⣿⣷⡀⡀⡀⣰⣿⣿⣿⣿⣦⡀⡀⡀⡀⡀⡀⠹⣿⣆⡀⡀⣿⡇⡀⢠⣿⡟⡀⡀⡀⡀⣿⣿⣿⣿⣿⡀⡀⡀⢀⣾⣿⣿⣿⣷⡀⡀⣿⣿⣿⣿⣿⣿⡀"#,
        r#"⡀⡀⡀⠸⣿⣿⠃⡀⡀⡀⢸⣿⡏⡀⡀⣿⣿⡀⡀⣿⣿⠁⡀⢸⣿⣧⡀⡀⣿⣿⡀⡀⣿⣿⡀⡀⡀⡀⡀⡀⡀⢻⣿⡄⡀⣿⡇⡀⣿⣿⡀⡀⡀⡀⡀⣿⡇⡀⣿⣿⡀⡀⡀⣿⣿⠁⡀⢸⣿⡇⡀⡀⡀⣿⣿⡀⡀⡀"#,
        r#"⡀⡀⡀⣼⣿⣿⡄⡀⡀⡀⡀⡀⡀⡀⣀⣿⣿⡀⡀⣿⣿⡀⡀⢸⣿⣿⡀⡀⣿⣿⡀⡀⠙⠛⡀⡀⡀⡀⡀⡀⡀⡀⢿⣿⡀⣿⡇⣼⣿⠁⡀⡀⡀⡀⡀⣿⡇⡀⣿⣿⡀⡀⡀⣿⣿⣀⣀⣸⣿⣿⡀⡀⡀⣿⣿⡀⡀⡀"#,
        r#"⡀⡀⢠⣿⡟⣿⣿⡀⡀⡀⡀⣠⣾⣿⠛⣿⣿⡀⡀⣿⣿⡀⡀⢸⣿⣿⡀⡀⣿⣿⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⢠⣿⠗⣿⡗⣿⣇⡀⡀⡀⡀⡀⢸⣿⠃⡀⣿⣿⡀⡀⡀⣿⣿⠛⠛⠛⠛⠛⡀⡀⡀⣿⣿⡀⡀⡀"#,
        r#"⡀⡀⣿⣿⡀⠘⣿⣷⡀⡀⢰⣿⡟⡀⡀⣿⣿⡀⡀⣿⣿⡀⡀⢸⣿⣿⡀⡀⣿⣿⡀⡀⣶⣶⡀⡀⡀⡀⡀⡀⡀⢀⣿⡿⡀⣿⡇⠹⣿⡄⡀⡀⡀⡀⣿⣿⡀⡀⣿⣿⡀⡀⡀⣿⣿⡀⡀⢠⣤⣤⡀⡀⡀⣿⣿⡀⡀⡀"#,
        r#"⡀⣼⣿⠃⡀⡀⢹⣿⣆⡀⢸⣿⣧⡀⣠⣿⣿⡀⡀⢿⣿⡄⡀⣸⣿⡏⡀⡀⣿⣿⡀⡀⣿⣿⡀⡀⡀⡀⡀⡀⡀⣿⣿⡀⡀⣿⡇⡀⢻⣿⡀⡀⢀⣾⡿⠁⡀⡀⣿⣿⡀⡀⡀⢿⣿⡄⡀⢸⣿⡇⡀⡀⡀⣿⣿⡀⡀⡀"#,
        r#"⢠⣿⡿⡀⡀⡀⡀⢿⣿⡀⡀⢿⣿⣿⠋⣿⣿⡀⡀⡀⠿⣿⣿⣿⠟⡀⡀⡀⠙⢿⣿⣿⣿⠋⡀⡀⡀⡀⡀⡀⣾⣿⠁⡀⡀⣿⡇⡀⡀⣿⣿⡀⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⡀⠈⠿⣿⣿⣿⠟⡀⡀⡀⡀⣿⣿⡀⡀⡀"#,
        r#"⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⣿⣿⡀⡀⡀⡀⡀⡀⣿⡇⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
        r#"⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⠿⠟⡀⡀⡀⡀⡀⡀⠿⠇⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀⡀"#,
    ];

    let art_height = ready_art.len() as u16;
    let art_width = ready_art[0].chars().count() as u16;
    let y_offset = area.height.saturating_sub(art_height) / 2;
    let x_offset = area.width.saturating_sub(art_width) / 2;

    let now = chrono::Local::now().timestamp_millis();
    let now_sec = now as f64 / 1000.0;

    // Окно вспышек 3 с, в нём 0.25 с резкий блик с вероятностью ~70%.
    let window = (now_sec / 3.0).floor() as u64;
    let window_hash = (window * 12345) % 100;
    let in_glint_phase = window_hash > 30 && (now_sec % 3.0) < 0.25;

    let mut art_lines = vec![Line::raw(""); y_offset as usize];

    for (i, &line) in ready_art.iter().enumerate() {
        let mut spans = vec![Span::raw(" ".repeat(x_offset as usize))];
        for (j, ch) in line.chars().enumerate() {
            if ch == '⡀' || ch == ' ' {
                spans.push(Span::raw(" "));
                continue;
            }
            let phase = ((j as f64 + i as f64 * 2.0) / 100.0 - now_sec * 0.3) * std::f64::consts::PI * 2.0;
            let sin_val = (phase.sin() + 1.0) / 2.0;
            let hash = (i * 313 + j * 177 + (now / 50) as usize) % 1000;
            let is_glint = in_glint_phase && hash > 980;

            let style = if is_glint {
                Style::default().fg(ratatui::style::Color::White).add_modifier(ratatui::style::Modifier::BOLD)
            } else {
                let g = 20 + (80.0 * sin_val) as u8;
                let b = 10 + (90.0 * sin_val) as u8;
                Style::default().fg(ratatui::style::Color::Rgb(0, g, b))
            };
            spans.push(Span::styled(ch.to_string(), style));
        }
        art_lines.push(Line::from(spans));
    }

    let p = Paragraph::new(art_lines);
    f.render_widget(p, area);
}
