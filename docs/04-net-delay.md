# 04-net-delay — Искусственная задержка сети между узлами кластера

## Справка (`./04-net-delay.sh -h`)

```
Использование: 04-net-delay.sh -1|-4 [ОПЦИИ]

Тест 04: netem delay на исходящий YDB sport (IPv4 и IPv6). Фазы нода/ДЦ — отдельные запуски.

Порты YDB (env YDB_PORTS): список через запятую, допускаются диапазоны вида 31000:32000.

Обязательно:
  -1, --single          Одна нода
  -4, --dc              Весь ДЦ

Опции:
  -d, --delay MS        Задержка, мс
  -t, --time SEC        Длительность хаоса, с
  -H, --host HOST       Хост для -1
  -C [HOST]             Проверка tc / RTT
  -D                    Снять netem с ноды и ДЦ
  -h, --help            Справка
```

## Как работает netem

`netem` (Network Emulator) — дисциплина очереди ядра Linux, добавляемая через `tc`.
Позволяет вносить задержку, джиттер, потери пакетов и другие дефекты в исходящий трафик.

## Структура qdisc: prio + фильтры по портам YDB

Задержка — для исходящего TCP, если **source port или destination port** ∈ **`YDB_PORTS`**. Пример порта **19001**; на стенде — полный список из `env.sh`. Настраиваются **все** iface хоста из `NET_IFACES` / `NET_IFACES_TABLE`.

```
NIC (<iface>)
 └── root prio
      ├── 1:1  netem delay 50ms   ← sport или dport ∈ YDB_PORTS  ← ЗАДЕРЖКА
      └── 1:2  netem delay 0ms     ← catch-all (prio 3) → без задержки
```

### Фильтры (`nemesis/tc.sh`)

Для **IPv4** и **IPv6** отдельно:

- **prio 3 (passthrough → класс 1:2):** IPv4 — один catch-all `match ip src 0.0.0.0/0`; IPv6 — **17 bitmask-фильтров** по `match ip6 sport` (покрывают 0..65535), потому что u32 не может надёжно матчить L4 по фиксированному смещению из-за extension headers.
- **prio 2 (YDB → класс 1:1):** для каждого порта из `YDB_PORTS` — фильтры по **sport** и **dport** (на IPv6 порты в hex, как в `nemesis/tc.sh`).

Фильтр по **dport** нужен для исходящих соединений к соседям (эфемерный source port).

## Снятие задержки

```bash
sudo tc qdisc del dev eth0 root
```

Удаление root qdisc автоматически удаляет все дочерние qdiscs и фильтры.

## Проверка

```bash
tc qdisc show dev eth0
# При активной задержке:
# qdisc prio 1: root refcnt 6 bands 3 priomap  1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1
# qdisc netem 10: parent 1:1 limit 262144 delay 50ms
# qdisc netem 20: parent 1:2 limit 262144

tc filter show dev eth0
# filter protocol ip pref 2 u32 ... match ip sport 19001 flowid 1:1
# filter protocol ip pref 2 u32 ... match ip dport 19001 flowid 1:1
# filter protocol ip pref 3 u32 ... match ip src 0.0.0.0/0 flowid 1:2
```

## Автоматическое снятие по таймауту

`nemesis/tc-remote.sh` записывает владельца интерфейса в `/var/lib/chaos-md`.
Скрипт запускает таймер до изменения qdisc. Таймер после ожидания сверяет
идентификатор владельца, снимает только qdisc своей операции и проверяет результат.
Таймер продолжает работу после разрыва SSH-соединения, но не переживает перезагрузку
ноды.

## Досрочное снятие (-D)

```bash
./04-net-delay.sh -D
```

Флаг `--operation` адресует исходную операцию. Без явного идентификатора команда
снимает qdisc на интерфейсах, которые заданы для выбранных хостов.

## Проверка применённой задержки (-C)

```bash
./04-net-delay.sh -C
./04-net-delay.sh -C node-b.example.net
```

Вывод (пример):
```
resource=tc:eth0 state=active operation=0123456789abcdef0123456789abcdef
```

### Команда на хосте

```bash
target_ip=$(getent ahostsv6 node-b.example.net | awk 'NR==1{print $1}')
sudo hping3 -S -p 19001 -s 19001 -c 10 "${target_ip}"
```

Флаги: `-S` — TCP SYN, `-p` — destination port, `-s` — source port, `-c` — количество проб.

Требует `hping3` на удалённом хосте: `sudo yum install hping3` / `sudo apt install hping3`.

## Команды для ручного применения

Полная генерация (все порты из `YDB_PORTS`, все iface, IPv4+IPv6) — в **`nemesis/tc.sh`**. Ниже — **упрощённый** пример для одного порта **19001** и iface **`eth0`**. Замените интерфейс и задержку.

### IPv4 (один порт)

**Применить:**
```bash
sudo tc qdisc del dev eth0 root
sudo tc qdisc add dev eth0 root handle 1: prio
sudo tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 50ms limit 262144
sudo tc filter add dev eth0 protocol ip parent 1:0 prio 3 u32 match ip src 0.0.0.0/0 flowid 1:2
sudo tc filter add dev eth0 protocol ip parent 1:0 prio 2 u32 match ip sport 19001 0xffff flowid 1:1
sudo tc filter add dev eth0 protocol ip parent 1:0 prio 2 u32 match ip dport 19001 0xffff flowid 1:1
sudo tc qdisc add dev eth0 parent 1:2 handle 20: netem delay 0ms limit 262144
```

### IPv6 (один порт)

**Применить** (passthrough — 17 масок prio 3; YDB — prio 2 sport+dport):

```bash
sudo tc qdisc del dev eth0 root
sudo tc qdisc add dev eth0 root handle 1: prio
sudo tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 50ms limit 262144
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x0    0xffff flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x1    0xffff flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x2    0xfffe flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x4    0xfffc flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x8    0xfff8 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x10   0xfff0 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x20   0xffe0 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x40   0xffc0 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x80   0xff80 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x100  0xff00 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x200  0xfe00 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x400  0xfc00 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x800  0xf800 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x1000 0xf000 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x2000 0xe000 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x4000 0xc000 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 3 u32 match ip6 sport 0x8000 0x8000 flowid 1:2
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 2 u32 match ip6 sport 0x4a39 0xffff flowid 1:1
sudo tc filter add dev eth0 protocol ipv6 parent 1:0 prio 2 u32 match ip6 dport 0x4a39 0xffff flowid 1:1
sudo tc qdisc add dev eth0 parent 1:2 handle 20: netem delay 0ms limit 262144
```

(`0x4a39` = 19001; полный список генерирует `nemesis/tc.sh`)

**Проверить / снять** — как в разделах выше (`tc qdisc show`, `tc qdisc del dev eth0 root`).

## Параметры скрипта

| Параметр | Ключ | По умолчанию |
|---|---|---|
| Задержка, мс | `-d` / `--delay` | `DEFAULT_NET_DELAY` |
| Длительность фазы, с | `-t` / `--time` | `DEFAULT_CHAOS_TIMEOUT` |
| Хост для `-1` | `-H` / `--host` | `SINGLE_HOST` |
| Область | `-1` или `-4` | обязателен один |
| Проверка tc/RTT | `-C` [HOST] | — |
| Снять netem | `-D` | — |
| Порты YDB | — | `YDB_PORTS` в `env.sh` (в т.ч. диапазоны) |
| Интерфейс | — | `NET_IFACES_TABLE` / `NET_IFACES` / `NET_IFACE` в `env.sh` (`lib/net.sh`) |
