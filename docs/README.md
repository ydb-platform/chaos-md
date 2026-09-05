# Методики хаос-тестов Chaos MD

## Настройка

- [../README.md](../README.md) — быстрый старт, env.sh, общий CLI.
- [../grafana/README.md](../grafana/README.md) — мониторинг и аннотации chaos-окон.
- [../workload/README.md](../workload/README.md) — нагрузка YDB (workload stock → VictoriaMetrics).
- [../chaos-md/README.md](../chaos-md/README.md) — TUI-диспетчер запусков.

## Тесты

| Тест | Скрипт | Методика | Описание |
|---|---|---|---|
| 01 | [`01-cpu-load.sh`](../01-cpu-load.sh) | [01-cpu-load.md](01-cpu-load.md) | Дефицит CPU через ChaosBlade — одна нода, затем весь ДЦ. |
| 02 | [`02-mem-load.sh`](../02-mem-load.sh) | [02-mem-load.md](02-mem-load.md) | Нагрузка на память (RAM heap + page cache) через ChaosBlade. |
| 03 | [`03-disk-fail.sh`](../03-disk-fail.sh) | [03-disk-fail.md](03-disk-fail.md) | «Потеря» диска через смену GPT partlabel; восстановление метки и рестарт storage. |
| 04 | [`04-net-delay.sh`](../04-net-delay.sh) | [04-net-delay.md](04-net-delay.md) | Задержка исходящего YDB-трафика (tc/netem, IPv4+IPv6, sport/dport) — одна нода, затем весь ДЦ. |
| 05 | [`05-net-loss.sh`](../05-net-loss.sh) | [05-net-loss.md](05-net-loss.md) | Потеря пакетов на YDB-интерконнекте (tc/netem, та же схема фильтров, что 04) — одна нода, затем весь ДЦ. |
| 06 | [`06-net-drop.sh`](../06-net-drop.sh) | [06-net-drop.md](06-net-drop.md) | Блокировка YDB-интерконнекта (iptables, по умолчанию REJECT) на одной ноде. |
| 07 | [`07-net-bw.sh`](../07-net-bw.sh) | [07-net-bw.md](07-net-bw.md) | Ограничение пропускной способности исходящего трафика (tc/tbf) — одна нода, затем весь ДЦ. |
| 08 | [`08-proc-freeze.sh`](../08-proc-freeze.sh) | [08-proc-freeze.md](08-proc-freeze.md) | Заморозка процессов **ydbd** (SIGSTOP); размораживание по таймауту или `-D`. |
| 09 | [`09-proc-kill.sh`](../09-proc-kill.sh) | [09-proc-kill.md](09-proc-kill.md) | SIGKILL процессов **ydbd**; `--hold` удерживает отказ до отдельного восстановления (`-1` или `-4`). |
| 10 | [`10-rolling-upgrade.sh`](../10-rolling-upgrade.sh) | [10-rolling-upgrade.md](10-rolling-upgrade.md) | Замена бинарника **ydbd** из дистрибутива, наблюдение, откат на оригинал. |
| 11 | [`11-dc-drop.sh`](../11-dc-drop.sh) | [11-dc-drop.md](11-dc-drop.md) | Блокировка YDB-интерконнекта (iptables, по умолчанию REJECT) на всех хостах ДЦ. |
| 12 | [`12-server-stop.sh`](../12-server-stop.sh) | [12-server-stop.md](12-server-stop.md) | Остановка tenant + storage (в доках: `ydbd-database-a.service`, `ydbd-storage.service`), авто-восстановление по `-t`. |
