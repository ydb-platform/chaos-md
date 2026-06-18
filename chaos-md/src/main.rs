#![allow(dead_code)]

use std::io::{self, stdout};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use chrono::Local;
use clap::Parser;
use crossterm::event::{Event, EventStream, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use futures::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::Terminal;
use tokio::sync::mpsc;

use chaos_md::ansi::LogParser;
use chaos_md::app::{App, CheckDialog, CurrentEvent, RunnerStatus, SelectorItem};
use chaos_md::catalog::CATALOG;
use chaos_md::input::{self, KeyOutcome};
use chaos_md::queue::{self, Phases, Step};
use chaos_md::runner::{describe, spawn_step, RunnerEvent, Running};
use chaos_md::state;
use chaos_md::theme as col;
use chaos_md::ui;
use chaos_md::watcher::{self, TimelineLine, WatcherEvent};

/// События от фоновой команды `./NN-test.sh -C`.
enum CheckLine {
    Text(String),
    Done,
}

#[derive(Parser, Debug)]
#[command(name = "chaos-md", version, about = "TUI for YDB chaos tests")]
struct Cli {
    /// Корень репозитория (где лежат NN-*.sh, env.sh, lib/, nemesis/).
    #[arg(long, value_name = "PATH")]
    root: Option<PathBuf>,

    /// Headless-режим: запустить выбранные тесты без TUI.
    #[arg(long)]
    headless: bool,

    /// CSV id тестов для headless (например: 04,05,11). По умолчанию — все.
    #[arg(long)]
    tests: Option<String>,

    /// Длительность фазы -t, секунды.
    #[arg(short = 't', long, default_value_t = 1200)]
    time_test: u32,

    /// Пауза между шагами, секунды.
    #[arg(short = 'p', long, default_value_t = 600)]
    time_wait: u32,

    /// Включить фазу -1 (node).
    #[arg(long, default_value_t = true)]
    node: bool,

    /// Включить фазу -4 (dc).
    #[arg(long, default_value_t = true)]
    dc: bool,

    /// Dry-run: тесты не выполняют ssh/scp, только показывают что бы запустилось.
    /// Используется для отладки UI и сценариев без реального стенда.
    #[arg(short = 'd', long)]
    dry_run: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let root = match cli.root.clone() {
        Some(p) => p,
        None => std::env::current_dir().context("getcwd")?,
    };
    let root = root
        .canonicalize()
        .with_context(|| format!("canonicalize {root:?}"))?;

    if cli.headless {
        return run_headless(&cli, &root).await;
    }
    run_tui(&root, cli.dry_run).await
}

// =============================================================================
// TUI
// =============================================================================

async fn run_tui(root: &PathBuf, dry_run: bool) -> Result<()> {
    enable_raw_mode()?;
    let mut out = stdout();
    execute!(out, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(out);
    let mut term = Terminal::new(backend)?;
    term.hide_cursor()?;

    let result = event_loop(&mut term, root, dry_run).await;

    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;
    term.show_cursor()?;
    result
}

async fn event_loop<B: ratatui::backend::Backend>(
    term: &mut Terminal<B>,
    root: &PathBuf,
    dry_run: bool,
) -> Result<()> {
    let mut app = App::new(root.clone());
    app.dry_run = dry_run;
    let _ = state::load(root, &mut app);
    let mut log_parser = LogParser::new();

    let (wtx, mut wrx) = mpsc::unbounded_channel::<WatcherEvent>();
    let _watcher_handle = watcher::spawn(app.timeline_path.clone(), wtx)
        .context("starting timeline watcher")?;

    let mut current_running: Option<Running> = None;
    let mut current_runner_rx: Option<mpsc::UnboundedReceiver<RunnerEvent>> = None;
    let mut start_pending = false;
    let mut check_rx: Option<mpsc::UnboundedReceiver<CheckLine>> = None;

    let mut events = EventStream::new();
    let mut tick = tokio::time::interval(Duration::from_millis(50)); // 20 FPS для плавной анимации
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        if app.force_redraw {
            app.force_redraw = false;
            term.clear()?;
        }
        term.draw(|f| ui::draw(f, &app))?;

        if app.should_quit {
            if let Some(r) = &mut current_running {
                let _ = r.kill();
            }
            return Ok(());
        }

        // Если очередь готова и Idle — стартуем.
        if start_pending && matches!(app.runner, RunnerStatus::Idle) && !app.queue.is_empty() {
            start_pending = false;
            start_queue(&mut app, &mut current_running, &mut current_runner_rx, term)?;
        }

        // Запрос на открытие диалога Check.
        if let Some(test_idx) = app.pending_check.take() {
            open_check_dialog(&mut app, test_idx, &mut check_rx, root);
        }

        tokio::select! {
            biased;

            maybe_evt = events.next() => {
                if let Some(Ok(Event::Key(k))) = maybe_evt {
                    if k.kind == KeyEventKind::Press {
                        let outcome = input::on_key(&mut app, k);
                        if outcome == KeyOutcome::StartQueue {
                            app.queue = queue::build(&app.selected, app.phases, app.time_wait_s);
                            if !app.queue.is_empty() {
                                app.runner = RunnerStatus::Idle;
                                start_pending = true;
                            }
                        }
                    }
                }
            }

            Some(WatcherEvent::Line(tl)) = wrx.recv() => {
                push_timeline_event(&mut app, tl);
            }

            maybe_runner_evt = recv_runner(&mut current_runner_rx) => {
                let step_done = match maybe_runner_evt {
                    Some(re) => handle_runner_event(&mut app, &mut log_parser, re),
                    None => current_running.is_some(),
                };
                if step_done {
                    current_running = None;
                    current_runner_rx = None;
                    if app.stop_teardown_running {
                        // Завершился teardown, запущенный по запросу пользователя
                        app.stop_teardown_running = false;
                        app.runner = RunnerStatus::Idle;
                        app.queue.clear();
                        app.finished_tests.clear();
                        app.finished_tests.resize(app.selected.len(), false);
                        push_local_log(&mut app, "[остановлено пользователем]".to_string());
                    } else {
                        advance_queue(&mut app, &mut current_running, &mut current_runner_rx, term)?;
                    }
                }
            }

            maybe_check = recv_check(&mut check_rx) => {
                match maybe_check {
                    Some(CheckLine::Text(line)) => {
                        if let Some(d) = &mut app.check_dialog {
                            d.lines.push(line);
                        }
                    }
                    Some(CheckLine::Done) | None => {
                        if let Some(d) = &mut app.check_dialog {
                            d.loading = false;
                        }
                        check_rx = None;
                    }
                }
            }

            _ = tick.tick() => {
                if app.stop_requested && app.is_running() {
                    app.stop_requested = false;
                    request_stop(&mut app, &mut current_running, &mut current_runner_rx, term)?;
                }
            }
        }
    }
}

/// Реализация запроса на остановку. Если у текущего шага есть `needs_teardown`,
/// запускаем `-D` как новый шаг, ставим флаг `stop_teardown_running`.
/// Иначе сразу Idle.
fn request_stop<B: ratatui::backend::Backend>(
    app: &mut App,
    current_running: &mut Option<Running>,
    current_runner_rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
    term: &mut Terminal<B>,
) -> Result<()> {
    // Найдём, какой тест сейчас прогоняется (если есть). Запускаем -D для
    // ЛЮБОГО Run-шага (а не только needs_teardown), потому что у каждого
    // bash-теста -D идемпотентен и должен снимать локальные изменения,
    // даже если основной цикл не оставил «висящий» хаос.
    let teardown_idx: Option<usize> = if let RunnerStatus::Running { step_idx, .. } = &app.runner {
        app.queue.get(*step_idx).and_then(|st| match st {
            Step::Run { test_idx, .. } => Some(*test_idx),
            Step::Teardown { test_idx } => Some(*test_idx),
            Step::Pause { .. } => None,
        })
    } else { None };

    // Прибиваем текущий процесс.
    if let Some(r) = current_running.as_mut() {
        let _ = r.kill();
    }
    *current_running = None;
    *current_runner_rx = None;
    app.log_current = None;
    app.chaos_started_at = None;
    app.current_event = None;

    push_local_log(app, "[запрошена остановка]".to_string());

    if let Some(idx) = teardown_idx {
        // Запускаем teardown-шаг.
        app.queue = vec![Step::Teardown { test_idx: idx }];
        app.runner = RunnerStatus::Running {
            step_idx: 0,
            started_at: Instant::now(),
            started_wall: Local::now(),
        };
        app.stop_teardown_running = true;
        spawn_current(app, current_running, current_runner_rx, term)?;
    } else {
        // Нечего сворачивать — сразу Idle.
        app.runner = RunnerStatus::Idle;
        app.queue.clear();
        app.finished_tests.clear();
        app.finished_tests.resize(app.selected.len(), false);
        push_local_log(app, "[остановлено пользователем]".to_string());
    }
    Ok(())
}

/// Выбрать recv() из current_runner_rx, либо вечно ждать.
async fn recv_runner(
    rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
) -> Option<RunnerEvent> {
    match rx {
        Some(r) => r.recv().await,
        None => std::future::pending::<Option<RunnerEvent>>().await,
    }
}

async fn recv_check(rx: &mut Option<mpsc::UnboundedReceiver<CheckLine>>) -> Option<CheckLine> {
    match rx {
        Some(r) => r.recv().await,
        None => std::future::pending::<Option<CheckLine>>().await,
    }
}

// =============================================================================
// Очередь
// =============================================================================

fn start_queue<B: ratatui::backend::Backend>(
    app: &mut App,
    current_running: &mut Option<Running>,
    current_runner_rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
    term: &mut Terminal<B>,
) -> Result<()> {
    if app.queue.is_empty() {
        return Ok(());
    }
    app.log_lines.clear();
    app.log_current = None;
    app.timeline_lines.clear();
    app.runner = RunnerStatus::Running {
        step_idx: 0,
        started_at: Instant::now(),
        started_wall: Local::now(),
    };
    spawn_current(app, current_running, current_runner_rx, term)
}

fn advance_queue<B: ratatui::backend::Backend>(
    app: &mut App,
    current_running: &mut Option<Running>,
    current_runner_rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
    term: &mut Terminal<B>,
) -> Result<()> {
    let (step_idx, next_idx) = match &app.runner {
        RunnerStatus::Running { step_idx, .. } => (*step_idx, step_idx + 1),
        _ => return Ok(()),
    };

    if let Some(Step::Run { test_idx, .. }) = app.queue.get(step_idx) {
        app.finished_tests[*test_idx] = true;
    }

    if next_idx >= app.queue.len() {
        app.runner = RunnerStatus::Finished {
            ok: true,
            at: Instant::now(),
        };
        app.finished_tests.clear();
        app.finished_tests.resize(app.selected.len(), false);
        return Ok(());
    }
    app.runner = RunnerStatus::Running {
        step_idx: next_idx,
        started_at: Instant::now(),
        started_wall: Local::now(),
    };

    let test_idx_to_select = app.queue.get(next_idx).and_then(|st| {
        match st {
            Step::Run { test_idx, .. } => Some(*test_idx),
            Step::Pause { after_test_idx, .. } => *after_test_idx,
            Step::Teardown { test_idx } => Some(*test_idx),
        }
    });

    if let Some(test_idx) = test_idx_to_select {
        let items = SelectorItem::all();
        for (i, item) in items.iter().enumerate() {
            if *item == SelectorItem::Test(test_idx) {
                app.selector_idx = i;
                break;
            }
        }
    }

    spawn_current(app, current_running, current_runner_rx, term)
}

fn spawn_current<B: ratatui::backend::Backend>(
    app: &mut App,
    current_running: &mut Option<Running>,
    current_runner_rx: &mut Option<mpsc::UnboundedReceiver<RunnerEvent>>,
    term: &mut Terminal<B>,
) -> Result<()> {
    let RunnerStatus::Running { step_idx, .. } = app.runner else {
        return Ok(());
    };
    let step: Step = app.queue[step_idx].clone();

    let size = term.size()?;
    let cols = size.width.saturating_sub(28).saturating_sub(24).max(40);
    let rows = size.height.saturating_sub(11).max(10);

    push_log_line(app, Line::raw(""));
    push_local_log(app, format!("¤ {}", describe(&step, app.time_test_s)));

    match spawn_step(&app.repo_root, &step, app.time_test_s, app.dry_run, cols, rows) {
        Ok((running, rx)) => {
            *current_running = Some(running);
            *current_runner_rx = Some(rx);
        }
        Err(e) => {
            push_local_log(app, format!("ОШИБКА spawn: {e}"));
            app.runner = RunnerStatus::Finished {
                ok: false,
                at: Instant::now(),
            };
        }
    }
    Ok(())
}

/// Возвращает true, если step завершён (Exited).
fn handle_runner_event(app: &mut App, parser: &mut LogParser, evt: RunnerEvent) -> bool {
    match evt {
        RunnerEvent::Bytes(b) => {
            let upd = parser.feed(&b);
            for line in upd.new_lines {
                push_log_line(app, line);
            }
            if let Some(ref cur) = upd.current_line {
                if cur.contains('⏱') && app.chaos_started_at.is_none() {
                    app.chaos_started_at = Some(Instant::now());
                }
            }
            app.log_current = upd.current_line;
            false
        }
        RunnerEvent::Exited { ok, code } => {
            push_local_log(
                app,
                format!(
                    "[exit code={}{}]",
                    code.map(|c| c.to_string())
                        .unwrap_or_else(|| "?".into()),
                    if ok { "" } else { ", FAIL" },
                ),
            );
            *parser = LogParser::new();
            app.log_current = None;
            app.chaos_started_at = None;
            true
        }
    }
}

fn push_log_line(app: &mut App, line: Line<'static>) {
    if app.log_lines.len() >= app.log_max {
        app.log_lines.pop_front();
    }
    app.log_lines.push_back(line);
}

fn push_local_log(app: &mut App, text: String) {
    let line = Line::from(Span::styled(
        text,
        Style::default()
            .fg(col::DIM)
            .add_modifier(Modifier::ITALIC),
    ));
    push_log_line(app, line);
}

fn push_timeline_event(app: &mut App, tl: TimelineLine) {
    use ratatui::style::Color;
    let color = match tl.kind.as_str() {
        "CHAOS_START" => Color::Green,
        "CHAOS_END" => Color::Cyan,
        "CHAOS_CANCEL" => Color::Red,
        _ => Color::White,
    };
    let line = Line::from(vec![
        Span::raw(
            tl.started_wall
                .map(|d| d.format("%H:%M:%S ").to_string())
                .unwrap_or_else(|| "?? ".to_string()),
        ),
        Span::styled(
            format!("{:14}", tl.kind),
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
        Span::raw(tl.details.clone()),
    ]);

    if app.timeline_lines.len() >= app.timeline_max {
        app.timeline_lines.pop_front();
    }
    app.timeline_lines.push_back(line);

    if tl.kind == "CHAOS_START" {
        let ev: CurrentEvent = tl.to_current_event();
        app.current_event = Some(ev);
    } else if tl.kind.starts_with("CHAOS_END") || tl.kind == "CHAOS_CANCEL" {
        app.current_event = None;
    }
}

// =============================================================================
// Check dialog
// =============================================================================

fn open_check_dialog(
    app: &mut App,
    test_idx: usize,
    check_rx: &mut Option<mpsc::UnboundedReceiver<CheckLine>>,
    root: &std::path::Path,
) {
    let entry = &CATALOG[test_idx];
    app.check_dialog = Some(CheckDialog {
        title: format!("Check: {} {}", entry.id, entry.title),
        lines: Vec::new(),
        scroll: 0,
        loading: true,
    });

    let (tx, rx) = mpsc::unbounded_channel::<CheckLine>();
    *check_rx = Some(rx);

    let file = format!("./{}", entry.file);
    let root = root.to_path_buf();

    tokio::task::spawn_blocking(move || {
        use std::process::{Command, Stdio};
        let out = Command::new("bash")
            .arg(&file)
            .arg("-C")
            .current_dir(&root)
            .env("TERM", "dumb")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        match out {
            Err(e) => {
                let _ = tx.send(CheckLine::Text(format!("Ошибка запуска: {e}")));
            }
            Ok(output) => {
                let combined = [output.stdout, b"\n--- stderr ---\n".to_vec(), output.stderr].concat();
                for line in String::from_utf8_lossy(&combined).lines() {
                    if tx.send(CheckLine::Text(line.to_string())).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = tx.send(CheckLine::Done);
    });
}

// =============================================================================
// Headless
// =============================================================================

async fn run_headless(cli: &Cli, root: &PathBuf) -> Result<()> {
    use std::io::Write;
    let mut selected = vec![false; chaos_md::catalog::CATALOG.len()];
    if let Some(csv) = &cli.tests {
        for id in csv.split(',') {
            let id = id.trim();
            if let Some(i) = chaos_md::catalog::find_by_id(id) {
                selected[i] = true;
            } else {
                eprintln!("Неизвестный test id: {id}");
            }
        }
    } else {
        for s in selected.iter_mut() {
            *s = true;
        }
    }
    let phases = Phases {
        node: cli.node,
        dc: cli.dc,
        dc_alt: false,
    };
    let queue = queue::build(&selected, phases, cli.time_wait);

    println!("Очередь ({} шагов):", queue.len());
    for (i, st) in queue.iter().enumerate() {
        println!("  {}. {}", i + 1, describe(st, cli.time_test));
    }
    println!();

    for (i, st) in queue.iter().enumerate() {
        println!("=== [{}/{}] {} ===", i + 1, queue.len(), describe(st, cli.time_test));
        let _ = std::io::stdout().flush();
        let (mut running, mut rx) = spawn_step(root, st, cli.time_test, cli.dry_run, 120, 30)?;
        while let Some(evt) = rx.recv().await {
            match evt {
                RunnerEvent::Bytes(b) => {
                    std::io::stdout().write_all(&b).ok();
                }
                RunnerEvent::Exited { ok, code } => {
                    println!("[exit {:?} ok={ok}]", code);
                    break;
                }
            }
        }
        let _ = running.kill();
    }
    println!("Готово.");
    Ok(())
}
