# Workload lifecycle

`manage.sh` даёт единый интерфейс для разных генераторов нагрузки. Сейчас
доступны adapters `search` (воркшоп по поиску) и `stock` (старый штатный YDB
workload).

Архитектурный контракт, жизненный цикл и правила добавления adapters описаны в
[ARCHITECTURE.md](ARCHITECTURE.md).

```sh
cp manager.env.example.sh env.local.sh
# отредактировать пути и connection config

bash manage.sh --type search info
bash manage.sh --type search prepare
bash manage.sh --type search --profile overview start
bash manage.sh --type search status
bash manage.sh --type search stop
```

`start` запускает процесс в фоне, пишет PID в `workload/.state/`, ждёт health
endpoint и сохраняет stdout/stderr в `logs/workload/search.log`. Команда `run`
оставляет процесс в foreground; это удобно для отдельного smoke-теста.

Именованный профиль выбирает готовый режим нагрузки. При каждом `start`/`stop`
manager пишет событие в timeline и открывает/закрывает региональную аннотацию
Grafana. Переключение намеренно состоит из двух явных команд:

```sh
bash manage.sh --type search stop
bash manage.sh --type search --profile fulltext-partition start
```

Это создаёт понятную границу профилей на графике. Если процесс уже запущен с
другим профилем, второй `start` завершается ошибкой, а не меняет нагрузку
незаметно. Действия с индексами проходят через тот же adapter и дают точечную
засечку:

```sh
bash manage.sh --type search action partitions
bash manage.sh --type search action partition-fixed fulltext
bash manage.sh --type search action partition-auto fulltext
bash manage.sh --type search action partition-elastic all
bash manage.sh --type search action reset-fulltext
bash manage.sh --type search action reset-vector
```

`partition-elastic` оставляет автосплит по нагрузке включённым, но применяет
настроенные workload-проектом нижние границы числа партиций. Это сохраняет
подготовленную ёмкость между этапами демонстрации.

`reset-fulltext` пересоздаёт только полнотекстовый индекс и ждёт его готовности.
Основная таблица и векторный индекс не изменяются; действие предназначено для
возврата демонстрационного стенда к одной исходной партиции индекса.

`reset-vector` пересоздаёт только векторный индекс и также ждёт его готовности.
DDL и параметры дерева задаёт подключённый workload-проект; chaos-md лишь
передаёт действие через общий адаптер.

Диагностическое действие `partitions` только читает состояние и не создаёт
Grafana-аннотацию. Аннотации `WORKLOAD_ACTION` остаются только у изменяющих
состояние действий, например `partition-elastic` и `reset-fulltext`.

Число dynamic-узлов меняется отдельно и безопасно:

```sh
bash cluster/dynamic-nodes.sh set 1
bash cluster/dynamic-nodes.sh set 3
```

Скрипт работает только с явно настроенным `YDBD_DYNAMIC_SERVICE`, сначала
запускает целевые узлы и лишь затем выключает лишние. Storage service защищён
от случайного выбора. Уже активные и уже остановленные сервисы не трогаются;
`systemctl start/stop` отправляется с `--no-block`, а каждый короткий SSH-вызов
ограничен `DYNAMIC_NODE_COMMAND_TIMEOUT_SECONDS` (по умолчанию 20 секунд).

Основной демонстрационный вариант — запуск из корня вместе с chaos-прогоном:

```sh
./chaos-md.sh --workload search --headless --tests 12,13 -t 300 --node
```

Локальные smoke-тесты lifecycle и adapters (не требуют настоящего кластера):

```sh
bash workload/tests/manager-smoke.sh
bash workload/tests/search-adapter-smoke.sh
bash workload/tests/launcher-smoke.sh
```

## Старый stock workload

Самодостаточный модуль нагрузки для хаос-тестов. Поверх штатного
[`ydb workload stock`](https://ydb.tech/docs/ru/reference/ydb-cli/commands/workload/stock):
парсит вывод и пушит метрики (RPS / latency / errors) в VictoriaMetrics в схеме
`ydb_workload_*` (теги `application`, `scenario`, `statut`).

Зависимости на target-хосте: `bash 4+`, `awk`, `curl`, `ydb` CLI с настроенным
профилем или endpoint-ом.

## Топология развёртывания

```
    [dev]                  [ydb-client]              [кластер YDB]
      │                         │                           │
      │  bash deploy.sh         │                           │
      │ ──rsync workload/──────►│                           │
      │                         │  bash workload.sh run     │
      │                         │ ──ydb workload stock─────►│
      │                    tmux │◄──── метрики (stdout) ────│
      │   (dev выключаем)       │                           │
                                │  POST line-protocol       │
                                │ ──────────────────────────►VictoriaMetrics
```

- **Редактирование** (`env.local.sh`, параметры) — на ноуте.
- **Весь runtime** (init, run, cleanup) — на `ydb-client` в tmux.
- После деплоя dev можно выключить — нагрузка продолжается.

## Первичная настройка (один раз)

### 1. На ноуте — конфигурация

```sh
cd workload
cp env.example.sh env.local.sh
vim env.local.sh            # WL_REMOTE_HOST, WL_YDB_ENDPOINT, WL_YDB_DATABASE, WL_VM_WRITE_URL
bash workload.sh info       # проверить, всё ли задано
```

### 2. Деплой на ydb-client

```sh
bash deploy.sh -n           # dry-run: показать что отправится
bash deploy.sh              # rsync workload/ → ${WL_REMOTE_HOST}:~/${WL_REMOTE_DEST}/
```

`env.local.sh` по умолчанию **не** копируется. Если на ydb-client нужны те же
значения — либо `--with-local`, либо создайте `env.local.sh` прямо там.

### 3. На ydb-client — установка ydb CLI (если нет)

```sh
ssh ydb-client
ydb version 2>/dev/null || curl -sSL https://storage.yandexcloud.net/yandexcloud-ydb/install.sh | bash
# добавляет ~/ydb в PATH; применить в текущей сессии:
export PATH="$HOME/ydb:$PATH"
```

Настроить профиль (избавляет от повторного указания endpoint/database):

```sh
ydb config profile create chaos \
  --endpoint grpc://ydb-node-01:2135 \
  --database /Root/db1
# проверить доступ:
ydb -p chaos scheme ls /Root/db1
```

В `env.local.sh` достаточно указать одну переменную:

```sh
WL_YDB_PROFILE=chaos   # вместо WL_YDB_ENDPOINT + WL_YDB_DATABASE
```

### 4. На ydb-client — инициализация таблиц

```sh
cd ~/ydb-workload
bash workload.sh info       # проверить конфиг
bash workload.sh init -n    # dry-run: показать команду ydb
bash workload.sh init       # создать таблицы под WL_PATH_PREFIX
```

Таблицы создаются один раз. При повторном `init` проверяется наличие и
пропускается (idempotent).

## Запуск нагрузки (tmux)

На `ydb-client`:

```sh
ssh ydb-client
tmux new-session -s workload        # создать сессию (или attach, если уже есть)

cd ~/ydb-workload
bash workload.sh run                # foreground; Ctrl-C для останова
# или на фиксированное время:
bash workload.sh run -d 3600        # 1 час
```

**Отсоединиться, не прерывая нагрузку:** `Ctrl-B D`

**Вернуться из любой машины:**

```sh
ssh ydb-client -t 'tmux attach -t workload'
```

### Короткий запуск на N минут

```sh
bash workload.sh run -d 60 add-rand-order   # 1 сценарий, 60 сек
bash workload.sh run -d 300                 # все WL_SCENARIOS, 5 мин
```

## Деплой обновлений (ноут → ydb-client)

После изменения конфига или скриптов:

```sh
# На ноуте:
bash deploy.sh

# Перезапустить нагрузку на ydb-client:
ssh ydb-client -t 'tmux attach -t workload'
# Ctrl-C → bash workload.sh run
```

## Очистка таблиц

```sh
ssh ydb-client
cd ~/ydb-workload
bash workload.sh cleanup        # спросит подтверждение
bash workload.sh cleanup -y     # без подтверждения
```

## Метрики

InfluxDB line protocol → POST `${WL_VM_WRITE_URL}`. Схема:

```
ydb_workload,application=<app>,scenario=<sc>,statut=ok \
    rps=<v>,pct50=<v>,pct95=<v>,pct99=<v>,pmax=<v>,retries=<v>i  <ts_ns>

ydb_workload,application=<app>,scenario=<sc>,statut=ko \
    countError=<v>i  <ts_ns>
```

В Grafana (Prometheus-источник) серии видны как `ydb_workload_rps`,
`ydb_workload_pct99`, `ydb_workload_countError`, и т.п. Запрос:

```
sum by (scenario) (rate(ydb_workload_countError{application="chaos-stock"}[1m]))
```

## Структура

```
workload/
├── manage.sh                   — универсальный lifecycle
├── manager.env.example.sh      — пример общей конфигурации adapters
├── adapters/
│   ├── search.sh               — deep-tech-ydb-searches
│   └── stock.sh                — legacy ydb workload stock
├── tests/                      — smoke-тест lifecycle
├── ARCHITECTURE.md             — контракт интеграции
├── workload.sh                 — legacy stock CLI
├── env.example.sh              — legacy stock config
├── deploy.sh                   — legacy stock deploy
└── lib/                        — библиотеки legacy stock workload
```

## Границы ответственности

- `manage.sh` управляет foreground/background lifecycle, PID, health и логами.
- Общий Grafana/VictoriaMetrics stack остаётся в `grafana/`; workload не
  запускает собственную копию мониторинга.
- `chaos-md.sh --workload <type>` интегрирует нагрузку с headless/TUI-прогоном и
  гарантирует остановку через trap.
- Конкретная реализация нагрузки и её продуктовые проверки принадлежат adapter,
  а не Rust TUI.
