//! UI-снапшот-тесты. Запуск: `cargo test --test snapshots`.
//!
//! С `CHAOS_MD_SNAP_DUMP=1` каждый сценарий пишет «скриншот» в
//! `target/snapshots/<name>.txt`. Удобно глазами посмотреть UI после правок:
//!
//!     CHAOS_MD_SNAP_DUMP=1 cargo test --test snapshots --no-fail-fast
//!     ls target/snapshots
//!
//! Тесты используют `TestBackend`, никакого реального терминала не нужно.

mod common;

use std::path::PathBuf;
use std::time::Instant;

use chaos_md::app::{App, CheckDialog, RunnerStatus, SelectorGroup};
use chaos_md::input::KeyOutcome;
use chaos_md::queue::Step;
use crossterm::event::KeyCode;

use common::*;

fn dump(name: &str, snap: &str) {
    if std::env::var("CHAOS_MD_SNAP_DUMP").is_err() {
        return;
    }
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("snapshots");
    std::fs::create_dir_all(&dir).ok();
    let _ = std::fs::write(dir.join(format!("{name}.txt")), snap);
}

// ──────────────────────────────────────────────────────────────────────
// Базовый Idle экран
// ──────────────────────────────────────────────────────────────────────

#[test]
fn idle_screen_has_main_zones() {
    let app = fresh_app();
    let snap = snapshot_default(&app);
    dump("01_idle", &snap);

    assert!(contains(&snap, "Тесты"), "selector title");
    assert!(contains(&snap, "Запуск"), "log title");
    assert!(contains(&snap, "Timeline"), "timeline title");
    assert!(contains(&snap, "Статус"), "status title");
    assert!(contains(&snap, "ЗАПУСК"), "start button");
    assert!(contains(&snap, "Chaos MD"), "menu bar");
}

#[test]
fn idle_screen_shows_dry_run_banner() {
    let mut app = fresh_app();
    app.dry_run = true;
    let snap = snapshot_default(&app);
    assert!(contains(&snap, "DRY-RUN"), "banner shown when dry_run=true");
}

#[test]
fn idle_no_banner_when_dry_run_off() {
    let mut app = fresh_app();
    app.dry_run = false;
    let snap = snapshot_default(&app);
    assert!(!contains(&snap, "DRY-RUN режим"), "no banner when dry_run=false");
}

#[test]
fn idle_shows_all_twelve_tests() {
    let app = fresh_app();
    let snap = snapshot_default(&app);
    // 12 тестов: id «01»..«12» должны присутствовать
    for id in ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12"] {
        assert!(contains(&snap, id), "test id {id} should be visible");
    }
}

// ──────────────────────────────────────────────────────────────────────
// Навигация в селекторе
// ──────────────────────────────────────────────────────────────────────

#[test]
fn down_arrow_moves_selection() {
    let mut app = fresh_app();
    assert_eq!(app.selector_idx, 0);
    press(&mut app, KeyCode::Down);
    assert_eq!(app.selector_idx, 1);
}

#[test]
fn up_arrow_at_top_is_clamped() {
    let mut app = fresh_app();
    press(&mut app, KeyCode::Up);
    assert_eq!(app.selector_idx, 0, "stays at top");
}

#[test]
fn down_arrow_at_bottom_is_clamped() {
    // В новой модели ↓ клампится в пределах группы TestList.
    // Последний итем группы TestList — DryRun.
    let mut app = fresh_app();
    for _ in 0..200 { press(&mut app, KeyCode::Down); }
    let expected = SelectorGroup::TestList.last_idx();
    assert_eq!(app.selector_idx, expected);
}

#[test]
fn down_arrow_does_not_jump_groups() {
    // Регрессия: ↓ из TestList не должна перепрыгивать в TimeFields.
    let mut app = fresh_app();
    for _ in 0..200 { press(&mut app, KeyCode::Down); }
    assert_eq!(app.selector_group, SelectorGroup::TestList);
}

#[test]
fn space_toggles_selected_test() {
    let mut app = fresh_app();
    assert!(!app.selected[0]);
    press_char(&mut app, ' ');
    assert!(app.selected[0]);
    press_char(&mut app, ' ');
    assert!(!app.selected[0]);
}

#[test]
fn enter_toggles_selected_test_same_as_space() {
    let mut app = fresh_app();
    press(&mut app, KeyCode::Enter);
    assert!(app.selected[0]);
}

#[test]
fn digits_grow_time_test() {
    let mut app = fresh_app();
    app.enter_selector_group(SelectorGroup::TimeFields);
    app.time_test_s = 0;
    press_char(&mut app, '6');
    // Первая цифра по pristine-логике заменила старое значение 0 на 6
    assert_eq!(app.time_test_s, 6);
    press_char(&mut app, '0');
    assert_eq!(app.time_test_s, 60);
    press(&mut app, KeyCode::Backspace);
    assert_eq!(app.time_test_s, 6);
}

#[test]
fn time_field_renders_pristine_highlight() {
    let mut app = fresh_app();
    app.enter_selector_group(SelectorGroup::TimeFields);
    let snap = snapshot_default(&app);
    dump("15_time_pristine", &snap);
    assert!(contains(&snap, "Время:"));
}

#[test]
fn start_button_focus_highlight_idle() {
    let mut app = fresh_app();
    app.enter_selector_group(SelectorGroup::StartButton);
    let snap = snapshot_default(&app);
    dump("16_start_focused_idle", &snap);
    assert!(contains(&snap, "ЗАПУСК"));
}

#[test]
fn pristine_first_digit_replaces() {
    let mut app = fresh_app();
    app.enter_selector_group(SelectorGroup::TimeFields);
    app.time_test_s = 1200;
    // pristine=true сразу после входа в группу
    assert!(app.time_field_pristine);
    press_char(&mut app, '8');
    assert_eq!(app.time_test_s, 8, "first digit must replace old value");
    assert!(!app.time_field_pristine);
    press_char(&mut app, '5');
    assert_eq!(app.time_test_s, 85, "second digit must append");
}

#[test]
fn moving_between_fields_resets_pristine() {
    let mut app = fresh_app();
    app.enter_selector_group(SelectorGroup::TimeFields);
    app.time_test_s = 0;
    press_char(&mut app, '5');
    assert!(!app.time_field_pristine);
    press(&mut app, KeyCode::Down); // → TimeWait
    assert!(app.time_field_pristine, "moving to next field resets pristine");
}

#[test]
fn enter_on_time_test_moves_to_time_wait() {
    let mut app = fresh_app();
    app.enter_selector_group(SelectorGroup::TimeFields);
    let time_wait_idx = chaos_md::app::SelectorItem::all()
        .iter()
        .position(|i| matches!(i, chaos_md::app::SelectorItem::TimeWait))
        .unwrap();
    press(&mut app, KeyCode::Enter);
    assert_eq!(app.selector_idx, time_wait_idx);
    assert!(app.time_field_pristine);
}

#[test]
fn enter_on_time_wait_moves_to_start_button() {
    let mut app = fresh_app();
    app.enter_selector_group(SelectorGroup::TimeFields);
    app.selector_move(1); // на TimeWait
    press(&mut app, KeyCode::Enter);
    assert_eq!(app.selector_group, SelectorGroup::StartButton);
}

#[test]
fn time_test_does_not_grow_beyond_limit() {
    let mut app = fresh_app();
    app.enter_selector_group(SelectorGroup::TimeFields);
    app.time_test_s = 100_000;
    app.time_field_pristine = false; // имитируем уже идущее редактирование
    press_char(&mut app, '9');
    assert_eq!(app.time_test_s, 100_000, "should reject overflow when appending");
}

// ──────────────────────────────────────────────────────────────────────
// Tab — фокус-переключение
// ──────────────────────────────────────────────────────────────────────

#[test]
fn tab_cycles_through_selector_subgroups() {
    // Tab внутри Selector: TestList → TimeFields → StartButton → Log
    let mut app = fresh_app();
    assert_eq!(app.selector_group, SelectorGroup::TestList);

    press(&mut app, KeyCode::Tab);
    assert_eq!(app.focus, chaos_md::app::Focus::Selector);
    assert_eq!(app.selector_group, SelectorGroup::TimeFields);

    press(&mut app, KeyCode::Tab);
    assert_eq!(app.focus, chaos_md::app::Focus::Selector);
    assert_eq!(app.selector_group, SelectorGroup::StartButton);

    press(&mut app, KeyCode::Tab);
    assert_eq!(app.focus, chaos_md::app::Focus::Log);
}

#[test]
fn tab_full_cycle_returns_to_test_list() {
    let mut app = fresh_app();
    for _ in 0..5 {
        press(&mut app, KeyCode::Tab);
    }
    assert_eq!(app.focus, chaos_md::app::Focus::Selector);
    assert_eq!(app.selector_group, SelectorGroup::TestList);
    assert_eq!(app.selector_idx, 0);
}

#[test]
fn tab_into_time_fields_sets_pristine() {
    let mut app = fresh_app();
    app.time_field_pristine = false;
    press(&mut app, KeyCode::Tab);
    assert_eq!(app.selector_group, SelectorGroup::TimeFields);
    assert!(app.time_field_pristine, "Tab into TimeFields resets pristine");
}

// ──────────────────────────────────────────────────────────────────────
// Кнопка Start / Stop
// ──────────────────────────────────────────────────────────────────────

fn put_cursor_on_start(app: &mut App) {
    app.enter_selector_group(SelectorGroup::StartButton);
}

#[test]
fn space_on_start_idle_requests_start() {
    let mut app = fresh_app();
    app.selected[0] = true;
    put_cursor_on_start(&mut app);
    let outcome = press_char(&mut app, ' ');
    assert_eq!(outcome, KeyOutcome::StartQueue);
}

#[test]
fn enter_on_start_idle_requests_start() {
    let mut app = fresh_app();
    app.selected[0] = true;
    put_cursor_on_start(&mut app);
    let outcome = press(&mut app, KeyCode::Enter);
    assert_eq!(outcome, KeyOutcome::StartQueue);
}

#[test]
fn space_on_start_running_opens_confirm() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    put_cursor_on_start(&mut app);
    let outcome = press_char(&mut app, ' ');
    assert_eq!(outcome, KeyOutcome::Nothing);
    assert!(app.stop_confirm_pending, "should open confirm dialog");
}

#[test]
fn enter_on_start_running_does_not_restart() {
    // Регрессионный тест: раньше Enter на кнопке во время запуска
    // безусловно возвращал StartQueue, что приводило к перезапуску очереди
    // поверх работающей.
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    put_cursor_on_start(&mut app);
    let outcome = press(&mut app, KeyCode::Enter);
    assert_eq!(outcome, KeyOutcome::Nothing, "must not start while running");
    assert!(app.stop_confirm_pending, "should open confirm dialog");
}

#[test]
fn stop_confirm_y_sets_stop_requested() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    app.stop_confirm_pending = true;
    press_char(&mut app, 'y');
    assert!(!app.stop_confirm_pending);
    assert!(app.stop_requested);
}

#[test]
fn stop_confirm_n_cancels() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    app.stop_confirm_pending = true;
    press_char(&mut app, 'n');
    assert!(!app.stop_confirm_pending);
    assert!(!app.stop_requested);
}

#[test]
fn stop_confirm_esc_cancels() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    app.stop_confirm_pending = true;
    press(&mut app, KeyCode::Esc);
    assert!(!app.stop_confirm_pending);
    assert!(!app.stop_requested);
}

#[test]
fn stop_confirm_dialog_visible_on_screen() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    app.stop_confirm_pending = true;
    let snap = snapshot_default(&app);
    dump("06_stop_confirm", &snap);
    assert!(contains(&snap, "y") || contains(&snap, "Y"), "confirm hint should mention y");
    // Должно где-то упомянуть «остановить»
    let s = snap.to_lowercase();
    assert!(s.contains("остан"), "dialog should say «остановить» / «остановка»");
}

// ──────────────────────────────────────────────────────────────────────
// Кнопка Stop — цвет/подсветка при фокусе
// ──────────────────────────────────────────────────────────────────────

#[test]
fn stop_button_label_visible_when_running() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    app.queue = vec![Step::Run {
        test_idx: 0,
        scope: chaos_md::catalog::Scope::Node,
    }];
    put_cursor_on_start(&mut app);
    let snap = snapshot_default(&app);
    dump("07_stop_button_focused", &snap);
    assert!(contains(&snap, "СТОП"), "Stop label visible");
}

// ──────────────────────────────────────────────────────────────────────
// Quit
// ──────────────────────────────────────────────────────────────────────

#[test]
fn q_in_idle_quits_immediately() {
    let mut app = fresh_app();
    press_char(&mut app, 'q');
    assert!(app.should_quit);
}

#[test]
fn q_while_running_asks_confirm() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    press_char(&mut app, 'q');
    assert!(!app.should_quit);
    assert!(app.quit_pending);
}

#[test]
fn quit_pending_visible_on_screen() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    app.queue = vec![Step::Run {
        test_idx: 0,
        scope: chaos_md::catalog::Scope::Node,
    }];
    app.quit_pending = true;
    let snap = snapshot_default(&app);
    dump("09_quit_pending", &snap);
    let s = snap.to_lowercase();
    assert!(s.contains("выйти") || s.contains("выход"), "quit hint must be visible");
}

#[test]
fn quit_pending_y_confirms() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    app.quit_pending = true;
    press_char(&mut app, 'y');
    assert!(app.should_quit);
}

#[test]
fn quit_pending_any_other_cancels() {
    let mut app = fresh_app();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    app.quit_pending = true;
    press_char(&mut app, 'n');
    assert!(!app.should_quit);
    assert!(!app.quit_pending);
}

// ──────────────────────────────────────────────────────────────────────
// Диалоги
// ──────────────────────────────────────────────────────────────────────

#[test]
fn i_opens_config_dialog() {
    let mut app = fresh_app();
    press_char(&mut app, 'i');
    assert!(app.config_dialog_open);
}

#[test]
fn i_closes_config_dialog_when_open() {
    let mut app = fresh_app();
    app.config_dialog_open = true;
    press_char(&mut app, 'i');
    assert!(!app.config_dialog_open);
}

#[test]
fn esc_closes_config_dialog() {
    let mut app = fresh_app();
    app.config_dialog_open = true;
    press(&mut app, KeyCode::Esc);
    assert!(!app.config_dialog_open);
}

#[test]
fn c_on_test_sets_pending_check() {
    let mut app = fresh_app();
    press_char(&mut app, 'c');
    assert_eq!(app.pending_check, Some(0));
}

#[test]
fn c_in_check_dialog_closes_it() {
    let mut app = fresh_app();
    app.check_dialog = Some(CheckDialog {
        title: "test".to_string(),
        lines: vec!["one".into(), "two".into()],
        scroll: 0,
        loading: false,
    });
    press_char(&mut app, 'c');
    assert!(app.check_dialog.is_none());
}

// ──────────────────────────────────────────────────────────────────────
// Чекбоксы фаз и dry-run
// ──────────────────────────────────────────────────────────────────────

#[test]
fn space_toggles_phase_node() {
    let mut app = fresh_app();
    let items = chaos_md::app::SelectorItem::all();
    let idx = items.iter().position(|i| matches!(i, chaos_md::app::SelectorItem::PhaseNode)).unwrap();
    app.selector_idx = idx;
    app.phases.node = true;
    press_char(&mut app, ' ');
    assert!(!app.phases.node);
}

#[test]
fn space_toggles_dry_run() {
    let mut app = fresh_app();
    let items = chaos_md::app::SelectorItem::all();
    let idx = items.iter().position(|i| matches!(i, chaos_md::app::SelectorItem::DryRun)).unwrap();
    app.selector_idx = idx;
    let prev = app.dry_run;
    press_char(&mut app, ' ');
    assert_eq!(app.dry_run, !prev);
}

// ──────────────────────────────────────────────────────────────────────
// Очистка / перерисовка
// ──────────────────────────────────────────────────────────────────────

#[test]
fn shift_k_clears_logs() {
    use ratatui::text::Line;
    let mut app = fresh_app();
    app.log_lines.push_back(Line::raw("hello"));
    app.timeline_lines.push_back(Line::raw("ev"));
    press_shift_char(&mut app, 'K');
    assert!(app.log_lines.is_empty());
    assert!(app.timeline_lines.is_empty());
}

#[test]
fn shift_r_triggers_force_redraw() {
    let mut app = fresh_app();
    press_shift_char(&mut app, 'R');
    assert!(app.force_redraw);
}

// ──────────────────────────────────────────────────────────────────────
// Запущенное состояние — статус и подсветка
// ──────────────────────────────────────────────────────────────────────

#[test]
fn running_step_status_shows_position() {
    let mut app = fresh_app();
    app.selected[0] = true;
    app.queue = vec![
        Step::Run { test_idx: 0, scope: chaos_md::catalog::Scope::Node },
        Step::Run { test_idx: 0, scope: chaos_md::catalog::Scope::Dc },
    ];
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    let snap = snapshot_default(&app);
    dump("12_running", &snap);
    assert!(contains(&snap, "[1/2]"), "status counter visible");
    assert!(contains(&snap, "cpu load"), "current test name visible");
}

#[test]
fn pause_step_does_not_paint_previous_test_as_running() {
    // Регрессия: раньше во время Pause-шага в селекторе подсвечивался
    // предыдущий тест как «▶» — это вводило в заблуждение.
    let mut app = fresh_app();
    app.selected[0] = true;
    app.selected[1] = true;
    app.queue = vec![
        Step::Run { test_idx: 0, scope: chaos_md::catalog::Scope::Node },
        Step::Pause { seconds: 60, after_test_idx: Some(0) },
        Step::Run { test_idx: 1, scope: chaos_md::catalog::Scope::Node },
    ];
    app.runner = RunnerStatus::Running {
        step_idx: 1,
        started_at: Instant::now(),
        started_wall: chrono::Local::now(),
    };
    let snap = snapshot_default(&app);
    dump("13_pause", &snap);
    // ▶ — символ «running». Во время Pause его не должно быть НИ У ОДНОГО теста.
    assert!(!contains(&snap, "▶"), "no running mark during pause");
    // А подсказка о паузе должна где-то быть.
    let s = snap.to_lowercase();
    assert!(s.contains("пауз"), "status shows pause");
}
