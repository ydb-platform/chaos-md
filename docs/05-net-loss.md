# 05-net-loss — Искусственная потеря пакетов между узлами кластера

## Справка (`./05-net-loss.sh -h`)

**`-1`** или **`-4`**. Порты: `YDB_PORTS` (IPv4 и IPv6, как в тесте 04). Ключи: `-l` % потерь, `-t`, `-H`, `-C`, `-D`.

```bash
./05-net-loss.sh -1 -l 2 -t 600
./05-net-loss.sh -4 -l 2 -t 600
./05-net-loss.sh -D
```

## Как работает netem loss

`netem` (Network Emulator) — дисциплина очереди ядра Linux.
`loss N%` задаёт вероятность случайного отбрасывания каждого исходящего пакета в классе, куда попал фильтр.

Используется та же схема `prio` и фильтров `u32` по source port, что и в тесте задержки (04), отдельно для **IPv4** и **IPv6**: в хаос попадают пакеты с портами из `YDB_PORTS`, остальной трафик уходит в passthrough-класс.

## Структура qdisc

Та же схема `prio`, что в [тесте 04](04-net-delay.md): **sport или dport** из `YDB_PORTS` → класс 1:1 с `netem loss`; passthrough → класс 1:2 (IPv6 passthrough — 17 bitmask-масок на prio 3).

```
NIC (<iface>)
 └── root prio
      ├── 1:1  netem loss 2%     ← порты YDB (sport|dport)
      └── 1:2  netem delay 0ms    ← остальной трафик
```

## Применение потери (упрощённо, один порт IPv4)

```bash
sudo tc qdisc del dev eth0 root
sudo tc qdisc add dev eth0 root handle 1: prio
sudo tc qdisc add dev eth0 parent 1:1 handle 10: netem loss 2% limit 262144
sudo tc filter add dev eth0 protocol ip parent 1:0 prio 3 u32 match ip src 0.0.0.0/0 flowid 1:2
sudo tc filter add dev eth0 protocol ip parent 1:0 prio 2 u32 match ip sport 19001 0xffff flowid 1:1
sudo tc filter add dev eth0 protocol ip parent 1:0 prio 2 u32 match ip dport 19001 0xffff flowid 1:1
sudo tc qdisc add dev eth0 parent 1:2 handle 20: netem delay 0ms limit 262144
```

Полная генерация — **`nemesis/tc.sh`** (все порты, iface, IPv6).

## Снятие потери

```bash
sudo tc qdisc del dev eth0 root
```

## Проверка

```bash
tc qdisc show dev eth0
# При активной потере:
# qdisc prio 1: root refcnt 6 bands 3 priomap  1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1
# qdisc netem 10: parent 1:1 limit 262144 loss 2%
# qdisc netem 20: parent 1:2 limit 262144

tc filter show dev eth0
# filter protocol ipv6 pref 1 u32 ... match ip6 sport 0x4a39 0xffff flowid 1:1
```

## Автоматическое снятие по таймауту

Удаленный скрипт запускает таймер до изменения qdisc. Таймер хранит идентификатор
операции и снимает только принадлежащие ей интерфейсы. После снятия таймер проверяет
состояние через `tc qdisc show`.

## Досрочное снятие (-D)

`./05-net-loss.sh -D --operation ID` снимает конкретную операцию. Команда без
`--operation` выполняет ручное снятие на настроенных интерфейсах.

## Проверка статуса (-C)

```bash
./05-net-loss.sh -C
./05-net-loss.sh -C node-b.example.net
```

Вывод (пример):
```
resource=tc:eth0 state=active operation=0123456789abcdef0123456789abcdef
```

## Команды для ручного применения

См. [тест 04](04-net-delay.md) — та же схема фильтров; вместо `netem delay` используйте `netem loss N%`.

## Параметры скрипта

| Параметр | Ключ | По умолчанию |
|---|---|---|
| Потеря пакетов, % | `-l` / `--loss` | `DEFAULT_NET_LOSS` |
| Длительность фазы, с | `-t` / `--time` | `DEFAULT_CHAOS_TIMEOUT` |
| Хост для `-1` | `-H` / `--host` | `SINGLE_HOST` |
| Область | `-1` или `-4` | один обязателен |
| Проверка | `-C` [HOST] | — |
| Снять netem | `-D` | — |
| Интерфейс | — | `NET_IFACES_TABLE` / `NET_IFACES` в `env.sh` |
