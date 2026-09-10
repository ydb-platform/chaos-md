# grafana/ — мониторинг стенда

Установка и обслуживание стека **VictoriaMetrics + node_exporter + Grafana** для chaos-тестов.

---

## Назначение

| Компонент | Где живёт | Зачем |
|-----------|-----------|-------|
| **VictoriaMetrics** (single) | docker на `${MON_HOST}` | TSDB для метрик (vmsingle, scrape встроен) |
| **node_exporter** | systemd на `${CLUSTER_HOSTS[*]}` | системные метрики хостов (CPU, RAM, диск, сеть) |
| **Grafana** | docker на `${MON_HOST}` | визуализация + аннотации chaos-окон |

YDB-метрики со **всех** `CLUSTER_HOSTS` и **каждого** порта из `${YDB_MON_PORTS}` (список через запятую, по умолчанию `8765,8767,8768`) забирает встроенный scraper VictoriaMetrics по путям вида `/counters/counters=<имя>/prometheus` (см. `grafana/scrape.yml`). Job’ы **pdisks** и **vdisks** используют только `${YDB_MON_PD_PORT}` — порт мониторинга узла хранения (по умолчанию 8765); таргеты — в `ydbd-storage.yml` на стороне `MON_HOST`.

Аннотации хаос-окон (CHAOS_START / END) шлёт в Grafana `lib/grafana.sh` — это runtime-часть тестов, не часть установки.

---

## Установка с нуля

Предусловие: на `${MON_HOST}` есть `docker`, на `${CLUSTER_HOSTS[*]}` доступен `sudo`.

С локальной машины делается так:

```bash
# 1) заливка репозитория на chaos-client (хост и каталог берутся из env.sh):
./sync-to-remote.sh

# 2) непосредственно на chaos-client:
ssh chaos-client
cd ~/${RSYNC_DEST:-chaos-tests}/grafana

# 3) далее друг за другом
./01-victoria.sh           # VictoriaMetrics в docker
./02-node-exporter.sh      # systemd-сервис на каждой ноде CLUSTER_HOSTS
./03-grafana.sh            # Grafana в docker (с маунтом provisioning/)
./04-dashboards-provision.sh   # рендер datasource yml + restart Grafana
```

Все скрипты поддерживают:
- `--check` — показать состояние (статус контейнера, метрики, файлы конфига).
- `--dry-run` — печатать команды, не выполнять.
- `-h, --help` — справка.

После установки:

- Grafana: `http://${MON_HOST}:${GRAFANA_PORT}/` (admin/`${GRAFANA_ADMIN_PASSWORD:-admin}`).
- Снаружи лаба — через SSH-туннель: `ssh -L ${GRAFANA_PORT}:localhost:${GRAFANA_PORT} ${MON_HOST}`.
- VictoriaMetrics: `http://${MON_HOST}:${VM_PORT}/-/ready`, targets: `/api/v1/targets`.

---

## Конфигурация (env.sh)

Все переменные — в корневом `env.sh` стенда:

```bash
MON_HOST="chaos-client.chaos-md.ydb.tech"  # где Grafana и VictoriaMetrics
YDB_MON_PORTS="8765,8767,8768"             # порты мониторинга на нодах; при необходимости допишите
YDB_MON_PD_PORT=8765                       # порт мониторинга узла хранения (pdisks/vdisks)
NODE_EXPORTER_PORT=9100
NODE_EXPORTER_VERSION="1.8.2"
GRAFANA_DOCKER_IMAGE="grafana/grafana:11.3.0"
VICTORIA_DOCKER_IMAGE="victoriametrics/victoria-metrics:v1.106.1"
VM_DATA_DIR="/var/lib/victoriametrics"
VM_PORT=8428
VM_RETENTION="30d"
GRAFANA_DATA_DIR="/var/lib/grafana"
GRAFANA_PORT=3000
```

Секреты (`GRAFANA_TOKEN` для аннотаций, `GRAFANA_ADMIN_PASSWORD` для UI) — в `env.local.sh` корня (gitignored).

---

## Аннотации chaos-окон в Grafana

Каждый chaos-тест шлёт через `lib/grafana.sh` пару аннотаций (start → end / cancel) с тегами `chaos` и `<имя-теста>`. На дашборде они становятся регионами.

| Событие | Теги | Цвет |
|---|---|---|
| `CHAOS_START` → `CHAOS_END` | `chaos`, `<имя-теста>` | красный |
| `CHAOS_START` → `CHAOS_CANCEL` | `chaos`, `<имя-теста>` | красный |
| Те же при `--dry-run` | `chaos-dry`, `<имя-теста>` | оранжевый |

Чтобы аннотации появились на ваших дашбордах:

1. Создать service account и токен (Editor) в Grafana, прописать в `env.local.sh`:
   ```bash
   GRAFANA_URL="http://${MON_HOST}:${GRAFANA_PORT}"
   GRAFANA_TOKEN="glsa_xxxxxxxx"
   ```
2. На каждом дашборде: Settings → Annotations → Add annotation query → tag `chaos` (и `chaos-dry`).

---

## Hot-update дашборда (без перезапуска контейнера)

`./grafana/deploy-dashboard.sh` — апдейт через API:

```bash
./grafana/deploy-dashboard.sh
```

Скрипт спрашивает имя (последнее запоминается в `grafana/.chaos-grafana-last`). Source — `grafana/dashboards/chaos/chaos-tests.json`. Удобно держать рабочий и тестовый дашборды (разные имена).

---

## Структура каталога

```
grafana/
├── 01-victoria.sh                — install VictoriaMetrics
├── 02-node-exporter.sh           — install node_exporter на CLUSTER_HOSTS
├── 03-grafana.sh                 — install Grafana
├── 04-dashboards-provision.sh    — рендер provisioning + restart
├── deploy-dashboard.sh           — API-апдейт дашборда (hot)
├── annotate.sh                   — создать аннотацию
├── dashboards/
│   └── chaos/
│       └── chaos-tests.json      — основной дашборд хаос-тестов
└── provisioning/
    ├── datasources/
    │   ├── victoriametrics.yml.tmpl   — шаблон (рендерится 04-скриптом)
    │   └── victoriametrics.yml        — сгенерированный (.gitignore)
    └── dashboards/
        └── dashboards.yml         — file-provider для /var/lib/grafana/dashboards
```

---
