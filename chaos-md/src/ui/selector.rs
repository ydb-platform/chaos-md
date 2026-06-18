//! Левая колонка: чекбоксы тестов, фазы, два поля времени, кнопка Start.

use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};
use ratatui::Frame;

use crate::app::{App, Focus, RunnerStatus, SelectorItem};
use crate::catalog::CATALOG;
use crate::queue::Step;
use crate::theme;

pub fn draw(f: &mut Frame, app: &App, area: Rect) {
    let focused = app.focus == Focus::Selector;
    let block = Block::default()
        .title(Span::styled(" ♦ Тесты ", theme::block_title(focused)))
        .borders(Borders::ALL)
        .border_style(theme::block_border(focused));
    let inner = block.inner(area);
    f.render_widget(block, area);

    let items = SelectorItem::all();
    let mut lines: Vec<Line> = Vec::with_capacity(items.len() + 4);
    let cur = app.current_selector_item();
    let width = inner.width as usize;

    // «Сейчас исполняющийся» тест — только когда шаг это реально Run/Teardown.
    // На Pause не возвращаем предыдущий тест, чтобы он не светился как «▶».
    let current_test_idx = match &app.runner {
        RunnerStatus::Running { step_idx, .. } => {
            app.queue.get(*step_idx).and_then(|st| match st {
                Step::Run { test_idx, .. } => Some(*test_idx),
                Step::Teardown { test_idx } => Some(*test_idx),
                Step::Pause { .. } => None,
            })
        }
        _ => None,
    };

    // На паузе — ID следующего теста (чтобы показать «☐ в очереди» иконкой).
    let pause_next_idx: Option<usize> = match &app.runner {
        RunnerStatus::Running { step_idx, .. } => match app.queue.get(*step_idx) {
            Some(Step::Pause { .. }) => app
                .queue
                .iter()
                .skip(*step_idx + 1)
                .find_map(|st| match st {
                    Step::Run { test_idx, .. } => Some(*test_idx),
                    _ => None,
                }),
            _ => None,
        },
        _ => None,
    };

    lines.push(Line::raw(""));

    if app.dry_run {
        lines.push(Line::from(Span::styled(
            "  - DRY-RUN режим",
            Style::default()
                .fg(theme::WARN_OR_DEFAULT)
                .add_modifier(Modifier::BOLD),
        )));
    }

    for (i, item) in items.iter().enumerate() {
        let is_cur = focused && *item == cur;
        match item {
            SelectorItem::Test(idx) => {
                let e = &CATALOG[*idx];
                let is_running = current_test_idx == Some(*idx);
                let is_pause_target = pause_next_idx == Some(*idx);
                let mark = if is_running {
                    "▶"
                } else if is_pause_target {
                    "⏸"
                } else if app.finished_tests[*idx] {
                    "✓"
                } else if app.selected[*idx] {
                    "☑"
                } else {
                    "☐"
                };
                let text = format!(" {} {} {}", mark, e.id, e.title);
                lines.push(highlight(
                    text,
                    is_cur || is_running,
                    width,
                    app.selected[*idx],
                    app.finished_tests[*idx],
                    is_running,
                ));
            }
            SelectorItem::PhaseNode => {
                if matches!(items.get(i.saturating_sub(1)), Some(SelectorItem::Test(_))) {
                    lines.push(Line::raw(""));
                    lines.push(Line::from(Span::styled(" Фазы:", theme::dim())));
                }
                let mark = if app.phases.node { "☑" } else { "☐" };
                lines.push(highlight(format!(" {} узел", mark), is_cur, width, app.phases.node, false, false));
            }
            SelectorItem::PhaseDc => {
                let mark = if app.phases.dc { "☑" } else { "☐" };
                lines.push(highlight(format!(" {} ЦОД", mark), is_cur, width, app.phases.dc, false, false));
            }
            SelectorItem::TimeTest => {
                lines.push(Line::raw(""));
                lines.push(time_line(
                    "Время:",
                    app.time_test_s,
                    is_cur,
                    is_cur && app.time_field_pristine,
                    width,
                ));
            }
            SelectorItem::TimeWait => {
                lines.push(time_line(
                    "Пауза:",
                    app.time_wait_s,
                    is_cur,
                    is_cur && app.time_field_pristine,
                    width,
                ));
            }
            SelectorItem::DryRun => {
                lines.push(Line::raw(""));
                let mark = if app.dry_run { "☑" } else { "☐" };
                lines.push(highlight(format!(" {} Пустой прогон", mark), is_cur, width, app.dry_run, false, false));
            }
            SelectorItem::Start => {
                lines.push(Line::raw(""));
                lines.push(Line::raw(""));
                let (label, style) = if app.is_running() {
                    if is_cur {
                        (
                            "▏  СТОП  ▕",
                            Style::default()
                                .bg(theme::ERR)
                                .fg(ratatui::style::Color::White)
                                .add_modifier(Modifier::BOLD)
                                .add_modifier(Modifier::REVERSED),
                        )
                    } else {
                        (
                            "▏  СТОП  ▕",
                            Style::default()
                                .bg(theme::ERR)
                                .fg(ratatui::style::Color::Black)
                                .add_modifier(Modifier::BOLD),
                        )
                    }
                } else if is_cur {
                    (
                        "[ ЗАПУСК ]",
                        Style::default()
                            .bg(theme::FOCUS)
                            .fg(theme::FOCUS_FG)
                            .add_modifier(Modifier::BOLD),
                    )
                } else {
                    (
                        "[ ЗАПУСК ]",
                        Style::default()
                            .bg(theme::OK_DIM)
                            .fg(ratatui::style::Color::White)
                            .add_modifier(Modifier::BOLD),
                    )
                };

                let label_width = label.chars().count();
                let left_pad = width.saturating_sub(label_width) / 2;
                let right_pad = width.saturating_sub(label_width + left_pad);
                let mut spans = vec![Span::raw(" ".repeat(left_pad))];
                spans.push(Span::styled(label, style));
                spans.push(Span::raw(" ".repeat(right_pad)));
                lines.push(Line::from(spans));
            }
        }
    }

    let p = Paragraph::new(lines);
    f.render_widget(p, inner);
}

fn highlight(text: String, focused: bool, width: usize, selected: bool, is_finished: bool, is_running: bool) -> Line<'static> {
    let padded = format!(" {:<width$}", text, width = width.saturating_sub(1));
    if is_running {
        Line::from(Span::styled(
            padded,
            Style::default()
                .fg(theme::ACCENT)
                .add_modifier(ratatui::style::Modifier::BOLD),
        ))
    } else if focused {
        Line::from(Span::styled(
            padded,
            Style::default()
                .bg(theme::FOCUS)
                .fg(theme::FOCUS_FG),
        ))
    } else if is_finished {
        Line::from(Span::styled(
            padded,
            Style::default().fg(theme::OK),
        ))
    } else if selected {
        Line::from(Span::styled(
            padded,
            Style::default().fg(theme::OK),
        ))
    } else {
        Line::from(Span::raw(padded))
    }
}

fn time_line(
    label: &'static str,
    value: u32,
    focused: bool,
    pristine: bool,
    width: usize,
) -> Line<'static> {
    let val_str = format!(" {:>4} ", value);
    let seconds_str = "▏сек.";

    let mut spans = vec![Span::styled(format!("  {}▕", label), Style::default())];

    if focused {
        spans[0] = Span::styled(
            format!("  {}▕", label),
            Style::default().bg(theme::FOCUS).fg(theme::FOCUS_FG),
        );
        // Pristine — значение «выделено», DOS-стиль: чёрный текст на ярко-жёлтом фоне.
        // Не-pristine (редактирование) — белый текст на тёмном фоне, как «открытое» поле.
        let val_style = if pristine {
            Style::default()
                .bg(theme::WARN_OR_DEFAULT)
                .fg(ratatui::style::Color::Black)
                .add_modifier(ratatui::style::Modifier::BOLD)
        } else {
            Style::default()
                .bg(ratatui::style::Color::White)
                .fg(ratatui::style::Color::Black)
        };
        spans.push(Span::styled(val_str, val_style));
        spans.push(Span::styled(
            seconds_str,
            Style::default().bg(theme::FOCUS).fg(theme::FOCUS_FG),
        ));

        let current_len: usize = spans.iter().map(|s| s.content.chars().count()).sum();
        if current_len < width {
            spans.push(Span::styled(
                " ".repeat(width - current_len),
                Style::default().bg(theme::FOCUS),
            ));
        }
    } else {
        spans.push(Span::styled(
            val_str,
            Style::default()
                .bg(theme::CYBER_GRAY)
                .fg(ratatui::style::Color::White),
        ));
        spans.push(Span::raw(seconds_str));
    }

    Line::from(spans)
}
