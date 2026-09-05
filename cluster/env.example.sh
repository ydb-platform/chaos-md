#!/usr/bin/env bash
# Локальная конфигурация вычислительных узлов конкретного стенда.
# Скопируйте в cluster/env.local.sh; этот файл исключён из Git.

DYNAMIC_NODE_HOSTS=(
  ydb-dynamic-1.example.com
  ydb-dynamic-2.example.com
  ydb-dynamic-3.example.com
)

# Только dynamic/tenant service. Storage service указывать нельзя.
YDBD_DYNAMIC_SERVICE="ydbd-database.service"
DYNAMIC_NODE_WAIT_SECONDS=90
# Жёсткий предел одного SSH-вызова start/stop/is-active.
DYNAMIC_NODE_COMMAND_TIMEOUT_SECONDS=20
