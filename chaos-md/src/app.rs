//! Состояние приложения.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use chrono::{DateTime, Local};
use ratatui::text::Line;

use crate::catalog::CATALOG;
use crate::queue::{Phases, Step};

/// Какая зона UI в фокусе.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Selector,
    Log,
    Timeline,
}

/// Что выделено в Selector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectorItem {
    /// Тест по индексу в CATALOG (0..12).
    Test(usize),
    PhaseNode,
    PhaseDc,
    DryRun,
    TimeTest,
    TimeWait,
    Start,
}

impl SelectorItem {
    /// Полный список итемов в порядке навигации сверху вниз.
    pub fn all() -> Vec<SelectorItem> {
        let mut v: Vec<_> = (0..CATALOG.len()).map(SelectorItem::Test).collect();
        v.push(SelectorItem::PhaseNode);
        v.push(SelectorItem::PhaseDc);
        v.push(SelectorItem::DryRun);
        v.push(SelectorItem::TimeTest);
        v.push(SelectorItem::TimeWait);
        v.push(SelectorItem::Start);
        v
    }

    /// К какой функциональной группе относится итем.
    pub fn group(self) -> SelectorGroup {
        match self {
            SelectorItem::Test(_)
            | SelectorItem::PhaseNode
            | SelectorItem::PhaseDc
            | SelectorItem::DryRun => SelectorGroup::TestList,
            SelectorItem::TimeTest | SelectorItem::TimeWait => SelectorGroup::TimeFields,
            SelectorItem::Start => SelectorGroup::StartButton,
        }
    }
}

/// Подгруппа внутри панели Selector — отдельная точка фокуса Tab.
/// Внутри группы навигация ↑/↓; Tab переключает на следующую группу.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectorGroup {
    /// Список тестов + фазы + dry-run — всё, что переключается Space.
    TestList,
    /// Поля ввода времени и паузы.
    TimeFields,
    /// Кнопка Запуск/Стоп.
    StartButton,
}

impl SelectorGroup {
    /// Индекс первого итема этой группы в `SelectorItem::all()`.
    pub fn first_idx(self) -> usize {
        SelectorItem::all()
            .iter()
            .position(|i| i.group() == self)
            .expect("group must contain at least one item")
    }

    /// Индекс последнего итема этой группы.
    pub fn last_idx(self) -> usize {
        SelectorItem::all()
            .iter()
            .rposition(|i| i.group() == self)
            .expect("group must contain at least one item")
    }

    pub fn next(self) -> Option<SelectorGroup> {
        match self {
            SelectorGroup::TestList => Some(SelectorGroup::TimeFields),
            SelectorGroup::TimeFields => Some(SelectorGroup::StartButton),
            SelectorGroup::StartButton => None,
        }
    }
}

#[derive(Debug, Clone)]
pub enum RunnerStatus {
    Idle,
    /// step_idx — индекс в queue; started_at — когда начался текущий шаг.
    Running { step_idx: usize, started_at: Instant, started_wall: DateTime<Local> },
    /// Завершено успешно или с ошибкой; через несколько секунд возвращаемся к Idle.
    Finished { ok: bool, at: Instant },
}

#[derive(Debug, Default, Clone)]
pub struct CurrentEvent {
    pub kind: String,             // "CHAOS_START"
    pub started_wall: Option<DateTime<Local>>,
    pub raw_details: String,      // "net delay  scope=dc  hosts=4  delay=50ms  timeout=600s"
    pub timeout_s: Option<u32>,   // спарсенный timeout=
    pub scope: Option<String>,
    pub hosts: Option<u32>,
}

/// Состояние диалогового окна Check (-C).
pub struct CheckDialog {
    pub title: String,
    pub lines: Vec<String>,
    pub scroll: usize, // визуальные строки (после wrap), 0 = top
    pub loading: bool,
}

pub struct App {
    pub repo_root: PathBuf,
    pub log_dir: PathBuf,
    pub timeline_path: PathBuf,

    // selector
    pub selected: Vec<bool>,
    pub phases: Phases,
    pub time_test_s: u32,
    pub time_wait_s: u32,
    pub selector_idx: usize, // индекс в SelectorItem::all()
    pub selector_group: SelectorGroup, // подгруппа Selector (Tab-стоп)
    /// «Свежий» вход в поле — первая цифра заменит значение, дальше дополняет.
    pub time_field_pristine: bool,

    // фокус
    pub focus: Focus,

    // лог теста (центральная зона)
    pub log_lines: VecDeque<Line<'static>>,
    pub log_current: Option<String>,
    pub log_scroll: usize, // 0 = к низу
    pub log_max: usize,

    // timeline (нижняя зона)
    pub timeline_lines: VecDeque<Line<'static>>,
    pub timeline_scroll: usize,
    pub timeline_max: usize,

    // status (правый-низ)
    pub current_event: Option<CurrentEvent>,

    // очередь и runner
    pub queue: Vec<Step>,
    pub runner: RunnerStatus,

    // dry-run: пропихиваем --dry-run в каждый bash-вызов
    pub dry_run: bool,

    // подтверждение выхода
    pub quit_pending: bool,

    // флаг «надо выйти после следующего тика»
    pub should_quit: bool,

    // диалог Check: Some = открыт
    pub check_dialog: Option<CheckDialog>,
    // запрос на открытие диалога (test_idx в CATALOG)
    pub pending_check: Option<usize>,

    // диалог конфигурации
    pub config_dialog_open: bool,
    pub env_config: HashMap<String, String>,

    // остановка текущей очереди тестов
    pub chaos_started_at: Option<Instant>,
    pub force_redraw: bool,
    pub stop_requested: bool,
    /// Открыто окошко подтверждения остановки.
    pub stop_confirm_pending: bool,
    /// Идёт teardown по запросу пользователя — следующий Exited переводит в Idle.
    pub stop_teardown_running: bool,

    // индексы завершённых тестов (для отображения галок)
    pub finished_tests: Vec<bool>,
}

impl App {
    pub fn new(repo_root: PathBuf) -> Self {
        let log_dir = repo_root.join("logs");
        let timeline_path = log_dir.join("timeline.log");
        let env_config = parse_env_sh(&repo_root.join("env.sh"));
        Self {
            repo_root,
            log_dir,
            timeline_path,
            selected: vec![false; CATALOG.len()],
            phases: Phases { node: true, dc: true, dc_alt: false },
            time_test_s: 1200,
            time_wait_s: 600,
            selector_idx: 0,
            selector_group: SelectorGroup::TestList,
            time_field_pristine: true,
            focus: Focus::Selector,
            log_lines: VecDeque::new(),
            log_current: None,
            log_scroll: 0,
            log_max: 10_000,
            timeline_lines: VecDeque::new(),
            timeline_scroll: 0,
            timeline_max: 5_000,
            current_event: None,
            queue: Vec::new(),
            runner: RunnerStatus::Idle,
            dry_run: true,
            quit_pending: false,
            should_quit: false,
            check_dialog: None,
            pending_check: None,
            config_dialog_open: false,
            env_config,
            chaos_started_at: None,
            force_redraw: false,
            stop_requested: false,
            stop_confirm_pending: false,
            stop_teardown_running: false,
            finished_tests: vec![false; CATALOG.len()],
        }
    }

    pub fn current_selector_item(&self) -> SelectorItem {
        SelectorItem::all()[self.selector_idx]
    }

    /// Передвинуть курсор в селекторе с учётом текущей группы. Курсор не
    /// «выпрыгивает» из группы — для перехода к следующей группе нужно Tab.
    pub fn selector_move(&mut self, delta: isize) {
        let all = SelectorItem::all();
        let new = self.selector_idx as isize + delta;
        if new < 0 || new >= all.len() as isize {
            return;
        }
        let new_idx = new as usize;
        if all[new_idx].group() != self.selector_group {
            return;
        }
        self.selector_idx = new_idx;
        if self.selector_group == SelectorGroup::TimeFields {
            self.time_field_pristine = true;
        }
    }

    /// Сделать активной указанную группу и поставить курсор на её первый итем.
    pub fn enter_selector_group(&mut self, group: SelectorGroup) {
        self.selector_group = group;
        self.selector_idx = group.first_idx();
        if group == SelectorGroup::TimeFields {
            self.time_field_pristine = true;
        }
    }

    /// Текущий running step, если есть.
    pub fn running_step(&self) -> Option<(&Step, Instant)> {
        if let RunnerStatus::Running { step_idx, started_at, .. } = &self.runner {
            self.queue.get(*step_idx).map(|s| (s, *started_at))
        } else {
            None
        }
    }

    pub fn step_count(&self) -> (usize, usize) {
        match &self.runner {
            RunnerStatus::Running { step_idx, .. } => (step_idx + 1, self.queue.len()),
            _ => (0, self.queue.len()),
        }
    }

    pub fn is_running(&self) -> bool {
        matches!(self.runner, RunnerStatus::Running { .. })
    }
}

/// Сколько секунд прошло с момента старта current_event (CHAOS_START).
pub fn elapsed_since(started: DateTime<Local>) -> u32 {
    let now = Local::now();
    (now - started).num_seconds().max(0) as u32
}

pub fn fmt_hms(s: u32) -> String {
    if s >= 3600 {
        format!("{:02}:{:02}:{:02}", s / 3600, (s % 3600) / 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

#[allow(dead_code)]
pub const TICK: Duration = Duration::from_millis(250);

/// Читает env.sh и возвращает map KEY → value.
/// Поддерживает простые присвоения и bash-массивы (join через пробел).
pub fn parse_env_sh(path: &Path) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let Ok(text) = std::fs::read_to_string(path) else { return map; };

    let mut iter = text.lines().peekable();
    while let Some(line) = iter.next() {
        let trimmed = line.trim();
        // Пропускаем комментарии, пустые строки и команды
        if trimmed.is_empty() || trimmed.starts_with('#') { continue; }

        // Убираем необязательный префикс export
        let trimmed = trimmed.strip_prefix("export ").unwrap_or(trimmed);

        let Some(eq_pos) = trimmed.find('=') else { continue; };
        let key = trimmed[..eq_pos].trim().to_string();
        if key.contains(' ') || key.is_empty() { continue; }
        let val_part = trimmed[eq_pos + 1..].trim();

        // Массив: KEY=( или KEY=(item...
        if val_part.starts_with('(') {
            let mut items: Vec<String> = Vec::new();
            let first_line = val_part.trim_start_matches('(');
            let (done, tail) = collect_array_items(first_line, &mut items);
            if !done {
                for cont in iter.by_ref() {
                    let (done, _) = collect_array_items(cont.trim(), &mut items);
                    if done { break; }
                    let _ = tail;
                }
            }
            map.insert(key, items.join(" "));
            continue;
        }

        // Простое значение (возможно в кавычках)
        let value = strip_quotes(val_part)
            .split('#').next().unwrap_or("").trim().to_string();
        map.insert(key, value);
    }
    map
}

fn collect_array_items(s: &str, items: &mut Vec<String>) -> (bool, &'static str) {
    let s = s.trim();
    // Есть закрывающая скобка?
    let (body, done) = if let Some(pos) = s.find(')') {
        (&s[..pos], true)
    } else {
        (s, false)
    };
    for token in body.split_whitespace() {
        let t = token.trim_matches(|c| c == '"' || c == '\'');
        if !t.is_empty() && !t.starts_with('#') {
            items.push(t.to_string());
        }
    }
    (done, "")
}

fn strip_quotes(s: &str) -> &str {
    if (s.starts_with('"') && s.ends_with('"')) ||
       (s.starts_with('\'') && s.ends_with('\'')) {
        &s[1..s.len() - 1]
    } else {
        s
    }
}
