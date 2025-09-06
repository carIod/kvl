#!/bin/sh

JSON_DATA='{}'

# section  key value status
addkey_json() {
    local item
    item="{\"key\":\"$2\",\"value\":\"$3\",\"status\":\"$4\"}"

    JSON_DATA=$(echo "$JSON_DATA" | jq --arg section "$1" --argjson item "$item" '
        if .[$section] then
            .[$section] += [$item]
        else
            . + {($section): [$item]}
        end
    ')
}

# res, section, key, value_ok, stat_ok, value_error, stat_err
addkey_from_result(){
    if [ "$1" -eq 0 ]; then
        addkey_json "$2" "$3" "$4" "$5"
    else
        addkey_json "$2" "$3" "$6" "$7"
    fi
    return "$1"
}

check_files() {
    missing=0
    for f in "$@"; do
        if [ ! -f "$f" ]; then
            echo "Нет файла: $f"
            missing=1
        fi
    done
    return $missing
# пример использования
#check_files /etc/passwd /etc/shadow /tmp/not_exist.txt
#if [ $? -eq 0 ]; then
}

check_dns_listener() {
    local procs count
    # Проверить, что локальный адрес (4-й столбец) заканчивается на :53 и печатает последний столбец
    procs=$(netstat -tulpn 2>/dev/null | awk '{ if ($4 ~ /:53$/) print $NF } ' | sort -u)

    if [ -z "$procs" ]; then
        #echo "Порт 53 не слушается ни TCP, ни UDP"
        return 1
    fi

    count=$(echo "$procs" | wc -l)
    if [ "$count" -eq 1 ]; then
        echo "$procs" | sed 's/^[0-9]*\///'
        return 0
    else
        #echo "Порт 53 слушают несколько процессов: $procs"
        return 2
    fi
}

#============================================================================================
# проверка что есть цепочка в которой маркировки пакетов
check_chain_mark() { 
	#echo "Статус маркировки трафика:"

	# Сохраняем текущие правила iptables для таблицы mangle
    local iptables_save
    iptables_save=$(iptab_save -t mangle)

	# Проверка: цепочка создана
	echo "$iptables_save" | grep -q "^:${VPN_IPTABLES_CHAIN}" > /dev/null 2>&1
	res=$?
    addkey_from_result "$res" "vpn_mark" "Цепочка правил создана?" "ДА" "ok" "НЕТ" "error"
	local status=0
	# Проверка: восстановление марки
	echo "$iptables_save" | grep -q "\-A ${VPN_IPTABLES_CHAIN} -j CONNMARK --restore-mark --nfmask ${FWMARK_NUM}" > /dev/null 2>&1 || status=1
	# Проверка: новая сессия — установка метки
	echo "$iptables_save" | grep -q "\-A ${VPN_IPTABLES_CHAIN} -m conntrack --ctstate NEW -j MARK --set-xmark ${FWMARK_NUM}/${FWMARK_NUM}" > /dev/null 2>&1 || status=1
	# Проверка: сохранение метки
	echo "$iptables_save" | grep -q "\-A ${VPN_IPTABLES_CHAIN} -j CONNMARK --save-mark --nfmask ${FWMARK_NUM} --ctmask ${FWMARK_NUM}" > /dev/null 2>&1 || status=1
	[ "$status" == "0" ]
    addkey_from_result "$?" "vpn_mark" "Установка метки на пакеты" "ДА" "ok" "НЕТ" "error"

	status=0
	# Проверка: PREROUTING перенаправляет в цепочку
	echo "$iptables_save" | grep -q "\-A PREROUTING -m set --match-set ${IPSET_TABLE_NAME} dst -j ${VPN_IPTABLES_CHAIN}" > /dev/null 2>&1 || status=1
	# Проверка: OUTPUT перенаправляет в цепочку
	echo "$iptables_save" | grep -q "\-A OUTPUT -m set --match-set ${IPSET_TABLE_NAME} dst -j ${VPN_IPTABLES_CHAIN}" > /dev/null 2>&1 || status=1
	[ "$status" == "0" ]
    addkey_from_result "$?" "vpn_mark" "Применение правил (PREROUTING/OUTPUT)" "ДА" "ok" "НЕТ" "error"

		# Проверка MTU, если ручной интерфейс
	cli_inface="$(get_config_value INFACE_CLI)"
    if [ "$cli_inface" = "manual" ]; then
		inface_entware="$(get_config_value INFACE_ENT)"
		chain="${START_CHAIN}MTU"
		local status=0
		echo "$iptables_save" | grep -q "^:${chain}" > /dev/null 2>&1 || status=1
		echo "$iptables_save" | grep -q "\-A ${chain} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" > /dev/null 2>&1 || status=1
		echo "$iptables_save" | grep -q "\-A FORWARD -i ${inface_entware} -p tcp -m tcp --tcp-flags SYN,RST SYN -j ${chain}" > /dev/null 2>&1 || status=1
		echo "$iptables_save" | grep -q "\-A FORWARD -o ${inface_entware} -p tcp -m tcp --tcp-flags SYN,RST SYN -j ${chain}" > /dev/null 2>&1 || status=1
        [ "$status" == "0" ]
		addkey_from_result "$?" "vpn_mark" "MTU-коррекция для исходящего трафика" "ДА" "ok" "НЕТ" "warning"
	fi
	return "$res"
}

check_chain_dns_redirect() {
    local iptables_save
    iptables_save=$(iptab_save -t nat)
	# Проверка: цепочка создана
	local status=0
	echo "$iptables_save" | grep -q "^:${PREF_HOLD}DNS" > /dev/null 2>&1 || status=1
	echo "$iptables_save" | grep -q "\-A ${PREF_HOLD}DNS -p udp -m udp --dport ${DNS_PORT} -j REDIRECT --to-ports ${DNS_PORT}" > /dev/null 2>&1 || status=1
	echo "$iptables_save" | grep -q "\-A PREROUTING ! -d $ROUTER_IP/32 -i $LOCAL_INFACE -p udp -m udp --dport ${DNS_PORT} -j ${PREF_HOLD}DNS" > /dev/null 2>&1 || status=1
    [ "$status" == "0" ]
    addkey_from_result "$?" "dns" "Локальное перенаправление DNS" "выполняется" "ok" "не выполняется" "warning"
}

# # выводим статус для модулей которые которы для любого интерфейса
check_show_status_all(){
	local res count
	# Проверка, что ipset существует
	ipset list -n | grep -qx "${IPSET_TABLE_NAME}"
	res=$?
    addkey_from_result $res "ipset" "Набор создан" "ДА" "ok" "НЕТ" "error"
	# Если набор существует, проверяем, пустой ли он
	if [ $res -eq 0 ]; then
        count=$(ipset list "$IPSET_TABLE_NAME" | awk '/^Members:/ {found=1; next} found && NF {count++} END {print count+0}')
        if [ "$count" -eq 0 ]; then
            res="error"
        elif [ "$count" -ge 1 ] && [ "$count" -le 10 ]; then
            res="warning"
        else
            res="ok"
        fi    
        addkey_json "ipset" "Количество элементов" "$count" "$res"
	fi
    # статус маркировки пакетов
	check_chain_mark
}

check_show_status_dns(){
    local proc_adguard proc_dnsmasq proc_dnscrypt ret adguard_on dnsmasq_on dnscrypt_on listener_name_run listener_name
    proc_adguard=AdGuardHome
    proc_dnsmasq=dnsmasq
    proc_dnscrypt=dnscrypt-proxy
    is_dns_override
    ret=$?
    adguard_on=$(pidof "$proc_adguard")
    dnsmasq_on=$(pidof "$proc_dnsmasq")
    dnscrypt_on=$(pidof "$proc_dnscrypt")
    listener_name_run="---"
    if [ $ret -ne 0 ]; then
        addkey_json "dns" "Режим работы DNS роутера" "Системный DNS-сервис" "error"
    elif [ -n "$adguard_on" ] && [ -z "$dnsmasq_on" ] && [ -z "$dnscrypt_on" ]; then
        addkey_json "dns" "Режим работы DNS роутера" "AdGuard Home" "ok"
        listener_name_run="AdGuardHome"
    elif [ -z "$adguard_on" ] && [ -n "$dnsmasq_on" ] && [ -n "$dnscrypt_on" ]; then
        addkey_json "dns" "Режим работы DNS роутера" "dnsmasq + dnscrypt-proxy" "ok"
        listener_name_run="dnsmasq"
    elif [ -n "$dnsmasq_on" ] && [ -z "$dnscrypt_on" ]; then
        addkey_json "dns" "Режим работы DNS роутера" "dnsmasq (незащищённый)" "warning"
        listener_name_run="dnsmasq"
    elif [ -n "$dnscrypt_on" ] && [ -z "$dnsmasq_on" ]; then
        addkey_json "dns" "Режим работы DNS роутера" "dnsmasq не запущен" "error"
        listener_name_run="dnscrypt-proxy"
    elif [ -n "$adguard_on" ] && { [ -n "$dnsmasq_on" ] || [ -n "$dnscrypt_on" ]; }; then
        addkey_json "dns" "Режим работы DNS роутера" "запущены все DNS-серверы" "error"
    else
        addkey_json "dns" "Режим работы DNS роутера" "нет активных серверов" "error"
    fi

    #получаем имя и результат кто слушает
    listener_name=$(check_dns_listener); ret=$?
    if [ $ret -eq 0 ]; then
        if [ "$listener_name_run" = "$listener_name" ]; then
            addkey_json "dns" "Проверка прослушки DNS-порта" "OK" "ok"
        else
            addkey_json "dns" "Проверка прослушки DNS-порта" "слушает: $listener_name" "warning"
        fi
    elif [ $ret -eq 1 ]; then
        addkey_json "dns" "Проверка прослушки DNS-порта" "порт 53 не слушается" "error"
    else
        addkey_json "dns" "Проверка прослушки DNS-порта" "конфликт: несколько процессов" "error"
    fi
}

# # статусы модулей специфичные для безопасного соединения 
check_show_status_vpn(){
	local res _inface_cli _inface_ent
	_inface_ent=$(get_config_value "INFACE_ENT")
	_inface_cli="$(get_config_value INFACE_CLI)"
#	если выбрано соединение, отличное от manual
	if ! [ "${_inface_cli}" = 'manual' ]; then
		local _inface_cli_desc connected
		_inface_cli_desc="$(get_decription_cli_inface "${_inface_cli}")"
		connected=$(is_interface_online "${_inface_cli}")
		[ "${connected}" = 'on' ]
		addkey_from_result "$?" "route" "Состояние выбранного соединения ${_inface_cli_desc}" "ПОДКЛЮЧЕНО" "ok" "ОТКЛЮЧЕНО" "warning"
	#else
		#echo -e "Интерфейс ${GREEN}'${_inface_ent}'${NOCL} задан вручную. Его состояние ${YELLOW}не отслеживается ${NOCL}автоматически."
		#TODO Подумать над внешними файлами hook в которых пользователь  сможет внести комманды для определения состояния соединения
	fi

	[ -n "$(ip route show table "$ROUTE_TABLE_ID")" ]
	res=$?
    addkey_from_result "$res" "route" "Таблица маршрутизации" "ЗАПОЛНЕНА" "ok" "ОТСУТСТВУЕТ" "error"
	# Если таблица существует, проверяем, тот ли интерфейс там по умолчанию
	if [ $res -eq 0 ]; then
		ip route show table "$ROUTE_TABLE_ID" | grep -q "^default dev ${_inface_ent}"
        addkey_from_result "$?" "route" "Маршрут по умолчанию в таблице" "УСТАНОВЛЕН КОРРЕКТНО" "ok" "НЕТ ИЛИ НЕВЕРНЫЙ" "error"
	fi

	ip rule show | grep -q "fwmark ${FWMARK_NUM}/${FWMARK_NUM}.*lookup ${ROUTE_TABLE_ID}"
    addkey_from_result "$?" "route" "Правило маршрутизации для выбранного соединения" "УСТАНОВЛЕНО" "ok" "ОТСУТСТВУЕТ" "error"

	ip rule show | grep -q "fwmark ${FWMARK_NUM}/${FWMARK_NUM}.*blackhole"
    addkey_from_result "$?" "route" "Защита трафика при сбое маршрута" "ВКЛЮЧЕНА" "ok" "НЕТ ЗАЩИТЫ" "error"
}

show_json_key() {
    local dir="$1"
    local key="$2"
    local value status note=""
    value=$(echo "$JSON_DATA" | jq -r --arg k "$key" --arg d "$dir" '.[$d][] | select(.key==$k) | .value')
    status=$(echo "$JSON_DATA" | jq -r --arg k "$key" --arg d "$dir" '.[$d][] | select(.key==$k) | .status')
    status=error
    case $status in
        ok) color=${GREEN} ;;
        error) 
            color=${RED} 
            note="$3"
            ;;
        warning) color=${YELLOW} ;;
        *) color=${NOCL} ;;
    esac

    value="$color$value$NOCL"
    align_left_right "$key" "$value" "$_LENGTH_"
    [ -n "$note" ] && echo -e "$note"
}

show_status() {
    
    show_json_key system "Версия пакета"
    show_json_key system "Режим работы пакета" " ${YELLOW}Подсказка: ${BLUE}Вам необходимо выбрать рабочее соединение${NOCL}"
    echo
    echo -e "${GREEN}DNS:${NOCL}"
    show_json_key dns "Режим работы DNS роутера" "    ${YELLOW}Подсказка: ${BLUE}Выберите режим работы 'kvl dns mode'${NOCL}"
    show_json_key dns "Проверка прослушки DNS-порта"
    show_json_key dns "Локальное перенаправление DNS"
    echo
    echo -e "${GREEN}Таблица IP-адресов для маршрутизации:${NOCL}"
    show_json_key ipset "Набор создан" "    ${YELLOW}Подсказка: ${BLUE}если вы только что установили КВАС ЛАЙТ, ip-таблица ещё не создана \n \
              перезагрузите роутер или выполните 'kvl start'${NOCL}"
    show_json_key ipset "Количество элементов" "    ${YELLOW}Подсказка: ${BLUE}если пакет «КВАС ЛАЙТ» ещё не настроен, или не было DNS запросов - \n \
              пустой список это нормально${NOCL}"
    echo
    echo -e "${GREEN}Правила маркировки трафика для маршрутизации:${NOCL}"
    show_json_key vpn_mark "Цепочка правил создана?" "    ${YELLOW}Подсказка: ${BLUE}Возможно пакет остановлен, выполните 'kvl start' \n \
 		      трафик из белого списка уходит через вашего провайдера!${NOCL}"
    show_json_key vpn_mark "Установка метки на пакеты"
    show_json_key vpn_mark "Применение правил (PREROUTING/OUTPUT)"
}


cmd_get_status(){
	addkey_json "system" "Версия пакета" "$(version)" "info"
	# выводим статус общих для всех компонентов модуля
    check_show_status_dns
	check_show_status_all
	# проверяем что включено, должно включено только одно
	local work_mode
	work_mode=$(get_config_value METHOD)
	case $work_mode in
        "tproxy") 
			# Direct Proxy
			addkey_json "system" "Режим работы пакета" "ПРОЗРАЧНЫЙ PROXY" "ok"
			;;
        "wg")
		    # Только VPN 
			addkey_json "system" "Режим работы пакета" "Тунель" "ok"
			check_show_status_vpn
			;;
        *)  
			# Ошибка: Выберите режим.
			addkey_json "system" "Режим работы пакета" "НЕ ЗАДАН" "error"
			;;
    esac
	check_chain_dns_redirect

    if [ "$JSON_OUTPUT" = 1 ]; then
        echo "$JSON_DATA"
    else
        if [ -n "$_INTERACTIVE_" ]; then
            show_status
        else
            echo "$JSON_DATA"
        fi
    fi    
}

cmd_report_show_status_dns() {
    check_show_status_dns
    check_chain_dns_redirect
#   echo "$JSON_DATA"
    show_json_key dns "Режим работы DNS роутера"
    show_json_key dns "Проверка прослушки DNS-порта"
    show_json_key dns "Локальное перенаправление DNS"
}