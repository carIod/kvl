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
# shellcheck source=opt\bin\libs\route.sh
. /opt/apps/kvl/bin/libs/route.sh
# shellcheck source=opt\bin\libs\iptab.sh
. /opt/apps/kvl/bin/libs/iptab.sh


IP_FILTER='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
REGEXP_IP_OR_RANGE="${IP_FILTER}|${IP_FILTER}-${IP_FILTER}|${IP_FILTER}/[0-9]{1,2}"

# ------------------------------------------------------------------------------------------
# Пересоздаем хосты в DNS конфигурационном файле
# ------------------------------------------------------------------------------------------
ip4_vpn__refresh_ipset_table(){
	local restart="$1"
	local dns_mode="$2"
	if [ -z "$dns_mode" ]; then
		get_dns_mode dns_mode
	fi	
	# обнуляем защищенный список  БС
	case "$dns_mode" in
		dnsmasq)
			: > "${DNSMASQ_IPSET_HOSTS}"
			;;
		adguard)
			: > "${ADGUARD_IPSET_FILE}"
			;;
		*)
			color_echo "${RED}ОШИБКА определения DNS сервера. Запустите ${BLUE}'kvl dns mode'${RED}${NOCL}"
			return 1
			;;	
	esac
		
	{
		while read -r line || [ -n "${line}" ]; do
  			# удаляем из строки комментарии - все что встречается после символа # и сам символ
  			line=$(echo "${line}" | sed 's/#.*$//g' | tr -s ' ' )
  			#  пропускаем пустые строки и строки с комментариями
  			[ -z "${line}" ] && continue
  			#  пропускаем строки с комментариями
  			[ "${line::1}" = "#" ] && continue
  			# пропускаем из обработки IP адреса
  			echo "${line}" | grep -Eq "${IP_FILTER}" && continue
  			host=$(echo "${line}" | sed 's/\*//g;')
			case "$dns_mode" in
				dnsmasq)
					echo "ipset=/${host}/${IPSET_TABLE_NAME}" >> "${DNSMASQ_IPSET_HOSTS}"
				;;
				adguard)
					echo "${host}/${IPSET_TABLE_NAME}" >> "${ADGUARD_IPSET_FILE}"
				;;
			esac
		done < "${KVL_LIST_WHITE}"
	} 
	show_result $? "${prefix}Заполняем конфигурацию DNS данными из защищенного списка" "УСПЕШНО" "ОШИБКА" 3
	if [ "$restart" = "restart" ]; then
		case "$dns_mode" in
			dnsmasq)
				if [ -f "$DNSMASQ_DEMON" ]; then
					color_echo "Перезапускаем сервер ${BLUE}dnsmasq${NOCL}"
					$DNSMASQ_DEMON restart #&> /dev/null
				fi
				;;
			adguard)
				if [ -f "$ADGUARDHOME_DEMON" ]; then 
					color_echo "Перезапускаем сервер ${BLUE}AdGuard Home${NOCL}"
					$ADGUARDHOME_DEMON restart #&> /dev/null
				fi
				;;
		esac		
	fi
}


# ------------------------------------------------------------------------------------------
# Обновляем правила ipset
# ------------------------------------------------------------------------------------------
ip4_vpn__insert_static_ip_ipset(){
	#stage="${1}"
	{
		while read -r line || [ -n "${line}" ]; do
			# пропускаем строки c минусами — это рекламные сайты
			# пропускаем пустые строки # пропускаем строки с комментариями
			[ "${line::1}" = "-" ] || [ -z "${line}" ] || [ "${line:0:1}" = "#" ] && continue

			# удаляем из строки комментарии - все что встречается после символа # и сам символ
			# удаляем *
			host=$(echo "${line}" | sed 's/#.*$//g' | tr -s ' ' | sed 's/\*//')

			# если строка IP, диапазон или маска; то добавляем напрямую и без ttl
			if echo "${host}" | grep -qE -- "${REGEXP_IP_OR_RANGE}"; then
				/opt/sbin/ipset -exist add "${IPSET_TABLE_NAME}" "${host}" timeout 0 &>/dev/null || true
			fi
		done < "${KVL_LIST_WHITE}"

	}
	show_result $? "Заполняем ipset таблицу статическими ip адресами из защищенного списка" "УСПЕШНО" "ОШИБКА" 2
}

ip4_vpn__insert_all_vpn_rules(){
	local ret=0
	ip4_iptab__vpn_insert_mangle || ret=1
	ip4_iptab__vpn_insert_nat || ret=1
	ip4_iptab__vpn_insert_filter || ret=1
	return $ret
}

# Останавливаем работу плагина $1-имя файла без .sh  $2-внутренее название плагина для вывода на экран 
ip4_vpn__stop_plugin(){
	local plugin_path="${PLUGIN_DIR%/}/${1}.sh"
	if [ -f "$plugin_path" ]; then
		"$plugin_path" stop  &>/dev/null
		ret=$?
		show_result "$ret" "Остановка плагина '${2}' " "УСПЕШНО" "ОШИБКА" 3
		[ "$ret" -ne 0 ] && return 1
	else
		log "Плагин '$plugin' не найден в каталоге $PLUGIN_DIR" 3
   		return 1		
	fi
}		

# Запускает плагин $1, а так же получает параметры из него
ip4_vpn__start_plugin(){
	local plugin_path="${PLUGIN_DIR%/}/${1}.sh"
	if [ -f "$plugin_path" ]; then
		if "$plugin_path" restart &>/dev/null; then  # все-же лучше restart так плагин перезапустит демон с новыми параметрами
			show_result 0 "Запуск плагина '${1}' " "УСПЕШНО" "" 3
			params_json=$("$plugin_path" get_param)
			ret=$?
			[ -z "$params_json" ] && ret=1
			show_result "$ret" "Получение параметров работы плагина '${1}' " "УСПЕШНО" "ОШИБКА" 3
			if [ "$ret" -ne 0 ]; then
    			return 1
			fi
			METHOD=$(echo "$params_json" | jq -r '.method')
			SERVER_IP=$(echo "$params_json" | jq -r '.server_ip // ""')
			INFACE_CLI=$(echo "$params_json" | jq -r '.inface_cli // ""') # для плагина содержит человеческое наименование
			INFACE_ENT=$(echo "$params_json" | jq -r '.inface_ent // ""')
			TCP_PORT=$(echo "$params_json" | jq -r '.tcp_port // ""')
			TCP_WAY=$(echo "$params_json" | jq -r '.tcp_way // ""') # путь tcp пакетов через dnat or troxy
			ENABLE_UDP=$(echo "$params_json" | jq -r '.udp // ""')
			UDP_PORT=$(echo "$params_json" | jq -r '.udp_port // ""')
			ENABLE_MTU=$(echo "$params_json" | jq -r '.mtu // ""')
			ENABLE_MASQ=$(echo "$params_json" | jq -r '.masq // ""')
			set_config_value INFACE_CLI "$INFACE_CLI"
			set_config_value INFACE_ENT "$INFACE_ENT"
			set_config_value METHOD "$METHOD"
			set_config_value TCP_PORT "$TCP_PORT"
			set_config_value TCP_WAY "$TCP_WAY"
			set_config_value ENABLE_UDP "$ENABLE_UDP"
			set_config_value UDP_PORT "$UDP_PORT"
			set_config_value ENABLE_MTU "$ENABLE_MTU"
			set_config_value ENABLE_MASQ "$ENABLE_MASQ"
			set_config_value SERVER_IP "$SERVER_IP"
		else
			# плагин не запустился	
			show_result 1 "Запуск плагина '${1}' " "" "ОШИБКА" 3
			log "Плагин '$plugin' не запустился" 3
   			return 1
		fi
	else
		log "Плагин '$plugin' не найден в каталоге $PLUGIN_DIR" 3
   		return 1			
	fi

}

# выполняется подготовка провайдера, если плагин то его запуск
ip4_vpn__provider_ready() {
	local plugin plugin_path params_json ret
	PROVIDER="$(get_config_value PROVIDER)"
	if [ "$PROVIDER" = "plugin" ]; then
		# если используется плагин то запускаем его и получаем от него параметры 
		plugin="$(get_config_value PLUGIN_NAME)"
		# запускаем и считываем параметры плагин вдруг они изменились
		ip4_vpn__start_plugin "$plugin" || return 1
		
	elif  [ "$PROVIDER" = "internal" ]; then # при таком провайдере работает пока что только METHOD = wg
		METHOD="$(get_config_value METHOD)"
		ENABLE_MTU="no" # для внутренних интерфейсов коррекция не требуется
		ENABLE_MASQ="no"
	else
		log "Пакет не настроен! Не выбран ни один интерфейс выхода. Выполните kvl vpn set" 3
	   	return 1	
	fi
	# сохраняем полученный параметры в кэш
	create_fast_config || log "Failed to create fast config /tmp/kvl_config.sh" 3
}

# инициализация пакета при старте роутера
cmd_kvl_start() {
	#Cоздаем таблицу IPset для белого списка адресов, 
	ip4_route__create_ipset
	# добавляем условие маршрутизации в таблицу
	ip4_route__add_rule || log "Failed to add route rule" 3
	# сразу же включаем маркировку трафика
	ip4_iptab__mangle_mark || log "Failed to mark mangle" 3
	# если включен перенаправление DNS то так же сразу добавляем
	ip4_iptab__nat_dns_redirect || log "Failed to redirect DNS" 3
	# далее подготовка провайдера
	if ip4_vpn__provider_ready; then
		ip4_route__add_table  || log "Failed to add table routing" 3
		ip4_vpn__insert_all_vpn_rules  || log "Failed to add all iptables rules" 3
	fi
	# вносим в ipset только ip адреса из списка
	ip4_vpn__insert_static_ip_ipset &> /dev/null
	return 0
}	

cmd_kvl_stop(){
	#  IPset мы не можем удалить, он используется не только в этом скрипте, а также в DNS и ULOG. 
	ip4_iptab__cleanup_all_user_rules &> /dev/null
	ip4_iptab__cleanup_all_user_rules "${PREF_HOLD}" &> /dev/null # до удаляем еще цепочку маркировки в mangle так как по умолчанию она не удаляется
	ip4_route__del_rule &> /dev/null
	ip4_route__del_route_table &> /dev/null
	return 0
}

cmd_kvl_restart(){
	cmd_kvl_stop
	sleep 1
	cmd_kvl_start
	return 0
}

switch_vpn() {
	local new_provider="$1"
	local new_method="$2"
	local new_inface_cli="$3"
	local new_inface_ent="$4"
	local new_plugin_name="$5"
	local old_plugin_name
	# проверяем что пакет запущен
	if ! ip4_route__rule_exists; then
		log "Пакет КВАС ЛАЙТ не был запущен изменение интерфейса выхода трафика недоступно" 3
		return 1
	fi
	old_plugin_name="$(get_config_value PLUGIN_NAME)"

	# --- Остановка старого плагина ---
	if [ "$PROVIDER" = "plugin" ]; then
		if [ "$new_provider" != "plugin" ] || [ "$old_plugin_name" != "$new_plugin_name" ]; then
			ip4_vpn__stop_plugin "$old_plugin_name" "$INFACE_CLI"
		fi
	fi

	ip4_iptab__cleanup_all_user_rules
	show_result $? "Очищаем iptables от пользовательских правил маршрутизации" "УСПЕШНО" "ОШИБКА" 3


	if command -v conntrack >/dev/null 2>&1; then
		local _dig_mark=$((FWMARK_NUM))
		if conntrack -L --mark "$_dig_mark" 2>/dev/null | grep -q 'src='; then
			conntrack -D --mark "$_dig_mark" &>/dev/null
			show_result $? "Выполняем очистку старых записей conntrack" "УСПЕШНО" "ОШИБКА" 2
		else
			show_result 0 "Записи в conntrack с меткой ${FWMARK_NUM} отсутствуют" "УСПЕШНО" ""
		fi
	else
		show_result 1 "Утилита conntrack не установлена в системе" "" "ОШИБКА" 3
	fi
	

	# --- Запуск нового плагина ---
	if [ "$new_provider" = "plugin" ]; then
#		if [ "$PROVIDER" != "plugin" ] || [ "$old_plugin_name" != "$new_plugin_name" ]; then
			ip4_vpn__start_plugin "$new_plugin_name"
#		fi
	else
		METHOD="$new_method"
		INFACE_CLI="$new_inface_cli"
		INFACE_ENT="$new_inface_ent"
		set_config_value METHOD "$METHOD"
		set_config_value INFACE_CLI "$INFACE_CLI"
		set_config_value INFACE_ENT "$INFACE_ENT"
	fi

	PROVIDER="$new_provider"
	set_config_value PROVIDER "$PROVIDER"
	set_config_value PLUGIN_NAME "$new_plugin_name"
	ip4_route__add_table
	ip4_vpn__insert_all_vpn_rules
	show_result $? "Выполняем настройку новых пользовательских правил в iptables" "УСПЕШНО" "ОШИБКА" 3
	log "VPN активирован: PROVIDER=$PROVIDER, METHOD=$METHOD, CLI=$INFACE_CLI, ENT=$INFACE_ENT, PLUGIN=$new_plugin_name"
	# сохраняем полученный параметры в кэш
	create_fast_config || log "Failed to create fast config /tmp/kvl_config.sh" 3
}

# фильтруем список интерфейсов 
get_iface_sort_json() {
	local types_string="|OpenVPN|Wireguard|IKE|SSTP|PPPOE|L2TP|PPTP|Proxy|"
	local line cli ent type iface_json="[]"

	while IFS= read -r line || [ -n "$line" ]; do
		type=$(echo "$line" | cut -d"|" -f3)
		echo "|$types_string|" | grep -qF "|$type|" || continue
		cli=$(echo "$line" | cut -d"|" -f1)
		ent=$(echo "$line" | cut -d"|" -f2)
		# Добавляем объект в JSON-массив
		iface_json=$(echo "$iface_json" | jq --arg cli "$cli" --arg ent "$ent" --arg type "$type" \
  			'. + [ { type: "internal", data: { cli: $cli, ent: $ent, type: $type } } ]')
	done < "$INFACE_NAMES_FILE"
	echo "$iface_json"
}

# Получает список всех плагинов с данными info и выводит JSON-массив
get_plugins_info_json() {
	local plugin_file plugin_json plugin_name
	local json_array="[]"

	for plugin_file in "$PLUGIN_DIR"/*.sh; do
		[ -f "$plugin_file" ] || continue
		plugin_json=$("$plugin_file" info 2>/dev/null) || continue
		[ -z "$plugin_json" ] && continue
		plugin_name=$(basename "$plugin_file" .sh)
		json_array=$(echo "$json_array" | jq \
  			--arg name "$plugin_name" \
  			--argjson info "$plugin_json" \
  			'. + [ { type: "plugin", data: ($info + { plugin: $name }) } ]')
	done
	echo "$json_array"
}

print_iface() {
	local iface_json  cli ent type cli_desc net_ip connected ret mess
	num="$1"
	iface_json="$2"
	cli=$(echo "$iface_json" | jq -r ".cli")
	ent=$(echo "$iface_json" | jq -r ".ent")
	type=$(echo "$iface_json" | jq -r ".type")
	cli_desc=$(get_decription_cli_inface "$cli")
	net_ip=$(get_ip_by_inface "$ent")
	[ -z "$net_ip" ] && net_ip="[-.-.-.-]" || net_ip="[${net_ip}]"
	mess="$num. Интерфейс $type $cli_desc $net_ip"
	connected=$(is_interface_online "$cli")
	if [ "$PROVIDER" = "internal" ] && [ -n "$INFACE_ENT" ] && [ "$ent" = "$INFACE_ENT" ]; then
		mess="${BLUE}${mess} текущий${NOCL}"
	fi
	[ "$connected" = "on" ]
	ret=$?
	show_result "$ret" "$mess" "В СЕТИ" "ОТКЛЮЧЕН" 0
}

print_plugin() {
	num="$1"
	plugins_json="$2"
	name=$(echo "$plugins_json" | jq -r ".name")
    desc=$(echo "$plugins_json" | jq -r ".description")
    type=$(echo "$plugins_json" | jq -r ".type")
    plugin_file=$(echo "$plugins_json" | jq -r ".plugin")
    line="$num. $name — $desc [$type]"
    if [ "$PROVIDER" = "plugin" ] && [ "$cur_plugin" = "$plugin_file" ]; then
        line="${BLUE}${line} текущий${NOCL}"
    fi
    echo -e "$line"
}

print_list_json(){
	local count="$1"
	local json="$2"
	cur_plugin="$(get_config_value PLUGIN_NAME)"
	i=0 
	while [ "$i" -lt "$count" ]; do
		type=$(echo "$json" | jq -r ".[$i].type")
		data=$(echo "$json" | jq -r ".[$i].data")
		i=$((i+1))
		case $type in
			internal) print_iface "$i" "$data" ;;
			plugin) print_plugin "$i" "$data" ;;
		esac
		
	done	
}
# команда выбора интерфейса для выхода через выбранное соединение
cmd_vpn_choose_vpn(){
	local iface_json plugins_json all_json count chosen_index
	local find_vpn="$1"
	iface_json=$(get_iface_sort_json)
	plugins_json=$(get_plugins_info_json)
	all_json=$(jq -n \
    --argjson a "$iface_json" \
    --argjson b "$plugins_json" \
    '$a + $b')
	count=$(echo "$all_json" | jq 'length')
	if [ "$count" -eq 0 ]; then
		report_json_or_console "empty" "[]" "Файл со списком доступных интерфейсов пуст. Вы не создали 'другие подключения' в роутере или не установлены плагины" >&2
		return 1
	fi
	if [ -n "$find_vpn" ]; then
		# ищем в имени интерфейса или названии плагина, если нет то выходим с ошибкой
		chosen_index=$(echo "$all_json" | jq -r --arg s "$find_vpn" 'to_entries[] | select(.value.data.ent == $s or .value.data.plugin == $s) | .key')
		if [ -z "$chosen_index" ]; then
			report_json_or_console "error" "[]" "Ошибка: интерфейс или с ключём:'${find_vpn}' не найден в списке доступных. Проверьте ввод." >&2
			return 1	
		fi
	elif [ -n "$_INTERACTIVE_" ]; then
		color_echo "${GREEN}Выберите VPN интерфейс для работы пакета${NOCL}"
		print_line
		print_list_json "$count" "$all_json" 
		print_line	
		if ! ask_user_to_choose "$count" "Выберите номер варианта VPN соединения" chosen_index; then
    		return 1
		fi
		chosen_index=$((chosen_index - 1))
	fi
	type=$(echo "$all_json" | jq -er ".[$chosen_index].type") || {
		report_json_or_console "error" "[]" "Ошибка: нет элемента с индексом $chosen_index. Проверьте ввод." >&2
    	return 1
	}
	case $type in
		internal)
			sel_cli_inface=$(echo "$all_json" | jq -r ".[$chosen_index].data.cli")
			sel_ent_inface=$(echo "$all_json" | jq -r ".[$chosen_index].data.ent")
			method=wg
			plugin_file=""
			;;
		plugin) 
			plugin_file=$(echo "$all_json" | jq -r ".[$chosen_index].data.plugin")
			method=$(echo "$all_json" | jq -r ".[$chosen_index].data.method")
			sel_cli_inface=""
			sel_ent_inface=""
			;;
		*)
			report_json_or_console "error" "[]" "Ошибка: неизвестный тип '$type'" >&2
    		return 1
			;;	
	esac
	switch_vpn "$type" "$method" "$sel_cli_inface" "$sel_ent_inface" "$plugin_file"
	return 0
}

cmd_vpn_show_vpn() {
	case "$PROVIDER" in
		internal)
			local cli_desc net_ip connected
			echo "Тип выхода - встроенный" 
			cli_desc=$(get_decription_cli_inface "$INFACE_CLI")
			echo "Наименование: $cli_desc"
			net_ip=$(get_ip_by_inface "$INFACE_ENT")
			[ -z "$net_ip" ] && net_ip="[-.-.-.-]" || net_ip="[${net_ip}]"
			echo "IP адрес клиента: $net_ip"
			connected=$(is_interface_online "$INFACE_CLI")
			echo -n "Состояние подключения: "
			if [ "$connected" = "yes" ]; then
				echo "ПОДКЛЮЧЕННО"
			else
				echo "ОТКЛЮЧЕНО"
			fi
			;;
		plugin) 
			echo "Тип выхода - плагин" 
			local pluginfile plugin_path
			pluginfile="$(get_config_value PLUGIN_NAME)"
			plugin_path="${PLUGIN_DIR%/}/${pluginfile}.sh"
			if [ -f "$plugin_path" ]; then
				"$plugin_path" info
			fi
			;;
	esac
}
#=============================================================================================

add_host_to_ipset() {
	local host="$1"
	local dns_mode ip_list ip

	# если список существует
	if ipset list -n | grep -qx "${IPSET_TABLE_NAME}"; then
		# получаем список из адресов от текущего dns сервера br0:53
		# и исключаем из списка адреса типа 0.0.0.0
		echo -e "Получаем DNS адреса хоста: ${GREEN}$host${NOCL}"
		ip_list=$(kdig +short "$host" "@$ROUTER_IP" | grep -Eo "$IP_FILTER" | grep -v '0.0.0.0' )

		# 	если список не пуст добавляем в список маршрутизации IPSET_TABLE_NAME. Это не поможет для третьего уровня, но для $host сразу откроет доступ
		if [ -n "${ip_list}" ]; then
			for ip in ${ip_list}; do
				echo -e "Полученный IP-адрес ${BLUE}$ip${NOCL} добавляем в таблицу маршрутизации ${WHITE}$IPSET_TABLE_NAME${NOCL}"
				ipset -exist add "$IPSET_TABLE_NAME" "$ip" &> /dev/null
			done
		fi
	fi	
	# далее в зависимости от текущей схемы ДНС добавляем домен в фильт маршрутизации и перезапускаем сервис 
	get_dns_mode dns_mode
	case "$dns_mode" in
		dnsmasq)
			echo -e "Добавляем запись в файл конфигурации ${BLUE}dnsmasq${NOCL}"
			echo "ipset=/${host}/${IPSET_TABLE_NAME}" >> "${DNSMASQ_IPSET_HOSTS}"
			if [ -f "$DNSMASQ_DEMON" ]; then
				echo -e "Перезапускаем сервер ${BLUE}dnsmasq${NOCL}"
				$DNSMASQ_DEMON restart #&> /dev/null
			fi
			;;
		adguard)
			echo -e "Добавляем запись в файл конфигурации ${BLUE}AdGuard Home${NOCL}"
			echo "${host}/${IPSET_TABLE_NAME}" >> "${ADGUARD_IPSET_FILE}"
			if [ -f "$ADGUARDHOME_DEMON" ]; then 
				echo -e "Перезапускаем сервер ${BLUE}AdGuard Home${NOCL}"
				$ADGUARDHOME_DEMON restart #&> /dev/null
			fi
			;;
		*)
			echo -e "${RED}ОШИБКА определения DNS сервера. Сервер DNS не перезашущен.${NOCL}"
			;;
	esac
}

del_host_to_ipset() {
	local host="$1"
	local dns_mode ip_list ip
	# если список существует попытаемся хотя бы частично удалить из него ip адреса
	if ipset list -n | grep -qx "${IPSET_TABLE_NAME}"; then
		# получаем список из адресов от текущего dns сервера br0:53
		# и исключаем из списка адреса типа 0.0.0.0
		echo -e "Получаем DNS адреса хоста: ${GREEN}$host${NOCL}"
		ip_list=$(kdig +short "$host" "@$ROUTER_IP" | grep -Eo "$IP_FILTER" | grep -v '0.0.0.0' )

		# 	если список не пуст удаляем из списка маршрутизации IPSET_TABLE_NAME. Это не поможет для третьего уровня, но для $host сразу заблокирует доступ
		if [ -n "${ip_list}" ]; then
			for ip in ${ip_list}; do
				echo -e "Полученный ip адрес ${BLUE}$ip${NOCL} удаляем из таблицы маршрутизации ${WHITE}$IPSET_TABLE_NAME${NOCL}"
				ipset del "$IPSET_TABLE_NAME" "$ip" &> /dev/null
				ipset del "$IPSET_ULOG_NAME" "$ip" &> /dev/null
				local _dig_mark=$((FWMARK_NUM))
				conntrack -D --orig-dst "$ip" --mark "$_dig_mark" &> /dev/null
			done
		fi
	fi
	# далее в зависимости от текущей схемы ДНС удаляем домен из конфигурации и перезапускаем сервис 
	get_dns_mode dns_mode
	case "$dns_mode" in
		dnsmasq)
			sed -i "/^ipset=\/${host////\\/}\/[^/]*$/d" "${DNSMASQ_IPSET_HOSTS}"
			if [ -f "$DNSMASQ_DEMON" ]; then
				echo -e "Перезапускаем сервер ${BLUE}dnsmasq${NOCL}"
				$DNSMASQ_DEMON restart #&> /dev/null
			fi
			;;
		adguard)
			sed -i "/^${host////\\/}\/[^/]*$/d" "${ADGUARD_IPSET_FILE}"
			if [ -f "$ADGUARDHOME_DEMON" ]; then 
				echo -e "Перезапускаем сервер ${BLUE}AdGuard Home${NOCL}"
				$ADGUARDHOME_DEMON restart #&> /dev/null
			fi
			;;
	esac		
}

cmd_list_show() {
	local line
	local count=0
	local json_entries=""

	if [ ! -f "${KVL_LIST_WHITE}" ]; then
		report_json_or_console "error" '[]' \
			"${RED}Списка маршрутизации не существует.${NOCL}" \
			"Пожалуйста, добавьте в него данные при помощи ${BLUE}'kvl list add <domain|ip|network>'${NOCL}"
		return
	fi

	while IFS= read -r line; do
		# Пропускаем пустые строки
		[ -z "$line" ] && continue

		if [ "$JSON_OUTPUT" -eq 1 ]; then
			# Накапливаем JSON (через запятую)
			[ "$count" -gt 0 ] && json_entries="${json_entries},"
			json_entries="${json_entries}\"$line\""
		elif [ -n "$_INTERACTIVE_" ]; then
			# Выводим построчно и с подсветкой
			case "$line" in
				*/*)
					line="${YELLOW}$line${NOCL}" ;;
				*.*.*.*)
					line="${GREEN}$line${NOCL}" ;;
				*)
					line="${BLUE}$line${NOCL}" ;;
			esac
			printf "%3d. %b\n" $((count + 1)) "$line"
		fi

		count=$((count + 1))
	done < "${KVL_LIST_WHITE}"

	if [ "$count" -eq 0 ]; then
		report_json_or_console "ok" '[]' \
			"${RED}Список маршрутизации пуст!${NOCL}" \
			"Пожалуйста, добавьте данные при помощи ${BLUE}'kvl list add <domain|ip|network>'${NOCL}"
		return
	fi

	if [ "$JSON_OUTPUT" -eq 1 ]; then
		printf '{"status":"ok","data":{"count":%d,"list":[%s]}}\n' "$count" "$json_entries"
	else
		color_echo "Список маршрутизации содержит ${GREEN}${count}${NOCL} записей:"
	fi
}

cmd_list_add() {
	local host flag_ip=0
	host=$(echo "$1" | sed 's|http[s]\{,1\}://||; s/\*//g; s|/*$||')	# Удаляет протокол http:// или https:// и все * из строки если есть
	if [ -z "$host" ]; then
		report_json_or_console "empty" "[]" "Usage: kvl list add <domain|ip|network>"
		return 1
	fi
	local ip_filter='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    local cidr_filter='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
	if  echo "$host" | grep -Eq "$ip_filter|$cidr_filter"; then
	    # тогда это должен быть корректный IP/сеть
    	if ! ipcalc -cs "$host" >/dev/null 2>&1; then
        	report_json_or_console "error" "[]" "Неверный IP-адрес или диапазон: $host"
        	return 1
		else
			flag_ip=1	
    	fi
	fi
	# Проверка, есть ли уже такая точная запись в файле
	if [ -f "$KVL_LIST_WHITE" ] && grep -Fxq "$host" "$KVL_LIST_WHITE"; then
		report_json_or_console "already" "[]" "Запись ${GREEN}'$host'${NOCL} уже есть в списке"
		return 1
	fi

	# Добавляем запись в конец файла
	echo -e "${WHITE}Добавляем хост ${GREEN}'$host'${WHITE} в список маршрутизации${NOCL}"
	echo "$host" >> "$KVL_LIST_WHITE"
	if [ "$flag_ip" -eq 0 ]; then
		add_host_to_ipset "$host"
	else
		ipset -exist add "$IPSET_TABLE_NAME" "$host" timeout 0 &> /dev/null
	fi	
	report_json_or_console "ok" "[]" "Запись ${GREEN}'$host'${NOCL} добавлена"
	echo -e "Внимание! Доступ к ресурсу появится сразу, однако если это домен с поддоменами,"
	echo -e "то доступ к поддоменам может появиться только после повторного DNS-запроса."
	echo -e "Чтобы ускорить процесс:"
	echo -e "  • Windows: ${WHITE}ipconfig /flushdns${NOCL}"
	echo -e "  • Linux:   ${WHITE}systemd-resolve --flush-caches${NOCL} или ${WHITE}resolvectl flush-caches${NOCL}"
	echo -e "  • macOS:   ${WHITE}sudo killall -HUP mDNSResponder${NOCL}"
	echo -e "  • Android: закройте и перезапустите приложение"
	return 0
}

cmd_list_del() {
	local host flag_ip=0
	host=$(echo "$1" | sed 's|http[s]\{,1\}://||; s/\*//g; s|/*$||')	# Удаляет протокол http:// или https:// и все * из строки если есть
	if [ -z "$host" ]; then
		report_json_or_console "empty" "[]" "Usage: kvl list del <domain|ip|network>"
		return 1
	fi
	if ! [ -f "$KVL_LIST_WHITE" ] || ! grep -Fxq "$host" "$KVL_LIST_WHITE"; then
		report_json_or_console "error" "[]" "Запись ${RED}'$host'${NOCL} не найдена в списке маршрутизации"
		return 1
	fi
	local ip_filter='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    local cidr_filter='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
	if  echo "$host" | grep -Eq "$ip_filter|$cidr_filter"; then
	    # тогда это должен быть корректный IP/сеть
    	if ! ipcalc -cs "$host" >/dev/null 2>&1; then
        	report_json_or_console "error" "[]" "Неверный IP-адрес или диапазон: $host"
        	return 1
		else
			flag_ip=1
    	fi
	fi

	# Экранируем косую черту для sed
	local esc_entry="${host//\//\\/}"
	# удаляем запись в списке
	sed -i "/^${esc_entry}\$/d" "$KVL_LIST_WHITE"
	if [ "$flag_ip" -eq 0 ]; then
		del_host_to_ipset "$host"
	else
		ipset del "$IPSET_TABLE_NAME" "$host" &> /dev/null
	fi
	report_json_or_console "ok" "[]" "Запись ${GREEN}'$host'${NOCL} удалена"
	echo -e "Внимание! Если удалена запись для отдельного хоста, его IP-адреса немедленно исключаются из списка маршрутизации"
	echo -e "и доступ через выбранное соединение прекращается сразу."
	echo -e "Если удалённая запись — это домен с поддоменами, то адреса поддоменов, которые уже использовались ранее,"
	echo -e "могут оставаться в таблице маршрутизации ещё некоторое время."
	echo -e "В таких случаях доступ к ним прекратится только после автоматического обновления адресов,"
	echo -e "что может занять от нескольких минут до нескольких часов."
	return 0
}

cmd_vpn_redirect(){
	local action="$1"
    local current

    # Получаем текущее значение
    current=$(get_config_value DNS_REDIRECT)
    [ "$current" = "yes" ] && display_current="${GREEN}включено${NOCL}" || display_current="${RED}выключено${NOCL}"

	color_echo "Сейчас DNS перенаправление: $display_current"
	color_echo "Когда включено, все DNS-запросы перенаправляются на локальный сервер роутера,"
	color_echo "что повышает вашу приватность и защищает от возможной подмены запросов провайдером."

    # Если аргумент не передан, спрашиваем пользователя
    if [ -z "$action" ]; then
        color_echo "Включить DNS перенаправление? (y/n/q-Выход)"
        read -r answer
        case "$answer" in
            y|Y) action="on" ;;
            n|N) action="off" ;;
			q|Q) color_echo "Операция прервана";  return 0 ;;
            *) color_echo "Неверный выбор"; return 1 ;;
        esac
    fi
    case "$action" in
        on)
            set_config_value DNS_REDIRECT yes
            color_echo "DNS перенаправление включено."
            ip4_iptab__nat_dns_redirect
            ;;
        off)
            set_config_value DNS_REDIRECT no
            color_echo "DNS перенаправление отключено."
            ip4_iptab__nat_dns_redir_del
            ;;
        *)
            color_echo "Неверный параметр. Используйте kvl dns redir {on|off}"
            return 1
            ;;
    esac
}

cmd_vpn_change_port_dns(){
	local new_port="${1}"
	local cmd="${2:-restart}"
	if [ -z "$new_port" ]; then
		current=$(get_config_value DNS_CRYPT_PORT)
		color_echo "Текущий порт в конфигурационном файле пакета: $current хотите поменять?"
		read_value "Введите новый порт (1024-65535):" new_port digit
		[[ "$new_port" =~ ^[Qq]$ ]] && return 1
	fi	
	if [[ $new_port -lt 1024 || $new_port -gt 65535 ]]; then
    	color_echo "Ошибка: порт должен быть в диапазоне 1024-65535"
    	exit 1
	fi
	if netstat -tuln | grep -q ":$new_port "; then
    	color_echo "Ошибка: порт $new_port занят"
    	exit 1
	fi
	# Обновляем dnsmasq
	sed -i "s/server=127.0.0.1#[0-9]*/server=127.0.0.1#$new_port/" /opt/etc/dnsmasq.conf
	# Обновляем dnscrypt-proxy2
	sed -i -E "1,/^[[:space:]]*listen_addresses = .*/ s|^[[:space:]]*listen_addresses = .*|listen_addresses = ['127.0.0.1:$new_port']|" /opt/etc/dnscrypt-proxy.toml
	# Перезапускаем сервисы
	local dns_mode
	get_dns_mode dns_mode
	if [ "$cmd" = "restart" ] && [ "$dns_mode" = "dnsmasq" ]; then
		color_echo "Перезапускаем dnsmasq"
		manage_demon "$DNSMASQ_DEMON" restart
		color_echo "Перезапускаем dnscrypt-proxy2"
		manage_demon "$DNSCRYPT_DEMON" restart
	fi
	set_config_value DNS_CRYPT_PORT "$new_port"
	color_echo "Порт изменён на $new_port"
}

_check_dnsmasq_conf() {
	local port  err err2
	# Проверка и синхронизация портов
	port=$(get_config_value DNS_CRYPT_PORT)
	if [ -z "$port" ]; then
		port=9153
		set_config_value DNS_CRYPT_PORT "$port"
	fi
	err=0
	awk -v ttl="max-ttl=${IPSET_TTL}" \
		-v lroute="listen-address=${ROUTER_IP}" \
		-v l127="listen-address=127.0.0.1" \
		-v conf="conf-file=${DNSMASQ_IPSET_HOSTS}" \
		-v serv="server=127.0.0.1#${port}" '
	BEGIN {
		need[ttl]=0
		need[lroute]=0
		need[l127]=0
		need[conf]=0
		need["proxy-dnssec"]=0
		need[serv]=0
	}
	# пропускаем полностью закомментированные строки
	/^[[:space:]]*#/ { next }

	{
		# ищем вхождение подстроки; хвостовые комментарии не мешают
		for (n in need) {
			if (index($0, n) > 0) need[n]=1
		}
	}
	END {
		exitcode=0
		for (n in need) {
			if (!need[n]) {
				printf "Не найдено требуемое значение: %s \n", n > "/dev/stderr"
				exitcode=1
			}
		}
		exit exitcode
	}
	' /opt/etc/dnsmasq.conf || err=1
	show_result $err "Проверка конфигурации DNSMasq"
	err2=0
	if ! grep -q "^[[:space:]]*listen_addresses = \['127.0.0.1:$port'\]" /opt/etc/dnscrypt-proxy.toml; then
		echo "Не найдено требуемое значение: listen_addresses = ['127.0.0.1:$port']" > "/dev/stderr"
		err2=1
	fi
	show_result $err2 "Проверка конфигурации DNSCrypt-proxy"

	return $((err + err2))
}

_fix_dnsmasq_configs() {
    local errors="$1"
	local port tmpfile
	port=$(get_config_value DNS_CRYPT_PORT)
    # ---- Исправляем dnscrypt-proxy.toml ----
    if ! grep -q "^[[:space:]]*listen_addresses = \['127.0.0.1:$port'\]" /opt/etc/dnscrypt-proxy.toml; then
		sed -i -E "1,/^[[:space:]]*listen_addresses = .*/ s|^[[:space:]]*listen_addresses = .*|listen_addresses = ['127.0.0.1:$port']|" /opt/etc/dnscrypt-proxy.toml
		show_result $? "Исправление конфигурационного файла dnscrypt-proxy2" "ВЫПОЛНЕННО" "ОШИБКА"
        errors=$((errors - 1))
    fi
    # если больше ошибок нет — выходим
    if [ "$errors" -eq 0 ]; then
        return 0
    fi
    # ---- Исправляем dnsmasq.conf ----
    {
	tmpfile="$(mktemp /tmp/dnsmasq_conf.XXXXXX)"
	awk -v route_ip="$ROUTER_IP" \
    -v changes="max-ttl=$IPSET_TTL;conf-file=$DNSMASQ_IPSET_HOSTS;server=127.0.0.1#$port" '
	BEGIN {
		split(changes, arr, ";")
		for (i in arr) {
			split(arr[i], kv, "=")
			params[kv[1]] = kv[2]
		}
		done_listen = 0
		dnssec = 0
	}
	# комментарии не трогаем
	/^[[:space:]]*#/ { print; next }
	{
		if ($0 ~ /^listen-address=/) {
			if (!done_listen) {
				print "listen-address=" route_ip
				print "listen-address=127.0.0.1"
				done_listen=1
			}
			next
		}
		# conf-dir — закомментировать
		if ($0 ~ /^conf-dir=/) { sub(/^[[:space:]]*/, "&#", $0); print; next }
		# proxy-dnssec — ставим флаг
		if ($0 ~ /^proxy-dnssec/) { dnssec=1; print; next }
		# заменяем параметры из массива params
		for (param in params) {
			if (match($0, "^[[:space:]]*" param "=[^[:space:]]*")) {
				prefix  = substr($0, 1, RSTART + length(param) )
				comment = substr($0, RSTART + RLENGTH)
				$0 = prefix params[param] comment
				found[param] = 1
				break
			}
		}
		print
	}
	END {
		if (!done_listen) {
			print "listen-address=" route_ip
			print "listen-address=127.0.0.1"
		}
		for (param in params) {
    		if (!found[param]) print param "=" params[param]
		}
		if (!dnssec) print "proxy-dnssec"
	}
	' /opt/etc/dnsmasq.conf > "$tmpfile"
	mv "$tmpfile" /opt/etc/dnsmasq.conf
	}
	show_result $? "Исправление конфигурационного файла dnsmasq" "ВЫПОЛНЕННО" "ОШИБКА"
}



# Установка AdGuard Home через opkg (adguardhome-go)
_install_adguard() {
	local ans
    color_echo "AdGuard Home не установлен. Понадобится ~14 МБ в /opt."
    printf "Установить AdGuard Home? [y/N]: "
    read -r ans
    case "$ans" in
        y|Y)
            opkg update >/dev/null 2>&1 
            if opkg install adguardhome-go; then
                # После установки — до настройки не автозапускать при перезагрузке роутера 
                [ -f "$ADGUARDHOME_DEMON" ] && sed -i 's/^ENABLED=yes.*/ENABLED=no/' "$ADGUARDHOME_DEMON"
				# Исправляем конфигурацию что бы Лог и ПИД файл записывался в память а не на флешку
    			[ -f "$ADGUARDHOME_CONF" ] && sed -i -E '/^(LOG|PID)=/ s#/opt##g' "$ADGUARDHOME_CONF"
                color_echo "${GREEN}Пакет установлен!${NOCL}"
                color_echo "Открой в браузере: http://$ROUTER_IP:3000 и пройди мастер (5 шагов):"
                color_echo "  1) Веб-интерфейс администрирования: выбери интерфейс br0 (если хотите администрировать только с локальной сети),"
				color_echo "     порт выбери 80 если свободен или например 8080, либо другой свободный."
                color_echo "  2) DNS-сервер: «Все интерфейсы», порт 53 (если 53 занят — любой свободный, при старте заменятся на стандартный 53)."
                color_echo "  3) Авторизация: задай логин/пароль (можешь такие же, как на роутере)."
				color_echo "     ${YELLOW}Один раз!${NOCL} уверенно нажми «Продолжить» и подожди до ~1 минуты. Через непродолжительное время отобразится следующее окно"
                color_echo "  4) После финиша мастера вернись и снова запусти ${WHITE}'kvl dns mode'${NOCL} для активации и выбора AdGuard Home."
                return 0
            else
                color_echo "${RED}Ошибка установки AdGuard Home.${NOCL}"
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

_check_adguard_yaml() {
	local result port bh bh2 ipset
    result="$(awk '
   		/^dns:/ { in_dns=1; next }       # вошли в секцию dns
        in_dns {
                if ($0 !~ /^ /) exit
                if ($1=="port:") { port=$2 }
                if ($1=="bind_hosts:") { bind=1 }
				if (bind==2 && $1=="-") { bh2=$2; bind=0 }
                if (bind==1 && $1=="-") { bh=$2; bind=2 }
				
                if ($1=="ipset_file:") {
                    sub(/ipset_file:[ ]*/, "", $0)
                    gsub(/"/,"",$0)      # убрать кавычки
                    ipset=$0
                }
        }
        END { print port, bh, bh2, ipset }
        ' "$ADGUARDHOME_YAML")"
    read -r port bh bh2 ipset <<EOF
$result
EOF
    if [ "$port" = 53 ] && [ "$bh" = "$ROUTER_IP" ] && [ "$bh2" = "127.0.0.1" ] && [ "$ipset" = "$ADGUARD_IPSET_FILE" ]; then
        return 0
    else
        return 1
    fi
}

_fix_adguard_yaml() {
    {
	local TMP_FILE
	TMP_FILE=$(mktemp /tmp/adguard_conf.XXXXXX)
	ttl_max=$(( IPSET_TTL - 50 ))
    awk -v ip_route="$ROUTER_IP" -v ipset="$ADGUARD_IPSET_FILE" -v ttl_max="$ttl_max" '
    BEGIN { in_dns=0; in_bind=0 }
    /^dns:/ { in_dns=1; print; next }
    /^[^ ]/ { in_dns=0 }  # вышли из секции dns
    in_dns {
        if ($1=="port:") { print "  port: 53"; next }
        if ($1=="ipset_file:") { print "  ipset_file: \"" ipset "\""; next }
        if ($1=="bind_hosts:") { print "  bind_hosts:"; print "    - " ip_route; print "    - 127.0.0.1"; in_bind=1; next }
		if ($1=="cache_ttl_max:") { print "  cache_ttl_max: " ttl_max ; next }
        if (in_bind && $1 ~ /^-/) { next }
        if (in_bind && $1 !~ /^-/) { in_bind=0 }
    }
    { print }  # печатаем все остальные строки без изменений
    ' "$ADGUARDHOME_YAML" > "$TMP_FILE"
    mv "$TMP_FILE" "$ADGUARDHOME_YAML"
	}
	show_result $? "Исправление конфигурационного файла AdGuard Home" "ВЫПОЛНЕННО" "ОШИБКА"
}

WGET='/opt/bin/wget -q --no-check-certificate'
# Выполняем команду отключения DNS провайдера без перезагрузки и выхода из сессии
rci_post()($WGET -qO - --post-data="$1" localhost:79/rci/ > /dev/null 2>&1)

cmd_vpn_dns_mode() {
	is_dns_override
	ret=$?
	if [ $ret -ne 0 ]; then
	  	cli="$ROUTER_IP/a"
		color_echo ""
		color_echo "${RED}Для корректной работы DNS сервера необходимо отключить использование DNS провайдера!${NOCL}"
		color_echo "С этой целью зайдите в админ панель роутера по адресу: ${GREEN}${cli}${NOCL}"
		color_echo "и выполните последовательно три следующих команды: "
		print_line
		color_echo "1. ${GREEN}opkg dns-override ${NOCL}           - отключаем использование DNS провайдера,"
		color_echo "2. ${GREEN}system configuration save ${NOCL}   - сохраняем изменения,"
		color_echo "3. ${GREEN}system reboot ${NOCL}               - перегружаем роутер."
		color_echo ""
		color_echo "После перезагрузки снова запустите 'kvl dns mode' для выбора режима работы ДНС"
		print_line

		color_echo ""
		color_echo "Так же можно попробовать выполнить 1 и 2 команду автоматически без перезагрузки роутера."
		color_echo "При этом возможна кратковременный разрыв связи."
		echo -en "${BLUE}Попытаться отключить DNS роутрера автоматически? [y/N]: ${NOCL}"
    	read -r ans
    	case "$ans" in
        	y|Y) 
				# Отключаем системный DNS-сервер роутера
				color_echo 'Отключаем работу через DNS-провайдера  роутера...'
				color_echo "Возможно, что сейчас произойдет выход из сессии..."
				color_echo "В этом случае необходимо заново войти в сессию по ssh"
				color_echo "и выполнить команду 'kvl dns mode'"
				rci_post '[{"opkg": {"dns-override": true}},{"system": {"configuration": {"save": true}}}]' &>/dev/null 
				color_echo ""
				color_echo "Если Вы еще здесь то снова запустите 'kvl dns mode' для проверки отключения и выбора рабочего режима работы ДНС"
				;;
		esac
		exit 1
	fi

	color_echo ""
	print_line
	color_echo "${YELLOW}dnsmasq + dnscrypt-proxy2${NOCL}"
	color_echo "➜ Лёгкий DNS-сервер с шифрованием через dnscrypt."
	color_echo "${GREEN}Плюсы:${NOCL} низкая нагрузка, безопасные DNS-запросы."
	color_echo "${RED}Минусы:${NOCL} нет встроенной фильтрации рекламы."
	color_echo ""
	color_echo "${YELLOW}AdGuard Home${NOCL}"
	color_echo "➜ Полноценный DNS-фильтр с веб-интерфейсом."
	color_echo "${GREEN}Плюсы:${NOCL} фильтрация рекламы и гибкие списки."
	color_echo "${RED}Минусы:${NOCL} выше нагрузка и требуется установка, настройка."
	print_line
	get_dns_mode dns_mode
	case "$dns_mode" in
		dnsmasq)
			color_echo "Текущий режим работы: ${GREEN}dnsmasq + dnscrypt-proxy2${NOCL}"
			;;
		adguard)
			color_echo "Текущий режим работы: ${GREEN}AdGuard Home${NOCL}"
			;;
		*)
			color_echo "Текущий режим работы: ${RED}ОШИБКА определения режима DNS сервера.${NOCL}"
			color_echo " ${RED}Вам точно нужно что то выбрать, не отказываетесь от выбора.${NOCL}"
			;;	
	esac
	print_line
	color_echo ""
	color_echo "1. dnsmasq + dnscrypt-proxy2"
	color_echo "2. AdGuard Home"
	ask_user_to_choose 2 "Ваш выбор: " choice
	# shellcheck disable=SC2154
	case "$choice" in
		1) 
			_check_dnsmasq_conf #2>/dev/null
			ret=$?
			if [ $ret -ne 0 ]; then  
				color_echo "Пытаемся исправить ошибки в конфигурационных файлах связки dnsmasq + dnscrypt-proxy2"
				_fix_dnsmasq_configs $ret
			fi
			# Включаем dnsmasq + dnscrypt-proxy2
			# Останавливаем AdGuard Home, если он установлен и отключаем дальнейший запуск
			manage_demon "$ADGUARDHOME_DEMON" stop no
			# Запускаем связку и автивируем автоматический запуск при старте роутера
			ip4_vpn__refresh_ipset_table no dnsmasq
			manage_demon "$DNSCRYPT_DEMON" start yes
			manage_demon "$DNSMASQ_DEMON" start yes
			color_echo "Режим dnsmasq + dnscrypt-proxy2 активирован"
		;;
		2)
		# Переключение на AdGuard Home
			# проверяем что демон AdGuard Home есть
			if [ ! -f "$ADGUARDHOME_DEMON" ]; then
				_install_adguard
				return 0
			fi
			# если файл существует значит пользователь настроил демон AdGuardHome
			if [ -f "$ADGUARDHOME_YAML" ]; then
				# проверим настройки клиента
				_check_adguard_yaml
				ret=$?
				show_result $ret "Проверка основных параметров AdGuard Home" "БЕЗ ОШИБОК" "ОШИБКИ ИСПРАВЛЯЕМ"
				[ $ret -ne 0 ] && _fix_adguard_yaml
				manage_demon "$ADGUARDHOME_DEMON" stop
				ip4_vpn__refresh_ipset_table no adguard
				manage_demon "$DNSMASQ_DEMON" stop no
				manage_demon "$DNSCRYPT_DEMON" stop no
				manage_demon "$ADGUARDHOME_DEMON" start yes
				color_echo "Режим AdGuard Home активирован"
			else
				color_echo "${YELLOW}Внимание:${NOCL} конфиг AdGuardHome.yaml ещё не создан. Заверши мастер по адресу http://$ROUTER_IP:3000"
				return 0
			fi
		;;
	esac
}