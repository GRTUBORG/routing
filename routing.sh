#!/bin/bash

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'
PROMO_MARKER_FILE='/var/lib/routing/.promo_shown'
NAMES_FILE='/var/lib/routing/names.db'

# Корректная обработка кириллицы и Backspace в интерактивном терминале.
if LC_ALL=C.UTF-8 locale charmap >/dev/null 2>&1; then
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
fi
stty iutf8 2>/dev/null || true

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

type_text() {
    local text="$1"
    local delay=0.03
    for (( i=0; i<${#text}; i++ )); do
        echo -n "${text:$i:1}"
        sleep $delay
    done
    echo ""
}

is_valid_utf8() {
    local text="$1"
    if command -v iconv >/dev/null 2>&1; then
        printf '%s' "$text" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
    else
        return 0
    fi
}

is_valid_ipv4() {
    local ip="$1"
    local octets
    local octet

    IFS='.' read -r -a octets <<< "$ip"
    [ ${#octets[@]} -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Запустите скрипт с правами root!${NC}"
        exit 1
    fi
}

# --- ПОДГОТОВКА СИСТЕМЫ ---
prepare_system() {
    mkdir -p "$(dirname "$NAMES_FILE")"
    touch "$NAMES_FILE"
    chmod 600 "$NAMES_FILE"

    # Включение IP Forwarding
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    else
        sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    fi

    # Активация Google BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null

    # Установка зависимостей
    export DEBIAN_FRONTEND=noninteractive
    local packages_to_install=()
    local package
    for package in iptables-persistent netfilter-persistent qrencode conntrack; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            packages_to_install+=("$package")
        fi
    done
    if [ ${#packages_to_install[@]} -gt 0 ]; then
        apt-get update -y > /dev/null
        apt-get install -y "${packages_to_install[@]}" > /dev/null
    fi

    migrate_legacy_names
}

# --- ПРОМО БЛОК ---
show_promo() {
    local PROMO_LINK="https://vk.cc/cUnikK"

    clear
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                ЛУЧШИЙ РУ-ХОСТИНГ ПОД ВАШИ НУЖДЫ              ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -ne "${CYAN}"
    type_text "  >>> $PROMO_LINK"
    type_text "  >>> $PROMO_LINK"
    type_text "  >>> $PROMO_LINK"
    echo -ne "${NC}"

    echo -e "\n${YELLOW}Генерация QR-кода... (3 сек.)${NC}"
    for i in {3..1}; do
        echo -ne "$i..."
        sleep 1
    done
    echo ""

    echo -e "\n${WHITE}" 
    if command -v qrencode &> /dev/null; then
        qrencode -t ANSIUTF8 "$PROMO_LINK"
    else
        echo "QR-код не загрузился, используйте ссылку выше."
    fi
    echo -e "${NC}"
    
    echo -e "${GREEN}Отсканируйте QR-код выше камерой телефона!${NC}"
    echo ""
    read -p "Нажмите Enter для настройки роутинга пакетов..."
}

show_promo_once() {
    if [[ -f "$PROMO_MARKER_FILE" ]]; then
        return
    fi

    mkdir -p "$(dirname "$PROMO_MARKER_FILE")"

    if show_promo; then
        touch "$PROMO_MARKER_FILE"
    fi
}

# --- ИНСТРУКЦИЯ (ТЕКСТ ВНУТРИ КОДА) ---
show_instructions() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║             📚 ИНСТРУКЦИЯ: КАК НАСТРОИТЬ КАСКАД              ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}ШАГ 1: Подготовка${NC}"
    echo -e "У вас должны быть данные от зарубежного VPN (WireGuard/VLESS):"
    echo -e " - ${YELLOW}IP адрес${NC} (зарубежный)"
    echo -e " - ${YELLOW}Порт${NC} (на котором работает VPN)"
    echo ""
    echo -e "${CYAN}ШАГ 2: Настройка данного сервера${NC}"
    echo -e "1. В меню выберите пункт ${GREEN}1${NC} (для UDP-трафика/VPN) или ${GREEN}2${NC} (для TCP-трафика/Proxy)."
    echo -e "2. Введите ${YELLOW}наименование${NC}, ${YELLOW}IP${NC}, ${YELLOW}входящий порт${NC} этого сервера и ${YELLOW}порт назначения${NC} зарубежного сервера."
    echo -e "3. Скрипт создаст 'мост' через этот VPS."
    echo ""
    echo -e "${CYAN}ШАГ 3: Настройка клиентского приложения (Важно!)${NC}"
    echo -e "1. Откройте приложение (AmneziaWG / WireGuard / v2rayNG)."
    echo -e "2. В настройках соединения найдите поле ${YELLOW}Endpoint / Адрес сервера${NC}."
    echo -e "3. Замените зарубежный IP на ${GREEN}IP ЭТОГО СЕРВЕРА${NC}."
    echo -e "4. В качестве порта укажите входящий порт, заданный в скрипте."
    echo ""
    echo -e "${GREEN}Готово! Теперь трафик идет по следующей схеме: клиент -> этот сервер -> зарубежный сервер.${NC}"
    echo ""
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# Удаляет прежний DNAT с тем же протоколом и входящим портом.
# Это исключает ситуацию, когда старое правило стоит выше нового и забирает весь трафик.
remove_conflicting_rules() {
    local proto="$1"
    local in_port="$2"
    local line
    local rule_index
    local match_index
    local old_dest
    local old_ip
    local old_port

    while true; do
        rule_index=0
        match_index=""
        old_dest=""

        while read -r line; do
            [[ "$line" == "-A PREROUTING "* ]] || continue
            ((rule_index++))
            [[ "$line" == *"-j DNAT"* ]] || continue

            if [[ "$(extract_rule_proto "$line")" == "$proto" && "$(extract_rule_port "$line")" == "$in_port" ]]; then
                match_index="$rule_index"
                old_dest=$(extract_rule_destination "$line")
                break
            fi
        done < <(iptables -t nat -S PREROUTING)

        [[ -n "$match_index" ]] || break
        iptables -t nat -D PREROUTING "$match_index" || return 1

        if [[ -n "$old_dest" ]]; then
            old_ip="${old_dest%:*}"
            old_port="${old_dest##*:}"
            iptables -D FORWARD -p "$proto" -d "$old_ip" --dport "$old_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            iptables -D FORWARD -p "$proto" -s "$old_ip" --sport "$old_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            delete_rule_name "$proto" "$in_port" "$old_dest" 2>/dev/null || true
        fi
    done

    while iptables -D INPUT -p "$proto" --dport "$in_port" -j ACCEPT 2>/dev/null; do :; done
}

# --- ЯДРО НАСТРОЙКИ ---
configure_rule() {
    local PROTO=$1
    local NAME=$2

    echo -e "\n${CYAN}--- Настройка $NAME ($PROTO) ---${NC}"

    while true; do
        echo -e "Введите наименование сервера (например, NL-1 или Германия):"
        read -r -e -p "> " SERVER_NAME
        if [[ -n "$SERVER_NAME" && ${#SERVER_NAME} -le 100 && "$SERVER_NAME" != *'|'* && "$SERVER_NAME" != *'"'* ]] && is_valid_utf8 "$SERVER_NAME"; then break; fi
        echo -e "${RED}Ошибка: используйте корректный UTF-8 текст длиной от 1 до 100 символов без | и \".${NC}"
    done

    while true; do
        echo -e "Введите IP адрес конечного сервера:"
        read -p "> " TARGET_IP
        if [[ -n "$TARGET_IP" ]]; then break; fi
    done

    while true; do
        echo -e "Введите входящий порт (порт этого сервера):"
        read -p "> " IN_PORT
        if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && [ "$IN_PORT" -ge 1 ] && [ "$IN_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    while true; do
        echo -e "Введите порт назначения (порт конечного сервера):"
        read -p "> " OUT_PORT
        if [[ "$OUT_PORT" =~ ^[0-9]+$ ]] && [ "$OUT_PORT" -ge 1 ] && [ "$OUT_PORT" -le 65535 ]; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    IFACE=$(ip route get "$TARGET_IP" | awk -- '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[ERROR] Скрипту не удалось определить интерфейс!${NC}"
        exit 1
    fi

    echo -e "${YELLOW}[*] Применение правил...${NC}"

    if ! remove_conflicting_rules "$PROTO" "$IN_PORT"; then
        echo -e "${RED}[ERROR] Не удалось удалить старое правило для порта $IN_PORT/$PROTO.${NC}"
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi

    if ! iptables -t nat -A PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT"; then
        echo -e "${RED}[ERROR] Не удалось создать DNAT. Проверьте введённые данные.${NC}"
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi

    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        if ! iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE; then
            iptables -t nat -D PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
            echo -e "${RED}[ERROR] Не удалось создать MASQUERADE на интерфейсе $IFACE.${NC}"
            read -p "Нажмите Enter для возврата в меню..."
            return
        fi
    fi

    if ! iptables -I FORWARD 1 -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT; then
        echo -e "${RED}[ERROR] Не удалось разрешить пересылку трафика в цепочке FORWARD.${NC}"
        iptables -t nat -D PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi

    if ! iptables -I FORWARD 1 -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT; then
        echo -e "${RED}[ERROR] Не удалось разрешить обратный трафик в цепочке FORWARD.${NC}"
        iptables -D FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -t nat -D PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi

    # После замены маршрута удаляем старую запись NAT-соединения.
    # Иначе постоянный UDP-поток (например, WireGuard) продолжит идти по прежнему DNAT.
    if command -v conntrack &> /dev/null; then
        conntrack -D -p "$PROTO" --dport "$IN_PORT" >/dev/null 2>&1 || true
    fi

    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]] ||
       ! iptables -t nat -C PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null ||
       ! iptables -C FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
       ! iptables -C FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
       ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        echo -e "${RED}[ERROR] Проверка созданного маршрута не пройдена. Успешный статус не сохранён.${NC}"
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi

    if ! set_rule_name "$PROTO" "$IN_PORT" "$TARGET_IP:$OUT_PORT" "$SERVER_NAME"; then
        echo -e "${YELLOW}[WARNING] Маршрут создан, но не удалось сохранить его наименование.${NC}"
    fi

    if ! netfilter-persistent save > /dev/null; then
        echo -e "${YELLOW}[WARNING] Маршрут активен, но не удалось сохранить его для перезагрузки.${NC}"
    fi
    
    echo -e "${GREEN}[SUCCESS] Туннель успешно настроен!${NC}"
    echo -e "$SERVER_NAME: $PROTO, порт $IN_PORT -> $TARGET_IP:$OUT_PORT"
    read -p "Нажмите Enter для возврата в меню..."
}

# --- РАБОТА С НАИМЕНОВАНИЯМИ ПРАВИЛ ---
extract_rule_comment() {
    local line="$1"
    local quoted_regex='--comment[[:space:]]+"(routing:[^"]*)"'
    local plain_regex='--comment[[:space:]]+(routing:[^[:space:]]+)'

    if [[ "$line" =~ $quoted_regex ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $plain_regex ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

extract_rule_port() {
    local line="$1"
    local regex='--dport[[:space:]]+([0-9]+)'
    if [[ "$line" =~ $regex ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

extract_rule_proto() {
    local line="$1"
    local regex='(^|[[:space:]])-p[[:space:]]+([[:alnum:]_]+)'
    if [[ "$line" =~ $regex ]]; then printf '%s' "${BASH_REMATCH[2]}"; fi
}

extract_rule_destination() {
    local line="$1"
    local regex='--to-destination[[:space:]]+([0-9.:]+)'
    if [[ "$line" =~ $regex ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

get_rule_name() {
    local proto="$1"
    local port="$2"
    local destination="$3"

    local name

    [[ -f "$NAMES_FILE" ]] || return
    name=$(awk -F'|' -v proto="$proto" -v port="$port" -v destination="$destination" '
        $1 == proto && $2 == port && $3 == destination { print $4; exit }
    ' "$NAMES_FILE")
    if [[ -n "$name" ]] && is_valid_utf8 "$name"; then printf '%s' "$name"; fi
}

set_rule_name() {
    local proto="$1"
    local port="$2"
    local destination="$3"
    local name="$4"
    local temp_file

    is_valid_utf8 "$name" || return 1
    mkdir -p "$(dirname "$NAMES_FILE")" || return 1
    touch "$NAMES_FILE" || return 1
    temp_file=$(mktemp "${NAMES_FILE}.tmp.XXXXXX") || return 1

    if ! awk -F'|' -v proto="$proto" -v port="$port" -v destination="$destination" '
        !($1 == proto && $2 == port && $3 == destination)
    ' "$NAMES_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! printf '%s|%s|%s|%s\n' "$proto" "$port" "$destination" "$name" >> "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    chmod 600 "$temp_file"
    mv -f "$temp_file" "$NAMES_FILE"
}

delete_rule_name() {
    local proto="$1"
    local port="$2"
    local destination="$3"
    local temp_file

    [[ -f "$NAMES_FILE" ]] || return 0
    temp_file=$(mktemp "${NAMES_FILE}.tmp.XXXXXX") || return 1

    if ! awk -F'|' -v proto="$proto" -v port="$port" -v destination="$destination" '
        !($1 == proto && $2 == port && $3 == destination)
    ' "$NAMES_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    chmod 600 "$temp_file"
    mv -f "$temp_file" "$NAMES_FILE"
}

migrate_legacy_names() {
    local line
    local proto
    local port
    local destination
    local comment
    local name

    while read -r line; do
        [[ "$line" == *"-j DNAT"* ]] || continue
        proto=$(extract_rule_proto "$line")
        port=$(extract_rule_port "$line")
        destination=$(extract_rule_destination "$line")
        [[ -n "$proto" && -n "$port" && -n "$destination" ]] || continue
        [[ -z "$(get_rule_name "$proto" "$port" "$destination")" ]] || continue

        comment=$(extract_rule_comment "$line")
        name="${comment#routing:}"
        if [[ -n "$name" ]] && is_valid_utf8 "$name"; then
            set_rule_name "$proto" "$port" "$destination" "$name" 2>/dev/null || true
        fi
    done < <(iptables -t nat -S PREROUTING 2>/dev/null)
}

print_rule_table_row() {
    local name="$1"
    local port="$2"
    local proto="$3"
    local destination="$4"
    local name_width="$5"
    local port_width="$6"
    local proto_width="$7"
    local gap=3

    printf '%s%*s%s%*s%s%*s%s\n' \
        "$name" "$((name_width - ${#name} + gap))" "" \
        "$port" "$((port_width - ${#port} + gap))" "" \
        "$proto" "$((proto_width - ${#proto} + gap))" "" \
        "$destination"
}

# --- СПИСОК ПРАВИЛ ---
list_active_rules() {
    echo -e "\n${CYAN}--- Активные переадресации ---${NC}"
    declare -a DISPLAY_RULES
    local NAME_HEADER="НАИМЕНОВАНИЕ"
    local PORT_HEADER="ВХОДЯЩИЙ ПОРТ"
    local PROTO_HEADER="ПРОТОКОЛ"
    local DEST_HEADER="ЦЕЛЬ"
    local name_width
    local port_width
    local proto_width

    name_width=${#NAME_HEADER}
    port_width=${#PORT_HEADER}
    proto_width=${#PROTO_HEADER}

    while IFS='|' read -r l_port l_name l_proto l_dest; do
        DISPLAY_RULES+=("$l_port|$l_name|$l_proto|$l_dest")
        if [ ${#l_name} -gt "$name_width" ]; then name_width=${#l_name}; fi
        if [ ${#l_port} -gt "$port_width" ]; then port_width=${#l_port}; fi
        if [ ${#l_proto} -gt "$proto_width" ]; then proto_width=${#l_proto}; fi
    done < <(
        iptables -t nat -S PREROUTING | while read -r line ; do
            [[ "$line" == *"-j DNAT"* ]] || continue
            l_port=$(extract_rule_port "$line")
            l_proto=$(extract_rule_proto "$line")
            l_dest=$(extract_rule_destination "$line")
            l_name=$(get_rule_name "$l_proto" "$l_port" "$l_dest")
            # Однократная совместимость с именами из прежних версий скрипта.
            if [[ -z "$l_name" ]]; then
                l_comment=$(extract_rule_comment "$line")
                l_name="${l_comment#routing:}"
            fi
            if [[ -n "$l_name" ]] && ! is_valid_utf8 "$l_name"; then l_name=""; fi
            if [[ -z "$l_name" ]]; then l_name="Без имени"; fi
            if [[ -n "$l_port" ]]; then printf '%s|%s|%s|%s\n' "$l_port" "$l_name" "$l_proto" "$l_dest"; fi
        done | sort -t'|' -k1,1n
    )

    echo -ne "${MAGENTA}"
    print_rule_table_row "$NAME_HEADER" "$PORT_HEADER" "$PROTO_HEADER" "$DEST_HEADER" "$name_width" "$port_width" "$proto_width"
    echo -ne "${NC}"

    for rule in "${DISPLAY_RULES[@]}"; do
        IFS='|' read -r l_port l_name l_proto l_dest <<< "$rule"
        print_rule_table_row "$l_name" "$l_port" "$l_proto" "$l_dest" "$name_width" "$port_width" "$proto_width"
    done
    echo ""
    read -p "Нажмите Enter..."
}

# --- БЫСТРАЯ ЗАМЕНА КОНЕЧНОГО IP ---
update_target_ip() {
    echo -e "\n${CYAN}--- Быстрая замена конечного IP ---${NC}"
    declare -a UPDATE_RULES
    local i=1
    local rule_index=0

    while IFS='|' read -r u_port u_index u_proto u_dest u_name; do
        u_display_name="$u_name"
        if [[ -z "$u_display_name" ]]; then u_display_name="Без имени"; fi
        UPDATE_RULES[$i]="$u_index|$u_port|$u_proto|$u_dest|$u_name"
        echo -e "${YELLOW}[$i]${NC} $u_display_name: входящий порт $u_port ($u_proto) -> $u_dest"
        ((i++))
    done < <(
        while read -r line; do
            [[ "$line" == "-A PREROUTING "* ]] || continue
            ((rule_index++))
            [[ "$line" == *"-j DNAT"* ]] || continue

            u_port=$(extract_rule_port "$line")
            u_proto=$(extract_rule_proto "$line")
            u_dest=$(extract_rule_destination "$line")
            u_name=$(get_rule_name "$u_proto" "$u_port" "$u_dest")
            if [[ -z "$u_name" ]]; then
                u_comment=$(extract_rule_comment "$line")
                u_name="${u_comment#routing:}"
            fi
            if [[ -n "$u_name" ]] && ! is_valid_utf8 "$u_name"; then u_name=""; fi

            if [[ -n "$u_port" && -n "$u_proto" && -n "$u_dest" ]]; then
                printf '%s|%s|%s|%s|%s\n' "$u_port" "$rule_index" "$u_proto" "$u_dest" "$u_name"
            fi
        done < <(iptables -t nat -S PREROUTING) |
            sort -t'|' -k1,1n
    )

    if [ ${#UPDATE_RULES[@]} -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo ""
    read -p "Номер правила (или 0 для отмены): " rule_num
    if [[ "$rule_num" == "0" || -z "${UPDATE_RULES[$rule_num]}" ]]; then return; fi

    while true; do
        echo -e "Введите новый конечный IPv4-адрес:"
        read -r -p "> " new_target_ip
        if is_valid_ipv4 "$new_target_ip"; then break; fi
        echo -e "${RED}Ошибка: введите корректный IPv4-адрес.${NC}"
    done

    IFS='|' read -r u_index u_port u_proto u_dest u_name <<< "${UPDATE_RULES[$rule_num]}"
    u_old_ip="${u_dest%:*}"
    u_out_port="${u_dest##*:}"
    u_new_dest="$new_target_ip:$u_out_port"

    if [[ "$new_target_ip" == "$u_old_ip" ]]; then
        echo -e "${YELLOW}[INFO] Этот IP уже установлен. Изменения не требуются.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    u_iface=$(ip route get "$new_target_ip" | awk -- '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    if [[ -z "$u_iface" ]]; then
        echo -e "${RED}[ERROR] Не удалось определить маршрут до $new_target_ip.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    if ! iptables -t nat -C POSTROUTING -o "$u_iface" -j MASQUERADE 2>/dev/null; then
        if ! iptables -t nat -A POSTROUTING -o "$u_iface" -j MASQUERADE; then
            echo -e "${RED}[ERROR] Не удалось создать MASQUERADE на интерфейсе $u_iface.${NC}"
            read -p "Нажмите Enter..."
            return
        fi
    fi

    if ! iptables -I FORWARD 1 -p "$u_proto" -d "$new_target_ip" --dport "$u_out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT; then
        echo -e "${RED}[ERROR] Не удалось разрешить трафик к новому IP.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    if ! iptables -I FORWARD 1 -p "$u_proto" -s "$new_target_ip" --sport "$u_out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT; then
        iptables -D FORWARD -p "$u_proto" -d "$new_target_ip" --dport "$u_out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        echo -e "${RED}[ERROR] Не удалось разрешить обратный трафик от нового IP.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    if ! iptables -t nat -R PREROUTING "$u_index" -p "$u_proto" --dport "$u_port" -j DNAT --to-destination "$u_new_dest"; then
        iptables -D FORWARD -p "$u_proto" -d "$new_target_ip" --dport "$u_out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -D FORWARD -p "$u_proto" -s "$new_target_ip" --sport "$u_out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        echo -e "${RED}[ERROR] Не удалось заменить конечный IP в DNAT.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    if ! iptables -t nat -C PREROUTING -p "$u_proto" --dport "$u_port" -j DNAT --to-destination "$u_new_dest" 2>/dev/null; then
        iptables -t nat -R PREROUTING "$u_index" -p "$u_proto" --dport "$u_port" -j DNAT --to-destination "$u_dest" 2>/dev/null
        iptables -D FORWARD -p "$u_proto" -d "$new_target_ip" --dport "$u_out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -D FORWARD -p "$u_proto" -s "$new_target_ip" --sport "$u_out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        echo -e "${RED}[ERROR] Проверка нового DNAT не пройдена; старый маршрут восстановлен.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    iptables -D FORWARD -p "$u_proto" -d "$u_old_ip" --dport "$u_out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$u_proto" -s "$u_old_ip" --sport "$u_out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    if [[ -n "$u_name" ]]; then
        if set_rule_name "$u_proto" "$u_port" "$u_new_dest" "$u_name"; then
            delete_rule_name "$u_proto" "$u_port" "$u_dest" 2>/dev/null || true
        else
            echo -e "${YELLOW}[WARNING] IP изменён, но не удалось перенести наименование.${NC}"
        fi
    else
        delete_rule_name "$u_proto" "$u_port" "$u_dest" 2>/dev/null || true
    fi

    if command -v conntrack &> /dev/null; then
        conntrack -D -p "$u_proto" --dport "$u_port" >/dev/null 2>&1 || true
    fi

    if ! netfilter-persistent save > /dev/null; then
        echo -e "${YELLOW}[WARNING] IP изменён, но не удалось сохранить правила для перезагрузки.${NC}"
    fi

    echo -e "${GREEN}[OK] Конечный IP изменён: $u_old_ip -> $new_target_ip${NC}"
    echo -e "$u_proto: порт $u_port -> $u_new_dest"
    read -p "Нажмите Enter..."
}

# --- УДАЛЕНИЕ ОДНОГО ПРАВИЛА ---
delete_single_rule() {
    echo -e "\n${CYAN}--- Удаление правила ---${NC}"
    declare -a RULES_LIST
    local i=1
    while read -r line; do
        [[ "$line" == *"-j DNAT"* ]] || continue
        l_port=$(extract_rule_port "$line")
        l_proto=$(extract_rule_proto "$line")
        l_dest=$(extract_rule_destination "$line")
        l_comment=$(extract_rule_comment "$line")
        l_name=$(get_rule_name "$l_proto" "$l_port" "$l_dest")
        if [[ -z "$l_name" ]]; then l_name="${l_comment#routing:}"; fi
        if [[ -n "$l_name" ]] && ! is_valid_utf8 "$l_name"; then l_name=""; fi
        if [[ -z "$l_name" ]]; then l_name="Без имени"; fi
        if [[ -n "$l_port" ]]; then
            RULES_LIST[$i]="$l_port|$l_proto|$l_dest|$l_comment"
            echo -e "${YELLOW}[$i]${NC} $l_name: входящий порт $l_port ($l_proto) -> $l_dest"
            ((i++))
        fi
    done < <(iptables -t nat -S PREROUTING)

    if [ ${#RULES_LIST[@]} -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo ""
    read -p "Номер правила для удаления (или введите число 0 для отмены): " rule_num
    if [[ "$rule_num" == "0" || -z "${RULES_LIST[$rule_num]}" ]]; then return; fi

    IFS='|' read -r d_port d_proto d_dest d_comment <<< "${RULES_LIST[$rule_num]}"
    d_target_ip="${d_dest%:*}"
    d_target_port="${d_dest##*:}"
    
    if [[ -n "$d_comment" ]]; then
        iptables -t nat -D PREROUTING -p "$d_proto" --dport "$d_port" -m comment --comment "$d_comment" -j DNAT --to-destination "$d_dest" 2>/dev/null
    else
        iptables -t nat -D PREROUTING -p "$d_proto" --dport "$d_port" -j DNAT --to-destination "$d_dest" 2>/dev/null
    fi
    iptables -D INPUT -p "$d_proto" --dport "$d_port" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$d_proto" -d "$d_target_ip" --dport "$d_target_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$d_proto" -s "$d_target_ip" --sport "$d_target_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    if command -v conntrack &> /dev/null; then
        conntrack -D -p "$d_proto" --dport "$d_port" >/dev/null 2>&1 || true
    fi

    delete_rule_name "$d_proto" "$d_port" "$d_dest" 2>/dev/null || true
    
    netfilter-persistent save > /dev/null
    echo -e "${GREEN}[OK] Удалено.${NC}"
    read -p "Нажмите Enter..."
}

# --- ПРИСВОЕНИЕ ИЛИ ИЗМЕНЕНИЕ НАИМЕНОВАНИЯ ---
rename_rule() {
    echo -e "\n${CYAN}--- Наименование правила ---${NC}"
    declare -a RENAME_RULES
    local i=1

    while IFS='|' read -r r_port r_proto r_dest r_name; do
        RENAME_RULES[$i]="$r_port|$r_proto|$r_dest"
        echo -e "${YELLOW}[$i]${NC} $r_name: входящий порт $r_port ($r_proto) -> $r_dest"
        ((i++))
    done < <(
        while read -r line; do
            [[ "$line" == *"-j DNAT"* ]] || continue
            r_port=$(extract_rule_port "$line")
            r_proto=$(extract_rule_proto "$line")
            r_dest=$(extract_rule_destination "$line")
            r_name=$(get_rule_name "$r_proto" "$r_port" "$r_dest")
            if [[ -z "$r_name" ]]; then
                r_comment=$(extract_rule_comment "$line")
                r_name="${r_comment#routing:}"
            fi
            if [[ -n "$r_name" ]] && ! is_valid_utf8 "$r_name"; then r_name=""; fi
            if [[ -z "$r_name" ]]; then r_name="Без имени"; fi
            if [[ -n "$r_port" && -n "$r_proto" && -n "$r_dest" ]]; then
                printf '%s|%s|%s|%s\n' "$r_port" "$r_proto" "$r_dest" "$r_name"
            fi
        done < <(iptables -t nat -S PREROUTING) |
            sort -t'|' -k1,1n
    )

    if [ ${#RENAME_RULES[@]} -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo ""
    read -p "Номер правила (или 0 для отмены): " rule_num
    if [[ "$rule_num" == "0" || -z "${RENAME_RULES[$rule_num]}" ]]; then return; fi

    while true; do
        echo -e "Введите новое наименование сервера:"
        read -r -e -p "> " new_name
        if [[ -n "$new_name" && ${#new_name} -le 100 && "$new_name" != *'|'* && "$new_name" != *'"'* ]] && is_valid_utf8 "$new_name"; then break; fi
        echo -e "${RED}Ошибка: используйте корректный UTF-8 текст длиной от 1 до 100 символов без | и \".${NC}"
    done

    IFS='|' read -r r_port r_proto r_dest <<< "${RENAME_RULES[$rule_num]}"
    if set_rule_name "$r_proto" "$r_port" "$r_dest" "$new_name"; then
        echo -e "${GREEN}[OK] Правилу присвоено имя: $new_name${NC}"
    else
        echo -e "${RED}[ERROR] Не удалось изменить наименование правила.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- ПОЛНАЯ ОЧИСТКА ---
flush_rules() {
    echo -e "\n${RED}!!! ВНИМАНИЕ !!!${NC}"
    echo "Сброс ВСЕХ настроек iptables."
    read -p "Вы уверены? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -t nat -F
        iptables -t mangle -F
        iptables -F
        iptables -X
        : > "$NAMES_FILE"
        netfilter-persistent save > /dev/null
        echo -e "${GREEN}[OK] Очищено.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- МЕНЮ ---
show_menu() {
    while true; do
        clear
		
		echo -e "------------------------------------------------------"
        echo -e "${GREEN}💰 Лучший VPN-сервис:${NC} https://t.me/wieldvpnrobot"
        echo -e "------------------------------------------------------"

		echo ""
                
        echo -e "1) Настроить ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "2) Настроить ${CYAN}VLESS / XRay${NC} (TCP)"
        echo -e "3) ${YELLOW}Быстро изменить конечный IP${NC}"
        echo -e "4) Посмотреть активные правила"
        echo -e "5) ${RED}Удалить одно правило${NC}"
        echo -e "6) ${RED}Сбросить ВСЕ настройки${NC}"
        echo -e "7) ${YELLOW}Показать PROMO${NC}"
        echo -e "8) ${MAGENTA}📚 ИНСТРУКЦИЯ (Как настроить)${NC}" 
        echo -e "9) ${CYAN}Присвоить / изменить наименование правила${NC}"
        echo -e "0) Выход"
        echo -e "------------------------------------------------------"
        read -p "Ваш выбор: " choice

        case $choice in
            1) configure_rule "udp" "AmneziaWG" ;;
            2) configure_rule "tcp" "VLESS" ;;
            3) update_target_ip ;;
            4) list_active_rules ;;
            5) delete_single_rule ;;
            6) flush_rules ;;
            7) show_promo ;;
            8) show_instructions ;;
            9) rename_rule ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- ЗАПУСК ---
check_root
prepare_system
show_promo_once
show_menu
