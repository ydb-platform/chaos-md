//! Хелперы для UI-снапшот-тестов.
//!
//! Идея: создаём `App` с предсказуемым состоянием (без чтения файла state),
//! гоняем `input::on_key`, рендерим в `TestBackend` и превращаем буфер в
//! plain-string «скриншот».

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::Terminal;

use chaos_md::app::App;
use chaos_md::input::{self, KeyOutcome};
use chaos_md::ui;

/// Стандартный размер «терминала» в тестах. Соответствует обычной ширине
/// конфига Chaos MD: 24 (selector) + 40 (centre min) + 23 (right) + бордеры.
pub const TEST_W: u16 = 110;
pub const TEST_H: u16 = 38;

/// Подготовить чистый App в изолированном temp-каталоге, чтобы тесты не
/// сохраняли state в репозиторий и не зависели от env.sh.
pub fn fresh_app() -> App {
    let dir = unique_tmpdir();
    std::fs::create_dir_all(&dir).ok();
    let mut app = App::new(dir);
    // По умолчанию dry_run=true. Для большинства тестов оставляем как есть.
    app.dry_run = true;
    app
}

fn unique_tmpdir() -> PathBuf {
    static SEQ: AtomicUsize = AtomicUsize::new(0);
    let pid = std::process::id();
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("chaos-md-test-{pid}-{nanos}-{seq}"))
}

/// Отправить одну клавишу без модификаторов.
pub fn press(app: &mut App, code: KeyCode) -> KeyOutcome {
    input::on_key(app, KeyEvent::new(code, KeyModifiers::NONE))
}

/// Отправить символ.
pub fn press_char(app: &mut App, c: char) -> KeyOutcome {
    press(app, KeyCode::Char(c))
}

/// Отправить Shift+символ.
pub fn press_shift_char(app: &mut App, c: char) -> KeyOutcome {
    input::on_key(app, KeyEvent::new(KeyCode::Char(c), KeyModifiers::SHIFT))
}

/// Отправить серию клавиш.
pub fn press_many(app: &mut App, codes: &[KeyCode]) {
    for c in codes {
        press(app, *c);
    }
}

/// Снять «скриншот» текущего экрана с указанным размером.
pub fn snapshot(app: &App, w: u16, h: u16) -> String {
    let backend = TestBackend::new(w, h);
    let mut term = Terminal::new(backend).expect("terminal");
    term.draw(|f| ui::draw(f, app)).expect("draw");
    buffer_to_string(term.backend().buffer())
}

/// Снять «скриншот» по умолчанию (TEST_W × TEST_H).
pub fn snapshot_default(app: &App) -> String {
    snapshot(app, TEST_W, TEST_H)
}

fn buffer_to_string(buf: &Buffer) -> String {
    let mut out = String::with_capacity((buf.area.width as usize + 1) * buf.area.height as usize);
    for y in 0..buf.area.height {
        for x in 0..buf.area.width {
            let cell = &buf[(x, y)];
            out.push_str(cell.symbol());
        }
        // обрезаем хвост пробелов справа, чтобы дифф был стабильнее
        while out.ends_with(' ') {
            out.pop();
        }
        out.push('\n');
    }
    out
}

/// Содержит ли снэпшот заданную подстроку (после нормализации пробелов).
pub fn contains(snap: &str, needle: &str) -> bool {
    snap.contains(needle)
}

/// Сколько раз подстрока встречается.
pub fn count(snap: &str, needle: &str) -> usize {
    if needle.is_empty() { return 0; }
    let mut n = 0usize;
    let mut start = 0usize;
    while let Some(p) = snap[start..].find(needle) {
        n += 1;
        start += p + needle.len();
    }
    n
}
