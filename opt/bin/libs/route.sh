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

# при изменении необходима перезагрузка роутера, либо вручную удалить старые
ROUTE_TABLE_ID=1002
PRIORITY_RULE=10778 
IPSET_TTL=900


# ------------------------------------------------------------------------------------------
# 	IPset::Cоздаем таблицу с именем '${IPSET_TABLE_NAME}'
#   hash:net:		Указывает тип набора — хэш-таблица для хранения сетей (подсетей или LilllI4 или IP-адресов). Этот тип оптимизирован для быстрого поиска и работы с сетевыми адресами.
#   family inet: 	Указывает, что набор предназначен для IPv4-адресов (inet — это IPv4, для IPv6 используется inet6).
#   -exist: 		Если набор с таким именем уже существует, команда не вызовет ошибку
#   timeout :	Устанавливает время жизни записей в наборе —  секунд. По истечении этого времени записи автоматически удаляются из набора, если не обновляются.
# ------------------------------------------------------------------------------------------
ip4_route__create_ipset(){
	if ipset list -n | grep -qx "${IPSET_TABLE_NAME}"; then
        return 0
    fi
	log "IPset::Cоздаем таблицу с именем '${IPSET_TABLE_NAME}'."
	if ! ipset create "${IPSET_TABLE_NAME}" hash:net family inet -exist timeout "${IPSET_TTL}" &>/dev/null; then
		log "[${FUNCNAME}] Ошибка при создании таблицы с именем '${IPSET_TABLE_NAME}' для ipset"
        return 1
	fi
}

# 	Создаем ip таблицу ${ROUTE_TABLE_ID} если метод wg (POINTOPOINT)
ip4_route__add_tbl_wg(){
	local ret=0
	{
		if ! ip route replace table "${ROUTE_TABLE_ID}" default dev "${INFACE_ENT}" 2>/dev/null; then
			ret=1
    		if ! ip link show "${INFACE_ENT}" >/dev/null 2>&1; then
        		log "[${FUNCNAME}] Ошибка: интерфейс '${INFACE_CLI}' не существует!" 3
    		else
				local INTERFACE_STATE
        		# Проверяем, поднят ли интерфейс (UP/DOWN)
        		INTERFACE_STATE=$(ip -o link show "${INFACE_ENT}" | awk '{print $3}')
        		if [[ "$INTERFACE_STATE" != *"UP"* ]]; then
            		log "[${FUNCNAME}] Ошибка: интерфейс '${INFACE_CLI}' не активен (состояние: ${INTERFACE_STATE})" 3
        		else
            		log "[${FUNCNAME}] Неизвестная ошибка при создании таблицы маршрутизации ID#${ROUTE_TABLE_ID} для '${INFACE_CLI}'" 3
        		fi
    		fi
		fi
	}
	show_result $ret "Создаем таблицу маршрутизации ID#${ROUTE_TABLE_ID} для '${INFACE_ENT}' ('${INFACE_CLI}')." "УСПЕШНО" "С ОШИБКАМИ" 3
}

# ip4_route__add_tbl_via() {
# 	{
# 		local ret _inface_ent_via
# 		_inface_ent_via=$(get_config_value "INFACE_ENT_VIA")
# 		if [ -z "$_inface_ent_via" ]; then
# 			log "[${FUNCNAME}] IP-адрес шлюза для интерфейса '${INFACE_ENT}' не задан"
# 			ret=1
# 		fi

# 		if ! ip route replace table "${ROUTE_TABLE_ID}" default via "${_inface_ent_via}" dev "${INFACE_ENT}" 2>/dev/null; then
# 			log "[${FUNCNAME}] Ошибка при создании таблицы маршрутизации ID#${ROUTE_TABLE_ID} для '${_inface_cli}'"
# 			ret=1
# 		fi

# 		# Пробуем добавить маршрут до сети шлюза (например, /24)
# 		local _net
# 		_net="$(echo "${_inface_ent_via}" | cut -d'.' -f1-3).0/24"
# 		if ! ip route add "${_net}" via "${_inface_ent_via}" dev "${INFACE_ENT}" table "${ROUTE_TABLE_ID}" 2>/dev/null; then
# 			log "[${FUNCNAME}] Маршрут ${_net} уже существует или не добавлен — это не критично"
# 		fi
# 	}
# 	show_result $ret "Создаем таблицу маршрутизации ID#${ROUTE_TABLE_ID} для '${INFACE_ENT}' ('${INFACE_CLI}')." "УСПЕШНО" "С ОШИБКАМИ" 3
# }

# 	Создаем ip таблицу ${ROUTE_TABLE_ID} если метод tproxy
ip4_route__add_tbl_tproxy(){
	local ret=0
	{
		if ! ip route replace local default dev lo table "${ROUTE_TABLE_ID}" 2>/dev/null; then
				error "[${FUNCNAME}] Ошибка при создании таблицы маршрутизации ID#${ROUTE_TABLE_ID} для 'TPROXY'"
				ret=1
		fi
	}
	show_result $ret "Создаем таблицу маршрутизации ID#${ROUTE_TABLE_ID} для 'TPROXY'." "УСПЕШНО" "С ОШИБКАМИ" 3
}

# в зависимости от выбранного соединения создаёт таблицу маршрутизации
ip4_route__add_table() {
	case "${METHOD}" in
		wg)
			ip4_route__add_tbl_wg
			;;
		tproxy) 
			ip4_route__add_tbl_tproxy
			;;
	esac	
}

ip4_route__rule_exists() {
	ip rule show | grep -q "fwmark ${FWMARK_NUM}/${FWMARK_NUM} lookup ${ROUTE_TABLE_ID}"
}

ip4_route__add_rule(){
	# проверяем что правила перехода в таблицу ROUTE_TABLE_ID не существует
	if ! ip4_route__rule_exists; then
		log "IPv4::Устанавливаем приоритет таблицы ID#${ROUTE_TABLE_ID} в значение ${PRIORITY_RULE}"

		if ip rule add fwmark ${FWMARK_NUM}/${FWMARK_NUM} lookup ${ROUTE_TABLE_ID} priority ${PRIORITY_RULE} 2>&1 | grep -vq 'File exists'; then
			log "[${FUNCNAME}] Ошибка при установке правила маршрутизации в таблицу ID#${ROUTE_TABLE_ID}"
		fi	
		if ip rule add fwmark ${FWMARK_NUM}/${FWMARK_NUM} blackhole priority $((PRIORITY_RULE + 1)) 2>&1 | grep -vq 'File exists'; then
			log "[${FUNCNAME}] Ошибка при установке заглушки blackhole"
		fi	
		#if ip route add default dev $(inface_ent) table ${ROUTE_TABLE_ID} 2>&1 | grep -vq 'File exists' ; then
		#		log "[${FUNCNAME}] Ошибка при установке маршрута по умолчанию таблицы с ID#${ROUTE_TABLE_ID}."
		#fi
	fi
}

ip4_route__flush_cache() {
	log 'Очистка кэша маршрутизации'
	/opt/sbin/ip route flush cache &>/dev/null
}



# если ЕСТЬ правило перехода в таблицу ROUTE_TABLE_ID маршрутизации то удаляет его и сбрасывает кэш
ip4_route__del_rule(){
	if ip4_route__rule_exists; then
		log "IPv4::Обнуляем приоритет таблицы ID#${ROUTE_TABLE_ID}"
		ip rule del fwmark ${FWMARK_NUM}/${FWMARK_NUM} lookup ${ROUTE_TABLE_ID} priority ${PRIORITY_RULE} &>/dev/null
		ip rule del fwmark ${FWMARK_NUM}/${FWMARK_NUM} blackhole priority $((PRIORITY_RULE + 1)) &>/dev/null
	fi
	ip4_route__flush_cache &>/dev/null
}

# удаление таблицы маршрутизации ${ROUTE_TABLE_ID}
ip4_route__del_route_table() {
	log "IPv4::Производим очистку записей таблицы маршрутизации ID#${ROUTE_TABLE_ID} и удалим ее."
	ip route flush table "${ROUTE_TABLE_ID}" &>/dev/null
	ip rule del table "${ROUTE_TABLE_ID}"  &>/dev/null
}