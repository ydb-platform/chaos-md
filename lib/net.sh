#!/usr/bin/env bash
# Сеть для хаос-тестов: интерфейсы по хосту, включение IPv4/IPv6 для tc и iptables.
# Требует предварительного source env.sh:
#   NET_IFACES — базовый список интерфейсов для всех хостов;
#   NET_IFACE — устаревший запасной вариант, если NET_IFACES пуст (одно имя);
#   NET_IFACES_TABLE — строки «pattern|iface1,iface2» (опционально); для 06/11 перечисляйте
#     все NIC с межнодевым YDB-трафиком, иначе iptables не перекроет второй линк;
#   CHAOS_HOST_IFACE_TABLE — то же, старое имя (читается, если NET_IFACES_TABLE пуст).

chaos_net_bool_true() {
    local v="${1:-}"
    v="$(printf '%s' "${v}" | tr '[:upper:]' '[:lower:]')"
    case "${v}" in
        1 | true | yes | on) return 0 ;;
        *)                     return 1 ;;
    esac
}

chaos_net_ipv4_enabled() { chaos_net_bool_true "${CHAOS_NET_IPV4:-true}"; }
chaos_net_ipv6_enabled() { chaos_net_bool_true "${CHAOS_NET_IPV6:-false}"; }

chaos_net_require_any_stack() {
    if ! chaos_net_ipv4_enabled && ! chaos_net_ipv6_enabled; then
        echo "chaos: CHAOS_NET_IPV4 и CHAOS_NET_IPV6 оба выключены — нечего применять" >&2
        return 1
    fi
    return 0
}

# Заполняет CHAOS_NET_IFACES_ARR из строки «a,b,c».
_chaos_net_parse_csv_to_arr() {
    local csv="$1" _parts _i
    CHAOS_NET_IFACES_ARR=()
    IFS=',' read -ra _parts <<< "${csv}"
    for _i in "${_parts[@]}"; do
        _i="${_i#"${_i%%[![:space:]]*}"}"
        _i="${_i%"${_i##*[![:space:]]}"}"
        [[ -n "${_i}" ]] && CHAOS_NET_IFACES_ARR+=("${_i}")
    done
}

# Строки таблицы: новое имя или legacy CHAOS_HOST_IFACE_TABLE.
_chaos_net_iface_table_rows() {
    if [[ "${NET_IFACES_TABLE+x}" == x ]]; then
        if [[ ${#NET_IFACES_TABLE[@]} -gt 0 ]]; then
            printf '%s\n' "${NET_IFACES_TABLE[@]}"
            return 0
        fi
    fi
    if [[ "${CHAOS_HOST_IFACE_TABLE+x}" == x ]]; then
        if [[ ${#CHAOS_HOST_IFACE_TABLE[@]} -gt 0 ]]; then
            printf '%s\n' "${CHAOS_HOST_IFACE_TABLE[@]}"
        fi
    fi
    return 0
}

# Заполняет массив CHAOS_NET_IFACES_ARR имён интерфейсов для хоста (порядок = порядок применения tc).
#
# Приоритет:
#   1) Первая строка таблицы NET_IFACES_TABLE (или CHAOS_HOST_IFACE_TABLE), у которой pattern
#      совпал с FQDN хоста (glob как в case … in ${pat})).
#   2) Иначе первая строка с pattern «*» в той же таблице (fallback для всех хостов).
#   3) Иначе NET_IFACES; если он пуст — NET_IFACE (по умолчанию eth0).
chaos_net_ifaces_for_host() {
    local host="$1"
    CHAOS_NET_IFACES_ARR=()

    local row pat list star_csv="" hit_csv=""
    while IFS= read -r row || [[ -n "${row}" ]]; do
        [[ -z "${row}" ]] && continue
        [[ "${row}" == *"|"* ]] || continue
        pat="${row%%|*}"
        list="${row#*|}"
        if [[ "${pat}" == "*" ]]; then
            [[ -z "${star_csv}" ]] && star_csv="${list}"
            continue
        fi
        case "${host}" in
            ${pat})
                hit_csv="${list}"
                break
                ;;
        esac
    done < <(_chaos_net_iface_table_rows)

    if [[ -n "${hit_csv}" ]]; then
        _chaos_net_parse_csv_to_arr "${hit_csv}"
        [[ ${#CHAOS_NET_IFACES_ARR[@]} -gt 0 ]] && return 0
    fi
    if [[ -n "${star_csv}" ]]; then
        _chaos_net_parse_csv_to_arr "${star_csv}"
        [[ ${#CHAOS_NET_IFACES_ARR[@]} -gt 0 ]] && return 0
    fi

    if [[ "${NET_IFACES+x}" == x ]] \
        && [[ ${#NET_IFACES[@]} -gt 0 ]]; then
        CHAOS_NET_IFACES_ARR=("${NET_IFACES[@]}")
        return 0
    fi

    CHAOS_NET_IFACES_ARR=( "${NET_IFACE:-eth0}" )
}

# Совместимость: первый интерфейс списка (старый get_iface из env.sh).
get_iface() {
    chaos_net_ifaces_for_host "$1"
    printf '%s\n' "${CHAOS_NET_IFACES_ARR[0]}"
}
