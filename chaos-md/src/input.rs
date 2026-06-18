//! Обработка нажатий клавиш. Чистые функции над `App` — без I/O,
//! чтобы их можно было гонять в snapshot-тестах через TestBackend.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::app::{App, Focus, SelectorGroup, SelectorItem};
use crate::state;

/// Что должен сделать вызывающий код после обработки клавиши.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyOutcome {
    /// Ничего особенного — состояние уже обновлено.
    Nothing,
    /// Пора собрать очередь и стартовать раннер.
    StartQueue,
}

/// Обработать одну клавишу. Возвращает `KeyOutcome::StartQueue`, если нужно
/// инициировать запуск очереди (исторически это был `bool`).
pub fn on_key(app: &mut App, k: KeyEvent) -> KeyOutcome {
    // Диалоги поглощают все клавиши.
    if app.check_dialog.is_some() {
        on_key_check_dialog(app, k);
        return KeyOutcome::Nothing;
    }
    if app.stop_confirm_pending {
        on_key_stop_confirm(app, k);
        return KeyOutcome::Nothing;
    }
    if app.config_dialog_open {
        on_key_config_dialog(app, k);
        return KeyOutcome::Nothing;
    }

    // Ctrl+C / q → выход. Если что-то идёт — спросить подтверждение.
    if (k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL))
        || k.code == KeyCode::Char('q')
    {
        if app.is_running() && !app.quit_pending {
            app.quit_pending = true;
            return KeyOutcome::Nothing;
        }
        app.should_quit = true;
        return KeyOutcome::Nothing;
    }
    if app.quit_pending {
        match k.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => app.should_quit = true,
            _ => app.quit_pending = false,
        }
        return KeyOutcome::Nothing;
    }

    // 'c' (без модификаторов) → открыть Check для выделенного теста.
    if k.code == KeyCode::Char('c') && k.modifiers.is_empty() {
        if let SelectorItem::Test(idx) = app.current_selector_item() {
            app.pending_check = Some(idx);
        }
        return KeyOutcome::Nothing;
    }

    // 'i' → открыть диалог конфигурации.
    if k.code == KeyCode::Char('i') && k.modifiers.is_empty() {
        app.config_dialog_open = true;
        return KeyOutcome::Nothing;
    }

    // 'K' (Shift+k) → очистка логов и таймлайна.
    if k.code == KeyCode::Char('K') && k.modifiers == KeyModifiers::SHIFT {
        app.log_lines.clear();
        app.log_current = None;
        app.timeline_lines.clear();
        return KeyOutcome::Nothing;
    }

    // 'R' / Ctrl+R → полная перерисовка экрана.
    if (k.code == KeyCode::Char('R') && k.modifiers == KeyModifiers::SHIFT)
        || (k.code == KeyCode::Char('r') && k.modifiers.contains(KeyModifiers::CONTROL))
    {
        app.force_redraw = true;
        return KeyOutcome::Nothing;
    }

    if k.code == KeyCode::Tab {
        cycle_focus(app);
        return KeyOutcome::Nothing;
    }

    match app.focus {
        Focus::Selector => on_key_selector(app, k),
        Focus::Log => {
            on_key_scroll(&mut app.log_scroll, k);
            KeyOutcome::Nothing
        }
        Focus::Timeline => {
            on_key_scroll(&mut app.timeline_scroll, k);
            KeyOutcome::Nothing
        }
    }
}

/// Tab по функциональным группам: TestList → TimeFields → StartButton → Log → Timeline → TestList.
/// Внутри панели Selector переключаем подгруппу, не уходя из неё, пока есть следующая.
fn cycle_focus(app: &mut App) {
    match app.focus {
        Focus::Selector => match app.selector_group.next() {
            Some(next_group) => app.enter_selector_group(next_group),
            None => app.focus = Focus::Log,
        },
        Focus::Log => app.focus = Focus::Timeline,
        Focus::Timeline => {
            app.focus = Focus::Selector;
            app.enter_selector_group(SelectorGroup::TestList);
        }
    }
}

fn on_key_check_dialog(app: &mut App, k: KeyEvent) {
    match k.code {
        KeyCode::Esc | KeyCode::Char('c') | KeyCode::Char('q') => {
            app.check_dialog = None;
        }
        KeyCode::Up => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = d.scroll.saturating_sub(1);
            }
        }
        KeyCode::Down => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = d.scroll.saturating_add(1);
            }
        }
        KeyCode::PageUp => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = d.scroll.saturating_sub(20);
            }
        }
        KeyCode::PageDown => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = d.scroll.saturating_add(20);
            }
        }
        KeyCode::Home => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = 0;
            }
        }
        KeyCode::End => {
            if let Some(d) = &mut app.check_dialog {
                d.scroll = usize::MAX / 2;
            }
        }
        _ => {}
    }
}

fn on_key_config_dialog(app: &mut App, k: KeyEvent) {
    match k.code {
        KeyCode::Esc | KeyCode::Char('i') | KeyCode::Char('q') => {
            app.config_dialog_open = false;
        }
        _ => {}
    }
}

/// Диалог подтверждения остановки. `y` подтверждает, остальное — отмена.
fn on_key_stop_confirm(app: &mut App, k: KeyEvent) {
    match k.code {
        KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => {
            app.stop_confirm_pending = false;
            app.stop_requested = true;
        }
        KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Char(' ') => {
            app.stop_confirm_pending = false;
        }
        _ => {}
    }
}

fn on_key_selector(app: &mut App, k: KeyEvent) -> KeyOutcome {
    // Глобальный шорткат «S» — переключатель Start/Stop — работает из любой группы.
    if k.code == KeyCode::Char('S') {
        return toggle_start_stop(app);
    }

    match app.selector_group {
        SelectorGroup::TestList => on_key_test_list(app, k),
        SelectorGroup::TimeFields => on_key_time_fields(app, k),
        SelectorGroup::StartButton => on_key_start_button(app, k),
    }
}

fn on_key_test_list(app: &mut App, k: KeyEvent) -> KeyOutcome {
    match k.code {
        KeyCode::Up => app.selector_move(-1),
        KeyCode::Down => app.selector_move(1),
        KeyCode::Char(' ') | KeyCode::Enter => {
            toggle_current(app);
            let _ = state::save(app);
        }
        _ => {}
    }
    KeyOutcome::Nothing
}

fn on_key_time_fields(app: &mut App, k: KeyEvent) -> KeyOutcome {
    match k.code {
        KeyCode::Up => app.selector_move(-1),
        KeyCode::Down => app.selector_move(1),
        KeyCode::Enter => {
            // Внутри группы: → следующее поле. Если это было последнее
            // (TimeWait) — переход в следующую группу (StartButton), как Tab.
            let cur = app.current_selector_item();
            if matches!(cur, SelectorItem::TimeWait) {
                app.enter_selector_group(SelectorGroup::StartButton);
            } else {
                app.selector_move(1);
            }
        }
        KeyCode::Backspace => {
            match app.current_selector_item() {
                SelectorItem::TimeTest => app.time_test_s /= 10,
                SelectorItem::TimeWait => app.time_wait_s /= 10,
                _ => {}
            }
            app.time_field_pristine = false;
            let _ = state::save(app);
        }
        KeyCode::Char(c) if c.is_ascii_digit() => {
            let d = c as u32 - '0' as u32;
            // Pristine — первая цифра заменяет содержимое (DOS-стиль).
            let replace = app.time_field_pristine;
            match app.current_selector_item() {
                SelectorItem::TimeTest => {
                    let n = if replace {
                        d
                    } else {
                        app.time_test_s.saturating_mul(10).saturating_add(d).min(100_000)
                    };
                    app.time_test_s = n;
                }
                SelectorItem::TimeWait => {
                    let n = if replace {
                        d
                    } else {
                        app.time_wait_s.saturating_mul(10).saturating_add(d).min(100_000)
                    };
                    app.time_wait_s = n;
                }
                _ => {}
            }
            app.time_field_pristine = false;
            let _ = state::save(app);
        }
        _ => {}
    }
    KeyOutcome::Nothing
}

fn on_key_start_button(app: &mut App, k: KeyEvent) -> KeyOutcome {
    match k.code {
        KeyCode::Char(' ') | KeyCode::Enter => toggle_start_stop(app),
        _ => KeyOutcome::Nothing,
    }
}

/// Логика «то ли запустить, то ли остановить» — общая для Space/Enter на Start
/// и для глобального `S`.
fn toggle_start_stop(app: &mut App) -> KeyOutcome {
    if app.is_running() {
        app.stop_confirm_pending = true;
        KeyOutcome::Nothing
    } else {
        KeyOutcome::StartQueue
    }
}

fn toggle_current(app: &mut App) {
    match app.current_selector_item() {
        SelectorItem::Test(idx) => app.selected[idx] = !app.selected[idx],
        SelectorItem::PhaseNode => app.phases.node = !app.phases.node,
        SelectorItem::PhaseDc => app.phases.dc = !app.phases.dc,
        SelectorItem::DryRun => app.dry_run = !app.dry_run,
        _ => {}
    }
}

fn on_key_scroll(scroll: &mut usize, k: KeyEvent) {
    match k.code {
        KeyCode::PageUp => *scroll = scroll.saturating_add(10),
        KeyCode::PageDown => *scroll = scroll.saturating_sub(10),
        KeyCode::Up => *scroll = scroll.saturating_add(1),
        KeyCode::Down => *scroll = scroll.saturating_sub(1),
        KeyCode::Home => *scroll = usize::MAX,
        KeyCode::End => *scroll = 0,
        _ => {}
    }
}
