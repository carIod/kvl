#!/bin/sh
# парсим модуль всего один раз
[ -n "$_UTL_INCLUDED" ] && return
_UTL_INCLUDED=1
# если скрипт запущен из консоли то выставляем флаг _INTERACTIVE_
[ -t 0 ] && _INTERACTIVE_=1	

INFACE_REQUEST="127.0.0.1:79/rci/show/interface"
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
# shellcheck source=opt\bin\libs\env.sh
. /opt/apps/kvl/bin/libs/env.sh

#	Получаем IP интерфейса по заданному entware интерфейсу
get_ip_by_inface() {
	/opt/sbin/ip -4 -o addr show dev "${1}" scope global | awk '{split($4, a, "/"); print a[1]}'
}

# Получаем первое значение переменной из конфигурационного файла
get_config_value() {
	grep -m1 "^${1}=" "${KVL_CONF_FILE}" | cut -d'=' -f2-
}

# Сохраняем значение переменной в конфигурационый файл если она изменилась
set_config_value() {
	local line current_val
	line=$(grep -m1 "^${1}=" "${KVL_CONF_FILE}" || true)
	if [ -z "$line" ]; then
        echo "${1}=${2}" >> "${KVL_CONF_FILE}"
    else	
		current_val=${line#*=}
		if [ "$current_val" != "$2" ]; then
            sed -i "s|^${1}=.*|${1}=${2}|" "${KVL_CONF_FILE}"
        fi
	fi	
}

# записываем параметры в файл  /tmp/kvl_config.sh он находится в памяти поэтому флеш память не изнашивается, данный файл потом будет загружать переменные в окружение
create_fast_config(){
	local params="PROVIDER METHOD INFACE_CLI INFACE_ENT TCP_WAY TCP_PORT ENABLE_UDP UDP_PORT ENABLE_MTU ENABLE_MASQ DNS_REDIRECT"
	: > /tmp/kvl_config.sh  # очищаем файл перед записью
    for p in $params; do
        val=$(get_config_value "$p")
        echo "$p=$val" >> /tmp/kvl_config.sh
    done
	echo "LOCAL_INFACE=br0" >> /tmp/kvl_config.sh
	echo "ROUTER_IP=$(get_ip_by_inface br0)" >> /tmp/kvl_config.sh
}

# Подгружаем некоторые параметры работы в окружение для ускорения выполнения скрипта
[ -f /tmp/kvl_config.sh ] || create_fast_config &>/dev/null
# shellcheck source=/dev/null
. /tmp/kvl_config.sh

# при запуске считываем какой уровень логов и проверяем на корректность
_LOG_LEVEL_=$(get_config_value "LOG_LEVEL")
[ "$_LOG_LEVEL_" -ge 1 ] 2>/dev/null && [ "$_LOG_LEVEL_" -le 3 ] || _LOG_LEVEL_=3

# Вычисляем текущую ширину и высоту экрана
if stty_size=$(stty size 2>/dev/null); then
	_STTY_ROWS_=${stty_size%% *}
	_STTY_COLS_=${stty_size##* }
else
    _STTY_ROWS_=24
    _STTY_COLS_=80
fi
# вычисляем максимальную длину сообщений от пакета
[ -n "${_STTY_COLS_}" ] && [ "${_STTY_COLS_}" -gt 80 ] && _LENGTH_=$((_STTY_COLS_*2/3)) || _LENGTH_=68

#функция перчатает заданное число раз один и тот же символ
print_line() {
	local len
	len="${1:-${_LENGTH_}}"
	: "$len"
	[ -n "$_INTERACTIVE_" ] && printf "%${len}s\n" | tr " " "-"
}
# Выводит строку с потдержкой цвета на экран если интерактивный режим
color_echo() {
	[ -n "$_INTERACTIVE_" ] && printf "%b\n" "$1"
}

str_clear() {
	echo "${1}" | sed -r "s/[\]033\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g"
}

str_len() {
	local charlen
	charlen=$(str_clear "${1}")
	echo ${#charlen}
}

# формирует строку заданного размера, состоящую из 2 строк левой и правой 
align_left_right() {
	local left="$1"      # то, что слева
	local right="$2"     # статус справа типа [ОТКЛЮЧЕН]
	local full_len="${3:-35}"  # общая длина строки
	local newline="${4:-1}"  # по умолчанию печатаем \n
	# Вычисляем, сколько пробелов нужно вставить между ними
	local pad_len=$(( full_len - $(str_len "${left}${right}") ))
	[ "$pad_len" -lt 0 ] && pad_len=0
	if [ "$newline" = "1" ]; then
        printf "%b%*s%b\n" "$left" "$pad_len" "" "$right"
    else
        printf "%b%*s%b" "$left" "$pad_len" "" "$right"
    fi
}

#--------------------------------------------------------------------------------------------------------------
# Выводит строку либо в консоль если скрипт запущен в консоле либо ситемный журнал
# Второй параметр уровень важности сообщения: 1=INFO[по умолчанию], 2=WARNING, 3= ERROR
log() {
	local msg lvl_err prio
	msg="$1"
	lvl_err=${2:-1}
	if [ -n "$_INTERACTIVE_" ]; then
		case "$lvl_err" in
			3) color="$RED" ;;  # ERROR — красный
			2) color="$YELLOW" ;;  # WARNING — жёлтый
			*) color="$NOCL" ;;
		esac
		printf "%b%s%b\n" "$color" "$msg" "$NOCL"
	# если уровень сообшения ниже чем в конфигурации то ничего не делаем	
	elif [ "$_LOG_LEVEL_" -ge "$lvl_err" ]; then
		# err - 3  warn - 4  info - 5
		prio=$((6 - lvl_err))  # переводим уровень в logger приоритет
		logger -p "user.$prio" -t "${APP_NAME_DESC}" "$msg"
	fi
}

show_result() {
	local res_code="$1"
	local msg="$2"
	local msg_ok="${3:-УСПЕШНО}"
	local msg_err="${4:-ОШИБКА}"
	local lvl_err="${5:-1}"  # по умолчанию INFO=1
	local spaces res_txt color
	
	if [ "$res_code" -eq 0 ]; then
		lvl_err=1 # если нет ошибки то понижаем уровень до информационного
		res_txt="${msg_ok}"
		color="${GREEN}"
	else
		res_txt="${msg_err}"
		color="${RED}"
	fi

	if [ -n "$_INTERACTIVE_" ]; then
		spaces=$(( _LENGTH_ - $(str_len "${msg}${res_txt}") ))
		printf "%b%${spaces}s%b%b%b\n" "$msg" "" "$color" "$res_txt" "$NOCL"
	else
		# если это НЕ интерактивный процесс и уровень логирования не выше чем данное событие то пишем так же в журнал
		if [ "$_LOG_LEVEL_" -ge "$lvl_err" ]; then
			# err - 3  warn - 4  info - 5
			local prio=$((6 - lvl_err))  # переводим уровень в logger приоритет
			logger -p "user.$prio" -t "${APP_NAME_DESC}" "${msg}: ${res_txt}"
		fi	
	fi	
	return "$res_code"
} 
# функция запрашивает у пользователя номер в пределах от 1 до $1, выводит сообщение $2 выбранный номер возвращает через $3
ask_user_to_choose() {
	local total="$1"
	local msg="$2"
	local selection

	while true; do
		echo -en "${BLUE}${msg} 1 - ${total} | Q-выход:${NOCL} "
		read -r selection
		if [[ "$selection" =~ ^[1-9][0-9]*$ ]]; then
			if [[ "$selection" -ge 1 && "$selection" -le "$total" ]]; then
				eval "${3}=\"\$selection\""
				return 0
			else
				echo "Число должно быть в пределах от 1 до ${total}"
			fi	
		elif [[ "$selection" =~ ^[Qq]$ ]]; then
			echo -e "${RED}Процедура настройки прервана пользователем!${NOCL}"
			exit 1
		else
			echo "Введите цифру 1-${total} или Q - выход."
		fi
	done	
}
# ------------------------------------------------------------------------------------------
#	 Читаем значение переменной из ввода данных в цикле
#	 $1 - заголовок для запроса может содержать коды цветов
#	 $2 - переменная в которой возвращается результат
#	 $3 - тип вводимого значения
#		 digit - цифра
#		 password - пароль без показа вводимых символов
# ------------------------------------------------------------------------------------------
read_value() {
	header="$(echo "${1}" | tr -d '?')"
	type="${3}"

	while true; do
		echo -en "${header}${NOCL} [Q-выход]  "
		if [ "${type}" = 'password' ]; then read -rs value; else read -r value; fi
		if [ -z "${value}" ]; then
				echo
				print_line
				echo -e "${RED}Данные не должны быть пустыми!"
				echo -e "${GREEN}Попробуйте ввести значение снова...${NOCL}"
				print_line
		elif echo "${value}" | grep -qiE '^Q$' ; then
				eval "${2}=q"
				break
		elif [ "${type}" = 'digit' ] && ! echo "${value}" | grep -qE '^[[:digit:]]{1,6}$'; then
				echo
				print_line
				echo -e "${RED}Введенные данные должны быть цифрами!"
				echo -e "${GREEN}Попробуйте ввести значение снова...${NOCL}"
				print_line
		elif [ "${type}" = 'password' ] && ! echo "${value}" | grep -qE '^[a-zA-Z0-9]{8,1024}$' ; then
				echo
				print_line
				echo -e "${GREEN}Пароль должен содержать минимум 8 знаков и"
				echo -e "${GREEN}ТОЛЬКО буквы и ЦИФРЫ, ${RED}без каких-либо спец символов!${NOCL}"
				echo -e "${RED}Попробуйте ввести его снова...${NOCL}"
				print_line
		else
				eval "${2}=\"\$value\""
				break
		fi
	done
}

version(){
	local _app_version
	_app_version=$(echo "${APP_VERSION}" | tr '-' ' ')
	echo "${_app_version}"
}

is_interface_online() {
	local cli_inface="$1"
	local connected="off"
	local inface_desc
	inface_desc=$(curl -s "${INFACE_REQUEST}?name=${cli_inface}" | jq -r 'select(.state=="up" and .link=="up" and .connected=="yes")')
	[ -n "$inface_desc" ] && connected="on"
	echo "$connected"
}
#Проверяем включен ли dns-override (если включен значит DNS самого роутера отключены и должен работать Ваш сервер)
is_dns_override() {
    curl -s '127.0.0.1:79/rci/opkg/dns-override' | grep -qF 'true'
}
# получает описание интерфейса, по его имени 
get_decription_cli_inface () {
	curl -s "${INFACE_REQUEST}?name=${1}" | jq -r '.description'
}

# rec_in_file() {
#     local file="$1"
#     [ -f "$file" ] || { echo 0; return; }
#     wc -l < "$file"
# }

report_json_or_console() {
	local status="$1"
	local json_data="$2"
	shift 2
	if [ "$JSON_OUTPUT" = 1 ]; then
		printf '{"status":"%s", "data":%s}\n' "$status" "$json_data"
		return 1
	elif [ -n "$_INTERACTIVE_" ]; then
		local line
		for line in "$@"; do
			printf "%b\n" "$line"
		done
		return 0
	fi
}


# Получаем режим работы DNS результат возвращаем в переменную $1
get_dns_mode(){
     local proc_adguard proc_dnsmasq proc_dnscrypt adguard_on dnsmasq_on dnscrypt_on listener_name_run 
     proc_adguard=AdGuardHome
     proc_dnsmasq=dnsmasq
     proc_dnscrypt=dnscrypt-proxy
     adguard_on=$(pidof "$proc_adguard")
     dnsmasq_on=$(pidof "$proc_dnsmasq")
     dnscrypt_on=$(pidof "$proc_dnscrypt")
    if [ -n "$adguard_on" ] && [ -z "$dnsmasq_on" ] && [ -z "$dnscrypt_on" ]; then
        listener_name_run="adguard"
    elif [ -z "$adguard_on" ] && [ -n "$dnsmasq_on" ] && [ -n "$dnscrypt_on" ]; then
        listener_name_run="dnsmasq"
    else
		# shellcheck disable=SC2034
		listener_name_run="error"
    fi
	eval "${1}=\"\$listener_name_run\""
}

manage_demon() {
    local demon="$1"
    local action="$2"   # start|stop|restart
    local enabled="${3:-""}"  # yes|no|"" ("" — не менять ENABLED)
    [ -f "$demon" ] || return 1
    # Сперва меняем ENABLED только если передан параметр
    if [ -n "$enabled" ]; then
        if ! grep -q "^ENABLED=$enabled" "$demon"; then
            sed -i "s/^ENABLED=.*/ENABLED=$enabled/" "$demon"
        fi
    fi
	# Если в запускающем файле демона установлено ENABLED=no то запустить демон не удастся, можно только остановить
    "$demon" "$action"  2>&1 # >/dev/null
}
