# Chaos MD — независимый фреймворк хаос-тестирования кластеров YDB

Версия проекта для ивента [Deep Tech Night](https://deeptechnight.ru/) находится в ветке [`deep-tech-night-2026`](https://github.com/ydb-platform/chaos-md/tree/deep-tech-night-2026).

---

YDB (https://ydb.tech/) — масштабируемая распределённая база данных разработки Яндекса, используемая для хранения и обработки критичных данных в облачных и on-premise кластерах.

Chaos MD — набор инструментов для проведения управляемых хаос-экспериментов, имитации сбоев и аномалий на кластере YDB, чтобы протестировать устойчивость системы и выявить скрытые уязвимости до боевой эксплуатации. Скрипты запускаются с управляющей машины по SSH; воздействия (нагрузка CPU/RAM, деградация сети, отказ диска, сигналы процессам, остановка сервисов) применяются на удалённых нодах. Предполагается наличие passwordless sudo на нодах.

Главная ценность этого фреймворка — его независимость и отчуждаемость, он может использоваться на любых стендах, так как не содержит специфических для Яндекса инструментов и зависимостей. Можно взять любую инсталляцию абстрактного кластера YDB и проверить ее на восприимчивость к аномалиям.

Также фреймоврк легко расширяем и спроектирован быть понятным и максимально прозрачным. Внесение хаосов сделано на bash и может быть легко прочитано и изучено.

## Структура проекта

```
.
├── 01-cpu-load.sh … 12-server-stop.sh   # тонкие сценарии тестов
├── env.example.sh                       # образец конфигурации
├── env.sh                               # симлинк на активный env-<name>.sh (gitignored)
├── switch-config.sh                     # переключение конфигурации стенда
├── lib/                                 # инфраструктура: CLI, лог, тикер, SSH-обёртки
│   ├── init.sh         — bootstrap: подключает env.sh и все lib/*
│   ├── term.sh         — цвета ANSI, тикер обратного отсчёта
│   ├── log.sh          — log() → logs/<TEST_NAME>.log
│   ├── timeline.sh     — log_tl() → logs/timeline.log + Grafana-аннотации
│   ├── grafana.sh      — региональные аннотации Grafana (опционально)
│   ├── ssh.sh          — обёртки ssh/scp с подсветкой команд и dry-run
│   ├── cli.sh          — общий парсер флагов (-1/-4/-A/-t/-D/-C/-H/-h)
│   ├── hosts.sh        — преобразование scope → TARGET_HOSTS
│   ├── ports.sh        — разбор YDB_PORTS (диапазоны)
│   ├── net.sh          — выбор сетевого интерфейса для хоста
│   ├── util.sh         — parallel_for_hosts, state_file
│   └── test_runner.sh  — chaos_run_window: apply → wait_with_timer → teardown
├── nemesis/                             # инструменты воздействия
│   ├── blade.sh        — ChaosBlade (тесты 01, 02)
│   ├── tc.sh           — Linux tc: netem + tbf (04, 05, 07)
│   ├── iptables.sh     — iptables/ip6tables (06, 11)
│   ├── disk.sh         — sysfs disk remove (03)
│   ├── proc.sh         — сигналы ydbd (08, 09)
│   └── systemd.sh      — systemctl: stop/restart + rolling upgrade (10, 12)
├── chaos-md/                            # TUI диспетчер Chaos MD (Rust)
├── chaos-md.sh                          # лаунчер TUI из корня репо
├── workload/                            # lifecycle нагрузок (README.md, ARCHITECTURE.md)
├── grafana/                             # установка стека мониторинга (см. grafana/README.md)
├── Makefile                             # сборка Chaos MD: musl x86_64 + aarch64 + macOS
├── build.sh                             # упаковка релизного архива в dist/
├── run-all.sh                           # последовательный прогон всех тестов (headless)
├── rolling-restart.sh                   # плановый роллинг-рестарт кластера
├── prepare-hosts.sh                     # подготовка нод: iptables-цепочка, hping3, gdisk, blade
├── setup-blade.sh                       # установка ChaosBlade на ноды
├── set-net-delay.sh                     # задержка на весь трафик iface (без привязки к портам)
├── all-forwards.sh                      # SSH port-forwarding к Grafana и ноде кластера
├── sync-to-remote.sh                    # синхронизация репо на удалённую машину
├── switch-config.sh                     # переключение симлинка env.sh
├── docs/                                # методики тестов
└── logs/                                # *.log + timeline.log (gitignored)
```

Каждый тест **тонкий** (~30–80 строк): парсинг общих флагов → выбор хостов → `chaos_announce` → `chaos_run_window apply teardown`. Конкретика хаоса задаётся в самих тестах; инструменты — в `nemesis/`; инфраструктура — в `lib/`.

## Быстрый старт

### Из релизного архива

Скачайте последний релиз со [страницы релизов GitHub](https://github.com/smartlime/chaos-md/releases), распакуйте и запустите:

```bash
tar -xzf disarray-YYYY-MM-DD.tar.gz
cd disarray
cp env.example.sh env.sh
# отредактировать env.sh (хосты, порты, интерфейсы, имена юнитов)
./prepare-hosts.sh        # подготовить ноды (один раз)
./01-cpu-load.sh -1 -t 600
```

### Из репозитория

```bash
git clone https://github.com/smartlime/chaos-md.git
cd chaos-md
cp env.example.sh env-stand.sh
# отредактировать env-stand.sh под свой стенд
./switch-config.sh stand  # создаёт симлинк env.sh → env-stand.sh
./prepare-hosts.sh
./01-cpu-load.sh -1 -t 600
```

## Конфигурация стенда

### Переключение конфигураций (`switch-config.sh`)

Для работы с несколькими стендами храните по одному файлу `env-<name>.sh` на стенд (в `.gitignore`):

```bash
./switch-config.sh prestable   # env.sh → env-prestable.sh
./switch-config.sh dev    # env.sh → env-dev.sh
```

`env.sh` — симлинк, можно легко переключать конфигурации.

### Переменные (`env.sh`)

| Переменная | Назначение |
|------------|------------|
| `SINGLE_HOST` | Нода для режима `-1` |
| `DC_HOSTS` | Хосты основного ДЦ для `-4` |
| `DC_ALT_HOSTS` | Альтернативный ДЦ (флаг `-A` в тестах 01, 02, 12) |
| `CLUSTER_HOSTS` | Все ноды (rolling-restart, rolling upgrade, prepare-hosts) |
| `YDB_PORTS` | Порты интерконнекта; список через запятую, диапазоны `31000:32000` |
| `DEFAULT_YDBD_BIN` | Путь к бинарнику ydbd на нодах (по умолчанию `/opt/ydb/bin/ydbd`) |
| `YDBD_STORAGE_SERVICE`, `YDBD_TENANT_SERVICES`, `YDBD_TENANT_UNIT_GLOB` | Имена systemd-юнитов |
| `YDB_MON_PD_PORT` | Порт мониторинга узла хранения (pdisks/vdisks в Grafana; см. `grafana/README.md`) |
| `CHAOS_NET_IPV4`, `CHAOS_NET_IPV6` | Включение стеков для tc (04,05,07) и iptables (06,11) |
| `CHAOS_IPTABLES_CHAIN` | Цепочка iptables для 06/11 (по умолчанию `YDB_CHAOS_FW`) |
| `NET_IFACES`, `NET_IFACES_TABLE` | Список сетевых интерфейсов; таблица «шаблон хоста → список iface» |
| `CHAOS_BLADE_CPU_LOAD_TEMPLATE` и др. | Шаблоны команд ChaosBlade с плейсхолдерами `@CPU_PERCENT@` и т.д. |
| `GRAFANA_URL`, `GRAFANA_TOKEN` | Опционально: аннотации хаос-окон в Grafana |

`env.sh` хранит конфигурацию стенда. Если рядом есть `env.local.sh`, Chaos MD
автоматически загружает его после `env.sh`. Это удобно для секретов
(`GRAFANA_TOKEN`) и локальных путей: файл исключён из Git и может
переопределять любые значения стенда. Автозагрузку можно отключить переменной
`CHAOS_SKIP_LOCAL_ENV=true`.

## Единый CLI всех тестов

| Флаг | Назначение |
|------|------------|
| `-1`, `--single` | Применить хаос на одной ноде |
| `-4`, `--dc` | Применить на основном ДЦ (`DC_HOSTS`) |
| `-A`, `--dc-alt` | Применить на альтернативном ДЦ (`DC_ALT_HOSTS`) |
| `-t`, `--time SEC` | Длительность фазы хаоса (секунды) |
| `-H`, `--host HOST` | Переопределить хост для `-1` |
| `-D`, `--teardown` | Снять хаос (откат, восстановление) |
| `--hold` | Применить хаос и вернуть управление; снять отдельным вызовом `-D` |
| `-C`, `--check [HOST]` | Показать текущее состояние |
| `-N`, `--dry-run` | Не выполнять ssh/scp; только показать, что бы запустилось |
| `-h`, `--help` | Справка с опциями теста; также выводится при запуске без обязательных параметров |

Каждый тест имеет свои дополнительные опции.

## Что вы видите на экране

- **Жёлтым** (`→  ssh <host>  ...`) — каждая значимая команда на удалённый хост.
- **Синим** — командная строка запуска самого теста.
- **Голубым** + `\r` — тикер обратного отсчёта. При перенаправлении в файл тикер подавляется автоматически.
- Логи — `logs/<TEST_NAME>.log`; события для корреляции с метриками — `logs/timeline.log`.

## Снятие хаоса (teardown)

Поведение зависит от немезиса:

| Немезис | Тесты | Как снимается |
|---------|-------|---------------|
| **blade** | 01, 02 | Встроенный `--timeout` в ChaosBlade; `-D` → `blade destroy` |
| **tc** | 04, 05, 07 | Фоновый `nohup` на ноде **и** явный teardown с управляющей машины по `-t` / `-D` |
| **iptables** | 06, 11 | Только явный teardown (`-F` цепочки); фонового таймера на ноде **нет** |
| **disk** | 03 | Фоновый таймер возврата метки + опц. рестарт storage |
| **proc** | 08 | Фоновый `SIGCONT` по `-t`; `-D` — немедленный CONT |
| **proc** | 09 | `--hold`: SIGKILL + stop YDB units; `-D`: start storage + tenant units |
| **systemd** | 10, 12 | Фоновый auto-recovery на ноде; `-D` — досрочный подъём |

Общая схема для tc и iptables (`chaos_run_window`):

1. Применяется на всех `TARGET_HOSTS`.
2. Без `--hold` — ожидание интервала `-t` с тикером и явный teardown.
3. С `--hold` — немедленный возврат в shell; окно остаётся открытым до `-D`.
   У немезисов с удалённым safety-таймером `-t` остаётся страховочным пределом.

Ручное снятие: `./NN-....sh -D` (с `-1`/`-4`/`-A`, если нужно ограничить область).

## TUI диспетчер Chaos MD

Единый экран для выбора тестов, запуска очереди, наблюдения за PTY-логом, ASCII-часами, статусом немезиса и timeline'ом событий. Сборка и архитектура — в [chaos-md/README.md](chaos-md/README.md).

```bash
./chaos-md.sh                                              # интерактивный TUI
./chaos-md.sh --headless --tests 04,05,11 -t 600 -p 300 --node --dc
./chaos-md.sh -d --headless --tests 04 -t 5 -p 3 --node   # dry-run без SSH
./chaos-md.sh --version
```

Нагрузку можно привязать ко всему прогону. Launcher проверит готовность,
запустит её до первого теста и гарантированно остановит при завершении или
прерывании:

```bash
./chaos-md.sh --workload search --headless --tests 12,13 -t 300 --node
```

Конфигурация конкретной нагрузки хранится в `workload/env.local.sh`. Для
повторного прогона с уже проверенной схемой можно добавить
`--skip-workload-prepare`. Независимый ручной запуск остаётся доступен через
`bash workload/manage.sh --type search ...`.

**Dry-run** (`-d`/`--dry-run`): вся цепочка (announce → apply → wait → teardown) без реальных SSH-вызовов. Жёлтые строки показывают, что бы выполнилось; timeline.log пополняется; тикер работает.

### Что требуется в `dist/` для работы тестов

| Файл | Где взять |
|------|-----------|
| `chaosblade-<version>-linux-amd64.tar.gz` | [github проекта Chaos Blade](https://github.com/chaosblade-io/chaosblade/releases/tag/v1.8.0) |
| `ydbd-<version>.tar.xz` _(для теста 10)_ | [ydb.tech :: downloads](https://ydb.tech/docs/ru/downloads/) |

`setup-blade.sh` / `prepare-hosts.sh` ищут ChaosBlade-архив сначала рядом с собой, потом в `dist/`. Тест 10 (`rolling-upgrade`) ищет `*.tar.xz` в `dist/` автоматически (или передайте явно через `-f`).

## Описание тестов

| Тест | Скрипт | Немезис | Описание |
|------|--------|---------|----------|
| [01](docs/01-cpu-load.md) | `01-cpu-load.sh` | blade | Нагрузка CPU (ChaosBlade): одна нода / ДЦ / альт. ДЦ |
| [02](docs/02-mem-load.md) | `02-mem-load.sh` | blade | Нагрузка RAM + page cache (ChaosBlade) |
| [03](docs/03-disk-fail.md) | `03-disk-fail.sh` | disk | Смена GPT partlabel → YDB «теряет» диск; восстановление через PCI rescan |
| [04](docs/04-net-delay.md) | `04-net-delay.sh` | tc/netem | Задержка исходящего трафика по портам `YDB_PORTS` (IPv4+IPv6) |
| [05](docs/05-net-loss.md) | `05-net-loss.sh` | tc/netem | Потеря пакетов на YDB-интерконнекте |
| [06](docs/06-net-drop.md) | `06-net-drop.sh` | iptables | REJECT/DROP интерконнекта на одной ноде (`--drop` для тихого DROP) |
| [07](docs/07-net-bw.md) | `07-net-bw.sh` | tc/tbf | Ограничение полосы исходящего трафика |
| [08](docs/08-proc-freeze.md) | `08-proc-freeze.sh` | proc | Заморозка процессов ydbd (SIGSTOP) |
| [09](docs/09-proc-kill.md) | `09-proc-kill.sh` | proc | SIGKILL процессов ydbd (`-1` или `-4`; `-r` — restart storage) |
| [10](docs/10-rolling-upgrade.md) | `10-rolling-upgrade.sh` | systemd | Замена бинарника ydbd из архива; наблюдение; откат |
| [11](docs/11-dc-drop.md) | `11-dc-drop.sh` | iptables | REJECT/DROP интерконнекта на всём ДЦ |
| [12](docs/12-server-stop.md) | `12-server-stop.sh` | systemd | Остановка tenant + storage с авто-восстановлением |

```bash
./01-cpu-load.sh -1 -p 90 -t 1200 -T 1300  # нагрузка CPU 90% на одной ноде, 20 мин, blade timeout 21:40
./04-net-delay.sh -4 -d 50 -t 600           # задержка 50 мс на всём ДЦ, 10 мин
./06-net-drop.sh -1 -t 600                  # сетевая изоляция iptables на одной ноде, 10 мин
./06-net-drop.sh -1 --drop -t 600           # DROP вместо REJECT
./10-rolling-upgrade.sh -1 -f ./dist/ydbd-package.tar.xz -t 1200  # rolling upgrade на одной ноде
./12-server-stop.sh -4 -t 600              # остановка storage+tenant на всём ДЦ, 10 мин
```

## Вспомогательные скрипты

### `set-net-delay.sh`

Задержка на **весь** трафик интерфейса (без фильтра по портам). Без timeline и Grafana, без авто-снятия.

```bash
./set-net-delay.sh -1 -d 50   # задержка 50 мс на одной ноде
./set-net-delay.sh -C
./set-net-delay.sh -D
```

### `rolling-restart.sh`

Последовательный перезапуск по всем нодам из `CLUSTER_HOSTS`: stop tenant → storage → start storage → tenant.

```bash
./rolling-restart.sh
./rolling-restart.sh -w 60    # ожидание между нодами, сек
./rolling-restart.sh -C
```

### `prepare-hosts.sh`

Подготовка нод к тестам (один раз на стенд): установка цепочки iptables, `hping3`, `gdisk`/`sgdisk`, симлинк `~/blade` из tar.gz, копирование архива rolling upgrade. Флаг `-h` — полный список действий.

### `sync-to-remote.sh`

Синхронизация репозитория на удалённую управляющую машину (rsync). Адрес назначения — из `env.sh`.

### `all-forwards.sh`

SSH port-forwarding туннели к стенду: Grafana и YDB monitoring port последней ноды кластера.

## Общие правила

- Без `-1`/`-4`/`-A` основной сценарий не стартует (предохранитель).
- `-t` — длительность фазы (секунды); `-D` — досрочное снятие.
- **`prepare-hosts.sh`** — один раз на стенд (iptables-цепочка для 06/11, пакеты, blade).
- Логи: `logs/<имя>.log`; события для Grafana: `logs/timeline.log`.
- SSH — без пароля, `BatchMode`. `~/blade` на нодах обязателен для тестов 01 и 02.

## Мониторинг

[grafana/README.md](grafana/README.md) — установка стека VictoriaMetrics + node_exporter + Grafana и настройка аннотаций хаос-окон.

---
*Автор: [Евгений Варнаков](https://t.me/varnakov_ru), продуктовая команда YDB, Яндекс, 2026.*
