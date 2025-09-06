#!/bin/sh

# ------------------------------------------------------------------------------------------
#
# 	ПАКЕТ КВАС ЛАЙТ
#
# ------------------------------------------------------------------------------------------
#
# ------------------------------------------------------------------------------
#	Разработчик: carIod
#	Дата создания: 10/06/2025
#	Лицензия: Apache License 2.0
#   github: https://github.com/carIod/kvas_light
#	На основе https://github.com/qzeleza/kvas используется на условиях лицензии Apache 2.0.
# ------------------------------------------------------------------------------
# shellcheck source=opt\bin\libs\utils.sh
. /opt/apps/kvl/bin/libs/utils.sh

PREF_HOLD="KVL_"
# Метка цепочки для маркировки пакетов в iptables (не удаляется при очистке всех правил)
VPN_IPTABLES_CHAIN="${PREF_HOLD}MARK"
# префикс всех остальных цепочек необхдим для скриптового удаления всех правил
START_CHAIN="_KVL_"

# Метка TPROXY цепочки для правил iptables
PROXY_IPTABLES_CHAIN="${START_CHAIN}TPROXY"
DNS_PORT=53

iptab() { /opt/sbin/iptables "$@"; }
iptab_save() { /opt/sbin/iptables-save "$@"; }

check_present_chain(){
	/opt/sbin/iptables -t "$1" -L "$2" -n &>/dev/null
}

# удаление всех пользовательских правил начинающихся на $START_CHAIN во всей iptables
# так же можно задать другой префикс (1й параметр) и список таблиц где удалять (2й параметр)
ip4_iptab__cleanup_all_user_rules() {
	local prefix="${1:-$START_CHAIN}"
	local tables="${2:-"filter nat mangle"}"
    local rc=0 table rule rule_del chain rules

    for table in $tables; do
        rules=$(iptab_save -t "$table" 2>/dev/null) || continue

        # Удаляем переходы в цепочки
        while read -r rule; do
			[ -z "$rule" ] && continue
            rule_del=$(echo "$rule" | sed 's/^-A /-D /')
			# shellcheck disable=SC2086
            if ! iptab -t "$table" $rule_del 2>/dev/null; then
                rc=1
                #echo "Ошибка удаления: $rule_del" >&2
            fi
        done <<EOF
$(echo "$rules" | grep -- "-j $prefix")
EOF

        # Удаляем сами цепочки
        while read -r chain; do
			[ -z "$chain" ] && continue
            if ! iptab -t "$table" -F "$chain" 2>/dev/null; then
                rc=1
                #echo "Ошибка очистки цепочки: $chain" >&2
            fi
            if ! iptab -t "$table" -X "$chain" 2>/dev/null; then
                rc=1
                #echo "Ошибка удаления цепочки: $chain" >&2
            fi
        done <<EOF
$(echo "$rules" | awk -v chain="$prefix" '$1 ~ "^:" chain {sub(/^:/, "", $1); print $1}')
EOF
    done
    return $rc
}
# =========================================================================================================================

ip4_iptab__nat_dns_redir_del(){
	ip4_iptab__cleanup_all_user_rules "${PREF_HOLD}DNS" "nat"
}

# Правило перенаправляет все DNS запросы на локальный сервер
ip4_iptab__nat_dns_redirect(){
	{
	if [ "$DNS_REDIRECT" = "yes" ]; then
		local chain
		chain="${PREF_HOLD}DNS"
		if ! check_present_chain nat "$chain"; then
			iptab -t nat -N "$chain" &>/dev/null
			log "Подключаем правило редиректа DNS на локальный порт"
			iptab -t nat -A "$chain"  -p udp --dport "$DNS_PORT" -j REDIRECT --to-port "$DNS_PORT" 
			iptab -t nat -A PREROUTING -i "$LOCAL_INFACE" -p udp --dport "$DNS_PORT" ! -d "$ROUTER_IP" -j "$chain"
		fi	
	fi	
	} &>/dev/null || log "[${FUNCNAME}] Во время добавления правил редиректа ДНС возникли ошибки" 3
}

ip4_iptab__mangle_mtu(){
	{
	local chain
	chain="${START_CHAIN}MTU"
	if ! check_present_chain mangle "$chain"; then
		# так как интерфейс создан вручную то добавляем правила для корекции MTU при пересылке
		iptab -t mangle -N "${chain}" &>/dev/null
		iptab -t mangle -A "${chain}" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
		iptab -t mangle -A FORWARD -i "${INFACE_ENT}" -p tcp -m tcp --tcp-flags SYN,RST SYN -j "${chain}"
		iptab -t mangle -A FORWARD -o "${INFACE_ENT}" -p tcp -m tcp --tcp-flags SYN,RST SYN -j "${chain}"
	fi
	} &>/dev/null || log "[${FUNCNAME}] Во время добавления правил корректировки MTU возникли ошибки" 3
}

ip4_iptab__mangle_tproxy(){
	{
	if ! check_present_chain mangle "$PROXY_IPTABLES_CHAIN"; then
		iptab -t mangle -N "${PROXY_IPTABLES_CHAIN}" &>/dev/null
		[ "$ENABLE_UDP" = "yes" ] && iptab -t mangle -A "${PROXY_IPTABLES_CHAIN}" -p udp -j TPROXY --on-port "${UDP_PORT}" --on-ip 127.0.0.1
		[ "$TCP_WAY" = "tproxy" ] && iptab -t mangle -A "${PROXY_IPTABLES_CHAIN}" -p tcp -j TPROXY --on-port "${TCP_PORT}" --on-ip 127.0.0.1
		iptab -t mangle -A PREROUTING -m mark --mark "${FWMARK_NUM}/${FWMARK_NUM}" -j "${PROXY_IPTABLES_CHAIN}"
	fi
	} &>/dev/null || log "[${FUNCNAME}] Во время добавления правил пересылки пакетов в TPROXY возникли ошибки" 3
}

# маркировка пакетов в iptables (не удаляется при очистке всех правил)
ip4_iptab__mangle_mark(){
	{
		if ! check_present_chain mangle "${VPN_IPTABLES_CHAIN}"; then
			log "Создаем цепочку правил в таблице mangle для маркировки трафика"
			iptab -N "${VPN_IPTABLES_CHAIN}" -t mangle &>/dev/null
			iptab -A "${VPN_IPTABLES_CHAIN}" -t mangle -j CONNMARK --restore-mark --mask "${FWMARK_NUM}" 
			iptab -A "${VPN_IPTABLES_CHAIN}" -t mangle -m mark --mark "${FWMARK_NUM}"/"${FWMARK_NUM}" -j RETURN
			iptab -A "${VPN_IPTABLES_CHAIN}" -t mangle -m conntrack --ctstate NEW -j MARK --set-mark "${FWMARK_NUM}"/"${FWMARK_NUM}" 
			iptab -A "${VPN_IPTABLES_CHAIN}" -t mangle -m mark ! --mark "${FWMARK_NUM}"/"${FWMARK_NUM}" -j DROP
			iptab -A "${VPN_IPTABLES_CHAIN}" -t mangle -j CONNMARK --save-mark --mask "${FWMARK_NUM}"
			iptab -A "${VPN_IPTABLES_CHAIN}" -t mangle -j ULOG --ulog-nlgroup 1

			iptab -A PREROUTING -t mangle -m set --match-set "${IPSET_TABLE_NAME}" dst -j "${VPN_IPTABLES_CHAIN}"
			iptab -A OUTPUT     -t mangle -m set --match-set "${IPSET_TABLE_NAME}" dst -j "${VPN_IPTABLES_CHAIN}"
		fi	
	} &>/dev/null || log "[${FUNCNAME}] Во время маркировки трафика для VPN соединений возникли ошибки." 3

}


ip4_iptab__nat_masquerade(){
	chain="${START_CHAIN}MASQ"
	{
	    if ! check_present_chain nat "${chain}"; then
			# если цепочки нет значит все правила в таблице ${table} уничтожены и нужно пересоздать
        	iptab -t nat -N "${chain}" &>/dev/null
			iptab -t nat -A "${chain}" -o "${INFACE_ENT}" -j MASQUERADE
			log "Подключаем правила маскарадинга на выходной интерфейс ${INFACE_ENT}"
			iptab -t nat -A POSTROUTING -j "${chain}"
            # в зависимости от настройки включает редирект DNS на локальный порт роутера
    	fi
	} &>/dev/null || log "[${FUNCNAME}] Во время добавления правил MASQUERADE возникли ошибки" 3
}

ip4_iptab__nat_tproxy(){
	{
		# Создаём цепочку, если её нет
		if ! check_present_chain nat "${PROXY_IPTABLES_CHAIN}"; then
			iptab -N "${PROXY_IPTABLES_CHAIN}" -t nat &>/dev/null
			log "Подключаем DNAT для входящих из интерфейса ${LOCAL_INFACE} порт ${TCP_PORT}."
			# Не маршрутизируем сам сервер SSR
			iptab -t nat -A "${PROXY_IPTABLES_CHAIN}" -d "${SERVER_IP}" -j RETURN
			# Основные правила перенаправления
			iptab -t nat -A "${PROXY_IPTABLES_CHAIN}" -p tcp -j DNAT --to-destination "127.0.0.1:${TCP_PORT}"
			# Добавляем переход из PREROUTING в {PROXY_IPTABLES_CHAIN}
			iptab -t nat -A PREROUTING -i "${LOCAL_INFACE}" -p tcp -m mark --mark "${FWMARK_NUM}/${FWMARK_NUM}" -j "${PROXY_IPTABLES_CHAIN}"
			iptab -t nat -A OUTPUT -p tcp -m mark --mark "${FWMARK_NUM}/${FWMARK_NUM}" -j "${PROXY_IPTABLES_CHAIN}"
		fi	
	} &>/dev/null || log "[${FUNCNAME}] Во время добавления правил DNAT возникли ошибки" 3
}

ip4_iptab__filter_forvard_mark(){
	chain="${START_CHAIN}FORWARD"
	{
	    if ! check_present_chain filter "${chain}"; then
			# если цепочки нет значит все правила в таблице filter уничтожены и нужно пересоздать
        	iptab -t filter -N "${chain}" &>/dev/null
			iptab -t filter -A "${chain}" -o "${INFACE_ENT}" -m mark --mark "${FWMARK_NUM}/${FWMARK_NUM}" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
			iptab -t filter -A "${chain}" -i "${INFACE_ENT}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT	
			log "Подключаем правила разрешения пересылки маркированного трафика в ${INFACE_ENT}"
			# пока что других правил обязательных нет для фильтра в vpn подключении поэтому переход в цепочку сделаю внутри проверки на manual
			iptab -t filter -A FORWARD -j "${chain}"
    	fi

	} &>/dev/null || log "[${FUNCNAME}] Во время добавления правил в таблицу filter возникли ошибки" 3
}

#=============================================================================================
# Следующие функции вызываются из hook файла \opt\etc\ndm\netfilter.d\100-kvl-vpn 
# это происходит автоматически при изменении iptables и нужно проверить что все правила есть
ip4_iptab__vpn_insert_mangle(){
	local ret=0
	# маркировка трафика вызывается всегда
	ip4_iptab__mangle_mark || ret=1
	case "${METHOD}" in
		wg)
		[ "$ENABLE_MTU" = "yes" ] && ! ip4_iptab__mangle_mtu && ret=1
		;;
		tproxy)
		{ [ "$ENABLE_UDP" = "yes" ] || [ "$TCP_WAY" = "tproxy" ]; } && ! ip4_iptab__mangle_tproxy && ret=1
		;;
		
	esac	
	return $ret
}

ip4_iptab__vpn_insert_nat(){
	local ret=0
	ip4_iptab__nat_dns_redirect || ret=1
	case "${METHOD}" in
		wg)
		[ "$ENABLE_MASQ" = "yes" ] && ! ip4_iptab__nat_masquerade && ret=1
		;;
		tproxy) 
		[ "$TCP_WAY" = "dnat" ] && ! ip4_iptab__nat_tproxy && ret=1
		;;
	esac
	return $ret
}

ip4_iptab__vpn_insert_filter(){
	local ret=0
	case "${METHOD}" in
		wg)
		[ "$ENABLE_MASQ" = "yes" ] && ! ip4_iptab__filter_forvard_mark && ret=1
		;;
		tproxy) 
		;;
	esac
	return $ret
}
#=============================================================================================
