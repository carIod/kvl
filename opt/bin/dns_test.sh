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
test_template="/opt/apps/kvl/etc/conf/dnscrypt-test.toml"
test_cfg="/tmp/dnscrypt-test.toml"
json_url="https://download.dnscrypt.info/dnscrypt-resolvers/json/public-resolvers.json"
cache_json="/opt/tmp/public-resolvers.json"
pid_file=/tmp/run/dnscrypt-test.pid
fifo_file=/tmp/dnscrypt-test.fifo

change_toml_config(){
    local server_names="$1"
    new_line="server_names = [$server_names]"
    tmpfile=$(mktemp)
    awk -v newline="$new_line" '
        BEGIN { inserted = 0 }
        /^[[:space:]]*#[[:space:]]*server_names[[:space:]]*=/ {
            print
            if (!inserted) { print newline; inserted = 1 }
            next
        }
        /^[[:space:]]*server_names[[:space:]]*=/ {
            next
        }
        { print }
        END {
            if (!inserted) print newline
        }
        '/opt/etc/dnscrypt-proxy.toml > "$tmpfile" && mv "$tmpfile" /opt/etc/dnscrypt-proxy.toml
    
    color_echo "${GREEN}Конфигурация /opt/etc/dnscrypt-proxy.toml успешно обновлена!${NOCL}"
}

change_dnscrypt_cfg(){
    local mode="$1"
    local max_count selected_numbers stamp country proto dnssec nolog nofilter delay info formatted numbers anycast alias
    max_count=$(echo "$json_array" | jq length)
    while :; do   
    formatted=""
    read_value "${WHITE}Введите номера серверов через запятую, диапазон (1-$max_count)" selected_numbers
    [[ "$selected_numbers" =~ ^[Qq]$ ]] && return 1
    numbers=$(echo "$selected_numbers" | sed 's/ *, */,/g' | tr ',' '\n')
    print_line
    while read -r num; do
        [ -z "$num" ] && continue

        case $num in
            *[!0-9]*)
                color_echo "${RED}Ошибка: '$num' не число, пропускаем${NOCL}"
                continue
                ;;
            *)
                if [ "$num" -lt 1 ] || [ "$num" -gt "$max_count" ]; then
                    color_echo "${RED}Ошибка: '$num' вне диапазона, пропускаем${NOCL}"
                    continue
                fi
                alias=$(echo "$json_array" | jq -r ".[$((num-1))].server")
                if [ "$mode" = "dnsmasq" ]; then
                    if [ -n "$formatted" ]; then
                        formatted="$formatted, '$alias'"
                    else
                        formatted="'$alias'"
                    fi
                else
                    info=$(jq -r --arg name "$alias" '.[] | select(.name==$name)' "$cache_json")
                    if [ -n "$info" ]; then
                        delay=$(echo "$json_array" | jq -r ".[$((num-1))].delay")
                        eval "$(echo "$info" | jq -r '
                        "country=" + (.country // "" | @sh) + "\n" +
                        "dnssec="  + ((.dnssec   // false) | tostring | @sh) + "\n" +
                        "nolog="   + ((.nolog    // false) | tostring | @sh) + "\n" +
                        "nofilter="+ ((.nofilter // false) | tostring | @sh) + "\n" +
                        "stamp="   + (.stamp // "" | @sh) + "\n" +
                        "proto="   + (.proto // "" | @sh) + "\n" +
                        "desc="    + (.description // "" | @sh)
                        ')"
                        # переводы true/false
                        [ "$dnssec" = "true" ]  && dnssec="dnssec"      || dnssec="nosec"
                        [ "$nolog"  = "true" ]  && nolog="nolog"       || nolog="logs"
                        [ "$nofilter" = "true" ]&& nofilter="nofilter" || nofilter="filter"
                        anycast=$(echo "$desc" | grep -iq "anycast" && echo "(anycast)")
                        formatted="${formatted}# Сервер: $alias $delay Страна: $country$anycast ($dnssec, $nolog, $nofilter) ($proto)"$'\n'
                        formatted="${formatted}$stamp"$'\n'
                    fi    
                fi    
                ;;
        esac
    done <<EOF
$numbers
EOF
    local selected
    if [ "$mode" = "dnsmasq" ]; then
        color_echo "Получилась такая переменная:"
        color_echo "${BLUE}server_names=[$formatted]${NOCL}"
        [ -z "$formatted" ] && color_echo "${YELLOW}⚠️ В таком случае dnscrypt-proxy будет использоваться все сервера${NOCL}"
        color_echo    
        read_value "${WHITE}Подтвердите изменения (Y), повторить ввод (R) или" selected
    else
        color_echo "Получился такой массив:"     
        printf "%s" "$formatted"
        color_echo    
        read_value "${WHITE}Повторить ввод (R) или" selected
    fi
    case "$selected" in
        [Yy]*) break ;;    # подтверждаем и выходим из цикла
        [Rr]*) continue ;; # повторяем заново, очищаем formatted и т.д.
        [Qq]*) return 1 ;; # выход из функции
    esac    
    done
    [ "$mode" = "dnsmasq" ] && change_toml_config "$formatted"
}

# ==================================================== BEGIN =========================================================================================
get_dns_mode DNS_MODE
#DNS_MODE=dnsmasq
color_echo ""
color_echo "Этот команда запускает временный экземпляр ${BLUE}dnscrypt-proxy2${NOCL} и проверяет доступность резолверов."
color_echo "Он измеряет время отклика серверов, сортирует их по задержке и выводит вам список топ-серверов."
color_echo ""
color_echo "Вы можете выбрать, сколько записей из этого ТОП-листа показать для дальнейшего выбора."
color_echo ""
read_value "${WHITE}Сколько ТОП серверов вывести на экран" TOP_N digit
[[ "$TOP_N" =~ ^[Qq]$ ]] && exit 0
[ "$TOP_N" -eq 0 ] && exit 0
color_echo ""
color_echo "${GREEN}DNSCrypt${NOCL} — шифрует DNS-запросы между вашим устройством и резолвером,"
color_echo "защищая их от перехвата и подделки (атаки типа 'человек посередине')."
color_echo "Гарантирует конфиденциальность и целостность запросов. Работает по UDP и TCP"
color_echo "Подробнее: ${BLUE}https://dnscrypt.info/faq${NOCL}"
color_echo ""
read_value "${WHITE}Включать DNS-сервера работающие по протоколу DNSCrypt (y/n)" ASK_CRYPT
[[ "$ASK_CRYPT" =~ ^[Qq]$ ]] && exit
color_echo ""
color_echo "${GREEN}DoH (DNS-over-HTTPS)${NOCL} — это протокол, который передаёт DNS-запросы поверх HTTPS."
color_echo "Он скрывает содержимое и сам факт DNS-запроса от посторонних, так как весь трафик идёт по HTTPS."
color_echo "Это позволяет обойти цензуру и защитить приватность. Работает только по TCP"
color_echo ""
read_value "${WHITE}Включать DNS-сервера работающие по протоколу DoH (y/n)" ASK_DOH
[[ "$ASK_DOH" =~ ^[Qq]$ ]] && exit
color_echo ""
color_echo "${GREEN}DNSSEC${NOCL} — проверяет подлинность и целостность DNS-ответов через криптографические подписи,"
color_echo "защищая от подмены данных (например, перенаправления на фальшивый сайт)."
color_echo ""
read_value "${WHITE}Выбрать DNS-сервера, поддерживающие DNSSEC (y/n)" ASK_DNSSEC
[[ "$ASK_DNSSEC" =~ ^[Qq]$ ]] && exit
color_echo ""

color_echo "${GREEN}NoLog${NOCL} — резолвер не ведёт журналов запросов, повышая приватность."
color_echo "${YELLOW}Примечание:${NOCL} декларация резолвера, не абсолютная гарантия. Может сохранять минимальные служебные логи."
color_echo ""
read_value "${WHITE}Выбрать резолверы, которые декларируют что НЕ ведут логи (y/n)" ASK_LOG
[[ "$ASK_LOG" =~ ^[Qq]$ ]] && exit
color_echo ""

color_echo "${GREEN}NoFilter${NOCL} — резолвер не применяет свои фильтры (например, блокировку рекламы или контента для взрослых)."
color_echo "${YELLOW}Примечание:${NOCL} декларация резолвера, не абсолютная гарантия. Он может применять внутренние фильтры, даже если заявляет обратное."
color_echo ""
read_value "${WHITE}Выбрать резолверы без фильтрации запросов (y/n)" ASK_FILTER
[[ "$ASK_FILTER" =~ ^[Qq]$ ]] && exit
color_echo ""

awk -v dnssec="$ASK_DNSSEC" -v nolog="$ASK_LOG" -v nofilter="$ASK_FILTER" -v doh="$ASK_DOH" -v crypt="$ASK_CRYPT" '
{
    if ($1 == "require_dnssec") {
        $3 = (dnssec ~ /^[Yy]$/ ? "true" : "false")
    }
    else if ($1 == "require_nolog") {
        $3 = (nolog ~ /^[Yy]$/ ? "true" : "false")
    }
    else if ($1 == "require_nofilter") {
        $3 = (nofilter ~ /^[Yy]$/ ? "true" : "false")
    }
    else if ($1 == "doh_servers") {
        $3 = (doh ~ /^[Yy]$/ ? "true" : "false")
    }
    else if ($1 == "dnscrypt_servers") {
        $3 = (crypt ~ /^[Yy]$/ ? "true" : "false")
    }
    print
}
' "$test_template" > "$test_cfg"

color_echo "Временный конфиг сформирован: $test_cfg"

# на всякий случай удаляем если есть файл
[ -f "$pid_file" ] && rm -f "$pid_file"
# создаем fifo буфер
[ -p "$fifo_file" ] || mkfifo "$fifo_file"
[ -f "/tmp/dnsctypt-test.log" ] && rm -f "/tmp/dnsctypt-test.log"

json_array=""
flag=0
line_count=0

color_echo "Запуск тестового экземпляра dnscrypt-proxy в фоне"
dnscrypt-proxy -pidfile "$pid_file" -config "$test_cfg" > "$fifo_file" 2>&1 &
color_echo "Отслеживаем вывод сообщений от dnscrypt-proxy и ждем завершения сортировки."
color_echo "Количество выводимых серверов: $TOP_N"
color_echo "В зависимости от включенных фильтров (DNSSEC, NoLog, NoFilter) процесс может занять заметное время."
color_echo "Если в течение 15 секунд не поступает новых строк от dnscrypt-proxy, проверка завершается автоматически."
# считываем строки из fifo буфера и ограничиваем ожидание строк до 15 секунд
while read -t 15 -r line; do
    [ -n "$_INTERACTIVE_" ] && echo -n "."
#    echo "$line" >> /tmp/dnsctypt-test.log   # for debug
    case "$line" in
        *"Sorted latencies:"*) flag=1 ;;
        *"dnscrypt-proxy is ready"*) break ;;
        *"No servers configured"*)
            break
            ;;
        *)
            if [ "$flag" -eq 1 ]; then
                line_count=$((line_count + 1))
                unset delay server
                found_ms=0
                for field in $line; do
                    case "$field" in
                        *ms)
                            delay="$field"
                            found_ms=1
                        ;;
                    *)
                        if [ "$found_ms" -eq 1 ]; then
                            [ -n "$field" ] && server="$field"
                            break;
                        fi
                        ;;
                    esac
                done
                if [ -n "$delay" ] && [ -n "$server" ]; then
                    if [ -n "$json_array" ]; then
                        json_array="$json_array,"
                    fi
                    json_array="$json_array{\"delay\":\"$delay\",\"server\":\"$server\"}"
                fi
                # ограничиваем топ N
                [ "$line_count" -ge "$TOP_N" ] && break
            fi
        ;;
    esac
done < "$fifo_file"
if [ -z "$json_array" ]; then 
    color_echo " по выбранным фильтрам не найдено ни одного сервера."
else
    color_echo " записи выбраны!"
fi    
json_array="[$json_array]"
# Ожидаем когда появится файл pid 
#while [ ! -s "$pid_file" ]; do sleep 1; done
DNS_PID=$(cat $pid_file)
if kill "$DNS_PID" 2>/dev/null; then
    i=0
    while [ "$i" -lt 5 ]; do
        if ! kill -0 "$DNS_PID" 2>/dev/null; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$DNS_PID" 2>/dev/null; then
        echo -e "⚠️ dnscrypt-proxy  не завершился, принудительное убийство"
        kill -9 "$DNS_PID" 2>/dev/null
    fi
fi
echo -e "dnscrypt-proxy ${GREEN}остановлен.${NOCL}"
# удаляем ненужные файлы
rm -f "$fifo_file" "$pid_file" "$test_cfg"

# обновляем раз в сутки
# если файла нет — качаем
if [ ! -f "$cache_json" ]; then
    echo "Кэша нет, скачиваю..."
    curl -s -o "$cache_json" "$json_url"
else
    # проверяем возраст файла через find
    if [ -n "$(find "$cache_json" -mmin +1440 2>/dev/null)" ]; then
        echo "Файл кэша старше суток, обновляю..."
        curl -s -o "$cache_json" "$json_url"
    else
        echo "Кэш менее суток, не обновляю"
    fi
fi

color_echo "⚠️ Обратите внимание если в описании сервера есть «anycast»"
color_echo "${YELLOW}Anycast${NOCL} — это способ маршрутизации, когда один IP-адрес назначается сразу нескольким серверам, расположенным в разных местах сети."
color_echo "          Главная идея: когда клиент делает запрос на этот IP, сеть сама отправляет запрос к ближайшему (по маршруту) серверу."
color_echo "          То есть «anycast» = один адрес → несколько физических серверов → ближайший отвечает. (нет географического закрепления сервера)"
color_echo ""

i=0
echo "$json_array" | jq -c '.[]' | while read -r item; do
    server=$(echo "$item" | jq -r '.server')
    delay=$(echo "$item" | jq -r '.delay')
    i=$(( i + 1 ))
    [ ${#i} -eq 1 ] && ii=" $i" || ii="$i"
    info=$(jq -r --arg name "$server" '.[] | select(.name==$name)' "$cache_json")
    if [ -n "$info" ]; then
        eval "$(echo "$info" | jq -r '
            "country=" + (.country // "" | @sh) + "\n" +
            "dnssec="  + ((.dnssec   // false) | tostring | @sh) + "\n" +
            "nolog="   + ((.nolog    // false) | tostring | @sh) + "\n" +
            "nofilter="+ ((.nofilter // false) | tostring | @sh) + "\n" +
            "stamp="   + (.stamp // "" | @sh) + "\n" +
            "proto="   + (.proto // "" | @sh) + "\n" +
            "desc="    + ((.description // "" ) | @sh) + "\n"
            ')"
        # убираем \r и \n
        desc=$(echo "$desc" | tr '\r\n' ' ')
        # сводим табы к пробелам
        desc=$(echo "$desc" | tr '\t' ' ')
        desc_colored=$(echo "$desc" | awk -v yellow="$YELLOW" -v nocl="$NOCL" '{gsub(/anycast/, yellow "anycast" nocl, $0); print}')
        # переводы true/false
        [ "$dnssec" = "true" ]  && dnssec="${GREEN}dnssec${NOCL}"     || dnssec="${RED}nosec${NOCL}"
        [ "$nolog"  = "true" ]  && nolog="${GREEN}nolog${NOCL}"       || nolog="${RED}logs${NOCL}"
        [ "$nofilter" = "true" ]&& nofilter="${GREEN}nofilter${NOCL}" || nofilter="${RED}filter${NOCL}"
        print_line
        align_left_right "${GREEN}$ii) ${BLUE}Сервер: ${WHITE}$server${NOCL}" "" 40 0
        align_left_right "  " "${GREEN}$delay${NOCL}" 7 0
        align_left_right "     ${BLUE}Страна: ${WHITE}$country${NOCL}" "" 25 0
        align_left_right "        " "($dnssec, $nolog, $nofilter)" 25 0
        align_left_right "  " "${GREEN}($proto)${NOCL}" 7 
        echo -e "Описание:     $desc_colored"
        echo "Stamp:        $stamp"
    else
        print_line
        align_left_right "${GREEN}$ii) ${BLUE}Сервер:${NOCL}" "$server" 25 0
        align_left_right "  " "$delay" 7
        echo "Описание:     нет информации"
    fi
done
color_echo ""

case "$DNS_MODE" in
  adguard)
    color_echo "Вы используете режим ${GREEN}AdGuard Home.${NOCL}"
    color_echo ""
    color_echo "${YELLOW}Что делать дальше:${NOCL}"
    color_echo "1. Откройте веб-интерфейс AdGuard Home: обычно http://127.0.0.1:8080 или по адресу вашей установки."
    color_echo "2. Перейдите в раздел ${GREEN}Настройки → DNS${NOCL}."
    color_echo "3. Скопируйте понравившийся сервер из таблицы в формате ${CYAN}stamp://${NOCL} и вставьте его в список серверов."
    color_echo "   Это безопасный формат ссылки (DNS Stamp), который гарантирует правильное подключение."
    color_echo "4. При желании вы можете ограничить зоны, для которых сервер будет использоваться."
    color_echo "   Например: ${GREEN}[/ru/]stamp://...${NOCL} — запросы для доменов .ru будут идти только через этот резолвер."
    color_echo "   Для кириллических доменов нужно указывать в ${YELLOW}Punycode${NOCL}, например:"
    color_echo "     ${GREEN}[/xn--p1ai/]stamp://...${NOCL} (это зона .рф)."
    color_echo ""
    color_echo "${CYAN}Таким образом вы можете тонко настроить приватность и скорость работы DNS.${NOCL}"
    color_echo
    color_echo "   Выберите нужные резолверы из таблицы выше и введите их порядковые номера через запятую."
    color_echo "   это выведит список резолверов готовых для вставки на странице AdGuard Home"
    change_dnscrypt_cfg "$DNS_MODE"
    ;;
    
  dnsmasq)
    color_echo "Вы используете режим ${GREEN}Dnsmasq + DNSCrypt-Proxy2.${NOCL}"
    color_echo ""
    color_echo "${YELLOW}Что делать дальше:${NOCL}"
    color_echo "1. В этом режиме dnsmasq будет перенаправлять все DNS-запросы на DNSCrypt-Proxy2,"
    color_echo "   а уже DNSCrypt выберет конкретные безопасные резолверы."
    color_echo ""
    color_echo "2. Чтобы задать список серверов, используйте параметр ${GREEN}server_names${NOCL}."
    color_echo "   Сервера указываются через запятую, например:"
    color_echo "     ${CYAN}['scaleway-fr', 'google', 'yandex', 'cloudflare']${NOCL}"
    color_echo
    color_echo "3. Выберите нужные резолверы из таблицы выше и введите их порядковые номера через запятую."
    color_echo "   Если хотите завершить настройку без изменений — введите ${RED}Q${NOCL}."
    color_echo ""
    change_dnscrypt_cfg "$DNS_MODE"
    ;;
esac