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
GROUPS_FILE='/var/lib/routing/groups.db'
FAILOVER_LOCK_FILE='/run/routing-failover.lock'

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
    touch "$GROUPS_FILE"
    chmod 600 "$GROUPS_FILE"

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
            delete_rule_group "$proto" "$in_port" "$old_dest" 2>/dev/null || true
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

get_rule_group() {
    local proto="$1"
    local port="$2"
    local destination="$3"
    local group

    [[ -f "$GROUPS_FILE" ]] || return
    group=$(awk -F'|' -v proto="$proto" -v port="$port" -v destination="$destination" '
        $1 == proto && $2 == port && $3 == destination { print $4; exit }
    ' "$GROUPS_FILE")
    if [[ -n "$group" ]] && is_valid_utf8 "$group"; then printf '%s' "$group"; fi
}

set_rule_group() {
    local proto="$1"
    local port="$2"
    local destination="$3"
    local group="$4"
    local temp_file

    [[ -n "$group" && ${#group} -le 100 && "$group" != *'|'* ]] || return 1
    is_valid_utf8 "$group" || return 1
    mkdir -p "$(dirname "$GROUPS_FILE")" || return 1
    touch "$GROUPS_FILE" || return 1
    temp_file=$(mktemp "${GROUPS_FILE}.tmp.XXXXXX") || return 1

    if ! awk -F'|' -v proto="$proto" -v port="$port" -v destination="$destination" '
        !($1 == proto && $2 == port && $3 == destination)
    ' "$GROUPS_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! printf '%s|%s|%s|%s\n' "$proto" "$port" "$destination" "$group" >> "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    chmod 600 "$temp_file"
    mv -f "$temp_file" "$GROUPS_FILE"
}

delete_rule_group() {
    local proto="$1"
    local port="$2"
    local destination="$3"
    local temp_file

    [[ -f "$GROUPS_FILE" ]] || return 0
    temp_file=$(mktemp "${GROUPS_FILE}.tmp.XXXXXX") || return 1
    if ! awk -F'|' -v proto="$proto" -v port="$port" -v destination="$destination" '
        !($1 == proto && $2 == port && $3 == destination)
    ' "$GROUPS_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$GROUPS_FILE"
}

delete_group_records() {
    local group="$1"
    local temp_file

    [[ -f "$GROUPS_FILE" ]] || return 0
    temp_file=$(mktemp "${GROUPS_FILE}.tmp.XXXXXX") || return 1
    if ! awk -F'|' -v group="$group" '$4 != group' "$GROUPS_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$GROUPS_FILE"
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

emit_dnat_rules() {
    local line
    local rule_index=0
    local port
    local proto
    local destination
    local name
    local comment
    local group

    while read -r line; do
        [[ "$line" == "-A PREROUTING "* ]] || continue
        ((rule_index++))
        [[ "$line" == *"-j DNAT"* ]] || continue

        port=$(extract_rule_port "$line")
        proto=$(extract_rule_proto "$line")
        destination=$(extract_rule_destination "$line")
        [[ -n "$port" && -n "$proto" && -n "$destination" ]] || continue

        name=$(get_rule_name "$proto" "$port" "$destination")
        if [[ -z "$name" ]]; then
            comment=$(extract_rule_comment "$line")
            name="${comment#routing:}"
        fi
        if [[ -n "$name" ]] && ! is_valid_utf8 "$name"; then name=""; fi
        group=$(get_rule_group "$proto" "$port" "$destination")

        printf '%s|%s|%s|%s|%s|%s\n' "$port" "$rule_index" "$proto" "$destination" "$name" "$group"
    done < <(iptables -t nat -S PREROUTING 2>/dev/null) | sort -t'|' -k1,1n
}

parse_rule_selection() {
    local selection="$1"
    local max_index="$2"
    local token
    local start
    local end
    local value
    declare -A seen
    SELECTED_INDICES=()

    selection="${selection//,/ }"
    if [[ "$selection" == "all" || "$selection" == "все" ]]; then
        for ((value=1; value<=max_index; value++)); do SELECTED_INDICES+=("$value"); done
        return 0
    fi

    for token in $selection; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=$((10#${BASH_REMATCH[1]}))
            end=$((10#${BASH_REMATCH[2]}))
            ((start >= 1 && end >= start && end <= max_index)) || return 1
            for ((value=start; value<=end; value++)); do
                if [[ -z "${seen[$value]}" ]]; then SELECTED_INDICES+=("$value"); seen[$value]=1; fi
            done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            value=$((10#$token))
            ((value >= 1 && value <= max_index)) || return 1
            if [[ -z "${seen[$value]}" ]]; then SELECTED_INDICES+=("$value"); seen[$value]=1; fi
        else
            return 1
        fi
    done

    [ ${#SELECTED_INDICES[@]} -gt 0 ]
}

select_existing_group() {
    declare -a GROUP_OPTIONS
    local i=1
    local group

    while IFS= read -r group; do
        [[ -n "$group" ]] || continue
        GROUP_OPTIONS[$i]="$group"
        echo -e "${YELLOW}[$i]${NC} $group"
        ((i++))
    done < <(
        emit_dnat_rules | while IFS='|' read -r _ _ _ _ _ group; do
            if [[ -n "$group" ]]; then printf '%s\n' "$group"; fi
        done | sort -u
    )

    if [ ${#GROUP_OPTIONS[@]} -eq 0 ]; then
        echo -e "${RED}Нет созданных групп.${NC}"
        return 1
    fi

    read -p "Номер группы (или 0 для отмены): " group_num
    if [[ ! "$group_num" =~ ^[0-9]+$ || "$group_num" == "0" || -z "${GROUP_OPTIONS[$group_num]}" ]]; then return 1; fi
    SELECTED_GROUP="${GROUP_OPTIONS[$group_num]}"
}

print_rule_table_row() {
    local name="$1"
    local group="$2"
    local port="$3"
    local proto="$4"
    local destination="$5"
    local name_width="$6"
    local group_width="$7"
    local port_width="$8"
    local proto_width="$9"
    local gap=3

    printf '%s%*s%s%*s%s%*s%s%*s%s\n' \
        "$name" "$((name_width - ${#name} + gap))" "" \
        "$group" "$((group_width - ${#group} + gap))" "" \
        "$port" "$((port_width - ${#port} + gap))" "" \
        "$proto" "$((proto_width - ${#proto} + gap))" "" \
        "$destination"
}

# --- СПИСОК ПРАВИЛ ---
list_active_rules() {
    echo -e "\n${CYAN}--- Активные переадресации ---${NC}"
    declare -a DISPLAY_RULES
    local NAME_HEADER="НАИМЕНОВАНИЕ"
    local GROUP_HEADER="ГРУППА"
    local PORT_HEADER="ВХОДЯЩИЙ ПОРТ"
    local PROTO_HEADER="ПРОТОКОЛ"
    local DEST_HEADER="ЦЕЛЬ"
    local name_width
    local group_width
    local port_width
    local proto_width

    name_width=${#NAME_HEADER}
    group_width=${#GROUP_HEADER}
    port_width=${#PORT_HEADER}
    proto_width=${#PROTO_HEADER}

    while IFS='|' read -r l_port _ l_proto l_dest l_name l_group; do
        if [[ -z "$l_name" ]]; then l_name="Без имени"; fi
        if [[ -z "$l_group" ]]; then l_group="—"; fi
        DISPLAY_RULES+=("$l_port|$l_name|$l_group|$l_proto|$l_dest")
        if [ ${#l_name} -gt "$name_width" ]; then name_width=${#l_name}; fi
        if [ ${#l_group} -gt "$group_width" ]; then group_width=${#l_group}; fi
        if [ ${#l_port} -gt "$port_width" ]; then port_width=${#l_port}; fi
        if [ ${#l_proto} -gt "$proto_width" ]; then proto_width=${#l_proto}; fi
    done < <(emit_dnat_rules)

    echo -ne "${MAGENTA}"
    print_rule_table_row "$NAME_HEADER" "$GROUP_HEADER" "$PORT_HEADER" "$PROTO_HEADER" "$DEST_HEADER" "$name_width" "$group_width" "$port_width" "$proto_width"
    echo -ne "${NC}"

    for rule in "${DISPLAY_RULES[@]}"; do
        IFS='|' read -r l_port l_name l_group l_proto l_dest <<< "$rule"
        print_rule_table_row "$l_name" "$l_group" "$l_port" "$l_proto" "$l_dest" "$name_width" "$group_width" "$port_width" "$proto_width"
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

    while IFS='|' read -r u_port u_index u_proto u_dest u_name u_group; do
        u_display_name="$u_name"
        if [[ -z "$u_display_name" ]]; then u_display_name="Без имени"; fi
        UPDATE_RULES[$i]="$u_index|$u_port|$u_proto|$u_dest|$u_name|$u_group"
        if [[ -n "$u_group" ]]; then u_group_label=" [группа: $u_group]"; else u_group_label=""; fi
        echo -e "${YELLOW}[$i]${NC} $u_display_name$u_group_label: входящий порт $u_port ($u_proto) -> $u_dest"
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
            u_group=$(get_rule_group "$u_proto" "$u_port" "$u_dest")

            if [[ -n "$u_port" && -n "$u_proto" && -n "$u_dest" ]]; then
                printf '%s|%s|%s|%s|%s|%s\n' "$u_port" "$rule_index" "$u_proto" "$u_dest" "$u_name" "$u_group"
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

    IFS='|' read -r u_index u_port u_proto u_dest u_name u_group <<< "${UPDATE_RULES[$rule_num]}"
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

    if [[ -n "$u_group" ]]; then
        if set_rule_group "$u_proto" "$u_port" "$u_new_dest" "$u_group"; then
            delete_rule_group "$u_proto" "$u_port" "$u_dest" 2>/dev/null || true
        else
            echo -e "${YELLOW}[WARNING] IP изменён, но не удалось перенести группу.${NC}"
        fi
    else
        delete_rule_group "$u_proto" "$u_port" "$u_dest" 2>/dev/null || true
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

change_rule_target_ip() {
    local rule_index="$1"
    local in_port="$2"
    local proto="$3"
    local old_dest="$4"
    local new_ip="$5"
    local name="$6"
    local group="$7"
    local old_ip="${old_dest%:*}"
    local out_port="${old_dest##*:}"
    local new_dest="$new_ip:$out_port"
    local iface

    [[ "$new_ip" != "$old_ip" ]] || return 0
    iface=$(ip route get "$new_ip" | awk -- '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    if [[ -z "$iface" ]]; then
        echo -e "${RED}[ERROR] Порт $in_port: нет маршрута до $new_ip.${NC}"
        return 1
    fi

    if ! iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null; then
        if ! iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE; then
            echo -e "${RED}[ERROR] Порт $in_port: не удалось создать MASQUERADE.${NC}"
            return 1
        fi
    fi

    if ! iptables -I FORWARD 1 -p "$proto" -d "$new_ip" --dport "$out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT; then
        echo -e "${RED}[ERROR] Порт $in_port: не удалось разрешить прямой трафик.${NC}"
        return 1
    fi
    if ! iptables -I FORWARD 1 -p "$proto" -s "$new_ip" --sport "$out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT; then
        iptables -D FORWARD -p "$proto" -d "$new_ip" --dport "$out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        echo -e "${RED}[ERROR] Порт $in_port: не удалось разрешить обратный трафик.${NC}"
        return 1
    fi

    if ! iptables -t nat -R PREROUTING "$rule_index" -p "$proto" --dport "$in_port" -j DNAT --to-destination "$new_dest"; then
        iptables -D FORWARD -p "$proto" -d "$new_ip" --dport "$out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -D FORWARD -p "$proto" -s "$new_ip" --sport "$out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        echo -e "${RED}[ERROR] Порт $in_port: не удалось заменить DNAT.${NC}"
        return 1
    fi

    if ! iptables -t nat -C PREROUTING -p "$proto" --dport "$in_port" -j DNAT --to-destination "$new_dest" 2>/dev/null; then
        iptables -t nat -R PREROUTING "$rule_index" -p "$proto" --dport "$in_port" -j DNAT --to-destination "$old_dest" 2>/dev/null
        iptables -D FORWARD -p "$proto" -d "$new_ip" --dport "$out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -D FORWARD -p "$proto" -s "$new_ip" --sport "$out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        echo -e "${RED}[ERROR] Порт $in_port: проверка DNAT не пройдена, старое правило восстановлено.${NC}"
        return 1
    fi

    iptables -D FORWARD -p "$proto" -d "$old_ip" --dport "$out_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$proto" -s "$old_ip" --sport "$out_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    if [[ -n "$name" ]]; then
        if set_rule_name "$proto" "$in_port" "$new_dest" "$name"; then
            delete_rule_name "$proto" "$in_port" "$old_dest" 2>/dev/null || true
        else
            echo -e "${YELLOW}[WARNING] Порт $in_port: не удалось перенести наименование.${NC}"
        fi
    else
        delete_rule_name "$proto" "$in_port" "$old_dest" 2>/dev/null || true
    fi

    if [[ -n "$group" ]]; then
        if set_rule_group "$proto" "$in_port" "$new_dest" "$group"; then
            delete_rule_group "$proto" "$in_port" "$old_dest" 2>/dev/null || true
        else
            echo -e "${YELLOW}[WARNING] Порт $in_port: не удалось перенести группу.${NC}"
        fi
    else
        delete_rule_group "$proto" "$in_port" "$old_dest" 2>/dev/null || true
    fi

    if command -v conntrack &> /dev/null; then
        conntrack -D -p "$proto" --dport "$in_port" >/dev/null 2>&1 || true
    fi
    return 0
}


# --- НЕИНТЕРАКТИВНОЕ / АВТОМАТИЧЕСКОЕ ПЕРЕКЛЮЧЕНИЕ HOP ---
# Используется watchdog'ом и может вызываться вручную:
#   routing.sh replace-hop OLD_IP NEW_IP
#   routing.sh replace-group GROUP OLD_IP NEW_IP
#
# replace-hop меняет все активные DNAT-правила, которые сейчас смотрят на OLD_IP.
# replace-group делает то же самое, но только внутри указанной группы.
# Перед изменениями создаётся снимок iptables и локальных БД имён/групп.
# При любой ошибке правила откатываются целиком.

ensure_failover_state() {
    mkdir -p "$(dirname "$NAMES_FILE")" || return 1
    touch "$NAMES_FILE" "$GROUPS_FILE" || return 1
    chmod 600 "$NAMES_FILE" "$GROUPS_FILE" 2>/dev/null || true
}

bulk_replace_target_ip() (
    local old_ip="$1"
    local new_ip="$2"
    local scope_group="${3:-}"
    local lock_fd=9
    local tmpdir=""
    local iptables_snapshot=""
    local names_snapshot=""
    local groups_snapshot=""
    local record
    local port
    local rule_index
    local proto
    local destination
    local name
    local group
    local destination_ip
    local success=0
    local failed=0
    local total=0
    local iface
    declare -a MATCHED_RULES=()

    if ! is_valid_ipv4 "$old_ip" || ! is_valid_ipv4 "$new_ip"; then
        echo -e "${RED}[ERROR] OLD_IP и NEW_IP должны быть корректными IPv4-адресами.${NC}" >&2
        return 2
    fi
    if [[ "$old_ip" == "$new_ip" ]]; then
        echo -e "${YELLOW}[INFO] OLD_IP и NEW_IP совпадают — переключение не требуется.${NC}"
        return 0
    fi
    if [[ -n "$scope_group" && ( ${#scope_group} -gt 100 || "$scope_group" == *'|'* ) ]]; then
        echo -e "${RED}[ERROR] Некорректное имя группы.${NC}" >&2
        return 2
    fi

    if ! command -v flock >/dev/null 2>&1; then
        echo '[ERROR] Нужен flock (util-linux).' >&2
        return 1
    fi
    exec 9>"$FAILOVER_LOCK_FILE" || return 1
    if ! flock -n 9; then
        echo '[ERROR] routing занят (импорт/экспорт/редактирование/failover).' >&2
        return 75
    fi
    ensure_failover_state || return 1

    iface=$(ip route get "$new_ip" 2>/dev/null | awk -- '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    if [[ -z "$iface" ]]; then
        echo -e "${RED}[ERROR] Нет маршрута до нового hop $new_ip.${NC}" >&2
        return 1
    fi

    while IFS='|' read -r port rule_index proto destination name group; do
        destination_ip="${destination%:*}"
        [[ "$destination_ip" == "$old_ip" ]] || continue
        if [[ -n "$scope_group" && "$group" != "$scope_group" ]]; then
            continue
        fi
        MATCHED_RULES+=("$rule_index|$port|$proto|$destination|$name|$group")
    done < <(emit_dnat_rules)

    total=${#MATCHED_RULES[@]}
    if (( total == 0 )); then
        if [[ -n "$scope_group" ]]; then
            echo -e "${YELLOW}[INFO] В группе '$scope_group' нет правил, направленных на $old_ip.${NC}" >&2
        else
            echo -e "${YELLOW}[INFO] Нет активных DNAT-правил, направленных на $old_ip.${NC}" >&2
        fi
        return 3
    fi

    tmpdir=$(mktemp -d /tmp/routing-failover.XXXXXX) || return 1
    iptables_snapshot="$tmpdir/iptables.save"
    names_snapshot="$tmpdir/names.db"
    groups_snapshot="$tmpdir/groups.db"

    if ! iptables-save > "$iptables_snapshot"; then
        rm -rf "$tmpdir"
        echo -e "${RED}[ERROR] Не удалось создать snapshot iptables.${NC}" >&2
        return 1
    fi
    cp -a "$NAMES_FILE" "$names_snapshot" 2>/dev/null || : > "$names_snapshot"
    cp -a "$GROUPS_FILE" "$groups_snapshot" 2>/dev/null || : > "$groups_snapshot"

    if [[ -n "$scope_group" ]]; then
        echo -e "${CYAN}[*] AUTO-SWITCH group='$scope_group': $old_ip -> $new_ip, правил: $total${NC}"
    else
        echo -e "${CYAN}[*] AUTO-SWITCH: $old_ip -> $new_ip, правил: $total${NC}"
    fi

    # PREROUTING здесь только заменяется через -R, поэтому индексы не сдвигаются.
    for record in "${MATCHED_RULES[@]}"; do
        IFS='|' read -r rule_index port proto destination name group <<< "$record"
        if change_rule_target_ip "$rule_index" "$port" "$proto" "$destination" "$new_ip" "$name" "$group"; then
            ((success++))
            echo -e "${GREEN}[OK] $proto/$port: ${destination%:*} -> $new_ip${NC}"
        else
            ((failed++))
            echo -e "${RED}[ERROR] $proto/$port: переключение не выполнено.${NC}" >&2
            break
        fi
    done

    if (( failed > 0 )); then
        echo -e "${YELLOW}[*] Ошибка во время переключения. Выполняю rollback...${NC}" >&2
        if iptables-restore < "$iptables_snapshot"; then
            cp -f "$names_snapshot" "$NAMES_FILE" 2>/dev/null || true
            cp -f "$groups_snapshot" "$GROUPS_FILE" 2>/dev/null || true
            chmod 600 "$NAMES_FILE" "$GROUPS_FILE" 2>/dev/null || true
            netfilter-persistent save >/dev/null 2>&1 || true
            echo -e "${GREEN}[ROLLBACK OK] Исходные правила восстановлены.${NC}" >&2
        else
            echo -e "${RED}[CRITICAL] Не удалось восстановить snapshot iptables!${NC}" >&2
        fi
        rm -rf "$tmpdir"
        return 1
    fi

    if ! netfilter-persistent save >/dev/null; then
        echo -e "${YELLOW}[WARNING] Переключение активно, но netfilter-persistent save завершился ошибкой.${NC}" >&2
    fi

    rm -rf "$tmpdir"
    echo -e "${GREEN}[SUCCESS] AUTO-SWITCH завершён: $old_ip -> $new_ip, правил: $success.${NC}"
    return 0
)

replace_hop_cli() {
    local old_ip="${1:-}"
    local new_ip="${2:-}"
    if [[ -z "$old_ip" || -z "$new_ip" ]]; then
        echo "Использование: $0 replace-hop OLD_IP NEW_IP" >&2
        return 2
    fi
    bulk_replace_target_ip "$old_ip" "$new_ip"
}

replace_group_cli() {
    local group="${1:-}"
    local old_ip="${2:-}"
    local new_ip="${3:-}"
    if [[ -z "$group" || -z "$old_ip" || -z "$new_ip" ]]; then
        echo "Использование: $0 replace-group GROUP OLD_IP NEW_IP" >&2
        return 2
    fi
    bulk_replace_target_ip "$old_ip" "$new_ip" "$group"
}

cli_usage() {
    cat <<EOF
Неинтерактивные команды:
  $0 export-config FILE.tar.gz
      Экспорт простых DNAT-маршрутов и names.db/groups.db (нужен python3).
  $0 import-config FILE.tar.gz [--dry-run] [--no-install-deps]
      Импорт на чистый Debian/Ubuntu second-hop; автоматический backup/rollback.
      --dry-run: проверка без установки пакетов/изменения правил.
      --no-install-deps: не устанавливать отсутствующие зависимости.
  $0 import-metadata FILE.tar.gz [--dry-run]
      Восстановить только имена/группы для существующих маршрутов, без изменения firewall.
  $0 refresh-conntrack FILE.tar.gz [--udp-only] [--dry-run]
      Проверить существующие маршруты и сбросить conntrack только их входящих портов.

  $0 replace-hop OLD_IP NEW_IP
      Переключить ВСЕ DNAT-правила с OLD_IP на NEW_IP.

  $0 replace-group GROUP OLD_IP NEW_IP
      Переключить только правила указанной группы.

Примеры:
  $0 replace-hop 203.0.113.10 203.0.113.20
  $0 replace-group HOP-A 203.0.113.10 203.0.113.20
EOF
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
    delete_rule_group "$d_proto" "$d_port" "$d_dest" 2>/dev/null || true
    
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

# --- УПРАВЛЕНИЕ ГРУППАМИ ---
add_rules_to_group() {
    echo -e "\n${CYAN}--- Создание группы / добавление правил ---${NC}"
    declare -a GROUP_RULES
    local i=1
    local group_label

    while IFS='|' read -r port _ proto destination name group; do
        [[ -n "$name" ]] || name="Без имени"
        if [[ -n "$group" ]]; then group_label="группа: $group"; else group_label="без группы"; fi
        GROUP_RULES[$i]="$port|$proto|$destination"
        echo -e "${YELLOW}[$i]${NC} $name: $port ($proto) -> $destination [$group_label]"
        ((i++))
    done < <(emit_dnat_rules)

    if [ ${#GROUP_RULES[@]} -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    while true; do
        echo ""
        read -r -e -p "Название группы: " group_name
        if [[ -n "$group_name" && ${#group_name} -le 100 && "$group_name" != *'|'* ]] && is_valid_utf8 "$group_name"; then break; fi
        echo -e "${RED}Название должно содержать от 1 до 100 символов и не может содержать |.${NC}"
    done

    read -r -p "Номера правил (например: 1 2 5-10 или all): " selection
    if ! parse_rule_selection "$selection" "${#GROUP_RULES[@]}"; then
        echo -e "${RED}Некорректный список правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    local updated=0
    local selected
    for selected in "${SELECTED_INDICES[@]}"; do
        IFS='|' read -r port proto destination <<< "${GROUP_RULES[$selected]}"
        if set_rule_group "$proto" "$port" "$destination" "$group_name"; then ((updated++)); fi
    done

    echo -e "${GREEN}[OK] В группу '$group_name' добавлено правил: $updated.${NC}"
    read -p "Нажмите Enter..."
}

remove_rules_from_group() {
    echo -e "\n${CYAN}--- Удаление правил из группы ---${NC}"
    select_existing_group || { read -p "Нажмите Enter..."; return; }
    declare -a MEMBER_RULES
    local i=1

    while IFS='|' read -r port _ proto destination name group; do
        [[ "$group" == "$SELECTED_GROUP" ]] || continue
        [[ -n "$name" ]] || name="Без имени"
        MEMBER_RULES[$i]="$port|$proto|$destination"
        echo -e "${YELLOW}[$i]${NC} $name: $port ($proto) -> $destination"
        ((i++))
    done < <(emit_dnat_rules)

    read -r -p "Номера правил для исключения (например: 1 2 5-10 или all): " selection
    if ! parse_rule_selection "$selection" "${#MEMBER_RULES[@]}"; then
        echo -e "${RED}Некорректный список правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    local removed=0
    local selected
    for selected in "${SELECTED_INDICES[@]}"; do
        IFS='|' read -r port proto destination <<< "${MEMBER_RULES[$selected]}"
        if delete_rule_group "$proto" "$port" "$destination"; then ((removed++)); fi
    done
    echo -e "${GREEN}[OK] Из группы '$SELECTED_GROUP' исключено правил: $removed.${NC}"
    read -p "Нажмите Enter..."
}

delete_group() {
    echo -e "\n${CYAN}--- Удаление группы ---${NC}"
    select_existing_group || { read -p "Нажмите Enter..."; return; }
    read -r -p "Удалить группу '$SELECTED_GROUP'? Сами правила останутся. (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "yes" ]]; then
        if delete_group_records "$SELECTED_GROUP"; then
            echo -e "${GREEN}[OK] Группа '$SELECTED_GROUP' удалена, правила сохранены.${NC}"
        else
            echo -e "${RED}[ERROR] Не удалось удалить группу.${NC}"
        fi
    fi
    read -p "Нажмите Enter..."
}

list_groups() {
    echo -e "\n${CYAN}--- Состав групп ---${NC}"
    local found=0
    local current_group=""

    while IFS='|' read -r group port name proto destination; do
        [[ -n "$group" ]] || continue
        found=1
        if [[ "$group" != "$current_group" ]]; then
            current_group="$group"
            echo -e "\n${MAGENTA}[$current_group]${NC}"
        fi
        [[ -n "$name" ]] || name="Без имени"
        echo -e "  $port ($proto) -> $destination — $name"
    done < <(
        emit_dnat_rules | while IFS='|' read -r port _ proto destination name group; do
            if [[ -n "$group" ]]; then printf '%s|%s|%s|%s|%s\n' "$group" "$port" "$name" "$proto" "$destination"; fi
        done | sort -t'|' -k1,1 -k2,2n
    )

    if [[ "$found" == 0 ]]; then echo -e "${RED}Нет созданных групп.${NC}"; fi
    echo ""
    read -p "Нажмите Enter..."
}

update_group_target_ip() {
    echo -e "\n${CYAN}--- Массовая замена конечного IP группы ---${NC}"
    select_existing_group || { read -p "Нажмите Enter..."; return; }
    declare -a GROUP_UPDATE_RULES
    local i=1

    while IFS='|' read -r port rule_index proto destination name group; do
        [[ "$group" == "$SELECTED_GROUP" ]] || continue
        display_name="$name"
        [[ -n "$display_name" ]] || display_name="Без имени"
        GROUP_UPDATE_RULES[$i]="$rule_index|$port|$proto|$destination|$name|$group"
        echo -e "${YELLOW}[$i]${NC} $display_name: $port ($proto) -> $destination"
        ((i++))
    done < <(emit_dnat_rules)

    if [ ${#GROUP_UPDATE_RULES[@]} -eq 0 ]; then
        echo -e "${RED}В группе нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    while true; do
        echo ""
        read -r -p "Новый конечный IPv4 для всей группы: " new_target_ip
        if is_valid_ipv4 "$new_target_ip"; then break; fi
        echo -e "${RED}Ошибка: введите корректный IPv4-адрес.${NC}"
    done

    read -r -p "Изменить IP у ${#GROUP_UPDATE_RULES[@]} правил группы '$SELECTED_GROUP' на $new_target_ip? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then return; fi

    local success=0
    local failed=0
    local record
    for record in "${GROUP_UPDATE_RULES[@]}"; do
        IFS='|' read -r rule_index port proto destination name group <<< "$record"
        if change_rule_target_ip "$rule_index" "$port" "$proto" "$destination" "$new_target_ip" "$name" "$group"; then
            ((success++))
        else
            ((failed++))
        fi
    done

    if ! netfilter-persistent save > /dev/null; then
        echo -e "${YELLOW}[WARNING] Изменения активны, но не удалось сохранить их для перезагрузки.${NC}"
    fi

    if [[ "$failed" == 0 ]]; then
        echo -e "${GREEN}[OK] IP группы '$SELECTED_GROUP' обновлён. Правил: $success.${NC}"
    else
        echo -e "${RED}[WARNING] Обновлено: $success, с ошибкой: $failed. Проверьте сообщения выше.${NC}"
    fi
    read -p "Нажмите Enter..."
}

groups_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}--- Управление группами ---${NC}"
        echo "1) Создать группу / добавить правила"
        echo "2) Убрать правила из группы"
        echo "3) Удалить группу"
        echo "4) Изменить конечный IP всей группы"
        echo "5) Посмотреть состав групп"
        echo "0) Вернуться в главное меню"
        echo "------------------------------------------------------"
        read -p "Ваш выбор: " group_choice
        case "$group_choice" in
            1) add_rules_to_group ;;
            2) remove_rules_from_group ;;
            3) delete_group ;;
            4) update_group_target_ip ;;
            5) list_groups ;;
            0) return ;;
            *) ;;
        esac
    done
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
        : > "$GROUPS_FILE"
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
        echo -e "4) ${CYAN}Управление группами${NC}"
        echo -e "5) Посмотреть активные правила"
        echo -e "6) ${RED}Удалить одно правило${NC}"
        echo -e "7) ${RED}Сбросить ВСЕ настройки${NC}"
        echo -e "8) ${YELLOW}Показать PROMO${NC}"
        echo -e "9) ${MAGENTA}📚 ИНСТРУКЦИЯ (Как настроить)${NC}" 
        echo -e "10) ${CYAN}Присвоить / изменить наименование правила${NC}"
        echo -e "11) Экспорт конфигурации hop в bundle"
        echo -e "12) Импорт конфигурации на чистый hop"
        echo -e "0) Выход"
        echo -e "------------------------------------------------------"
        read -p "Ваш выбор: " choice

        case $choice in
            1) with_routing_lock prepare_configure_rule "udp" "AmneziaWG" ;;
            2) with_routing_lock prepare_configure_rule "tcp" "VLESS" ;;
            3) with_routing_lock update_target_ip ;;
            4) with_routing_lock groups_menu ;;
            5) list_active_rules ;;
            6) with_routing_lock delete_single_rule ;;
            7) with_routing_lock flush_rules ;;
            8) show_promo ;;
            9) show_instructions ;;
            10) with_routing_lock rename_rule ;;
            11) export_config_menu ;;
            12) import_config_menu ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- PORTABLE SECOND-HOP CONFIGURATION (bundle v1) ---
# Shared with replace-hop/group; subshell closes the fd on every return/signal.
with_routing_lock() (
    command -v flock >/dev/null 2>&1 || {
        echo '[ERROR] Нужен flock (apt-get install util-linux).' >&2
        exit 1
    }
    exec 9>"$FAILOVER_LOCK_FILE" || exit 1
    flock -n 9 || {
        echo '[ERROR] routing занят (импорт/экспорт/редактирование/failover).' >&2
        exit 75
    }
    "$@"
)

bundle_cli() {
    with_routing_lock bundle_cli_locked "$@"
}

bundle_cli_locked() {
    local command="${1:-}" bundle="${2:-}" arg dry=0 no_install=0
    if [[ -z "$bundle" || "$bundle" == -* ]]; then
        echo "Использование: $0 $command FILE.tar.gz [--dry-run] [--no-install-deps]" >&2
        return 2
    fi
    for arg in "${@:3}"; do
        case "$command:$arg" in
            import-config:--dry-run|import-metadata:--dry-run|refresh-conntrack:--dry-run) dry=1 ;;
            refresh-conntrack:--udp-only) ;;
            import-config:--no-install-deps) no_install=1 ;;
            *) echo "[ERROR] Неизвестный аргумент: $arg" >&2; return 2 ;;
        esac
    done
    if ! command -v python3 >/dev/null 2>&1; then
        if [[ "$command" != import-config || "$dry" == 1 || "$no_install" == 1 ]]; then
            echo '[ERROR] Нужен Python 3.8+: apt-get update && apt-get install -y python3' >&2
            return 1
        fi
        [[ -f "$bundle" ]] || { echo '[ERROR] Bundle не найден.' >&2; return 1; }
        command -v apt-get >/dev/null 2>&1 || {
            echo '[ERROR] Автоустановка поддерживает Debian/Ubuntu (apt).' >&2; return 1;
        }
        echo '[*] Установка Python для проверки bundle...'
        DEBIAN_FRONTEND=noninteractive apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 || return 1
    fi
    python3 - "$@" <<'ROUTING_BUNDLE_PY'
import argparse
import hashlib
import gzip
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

# This program is embedded in routing.sh. Bundles contain DATA ONLY.
LIMIT = 8 * 1024 * 1024
MEMBERS = {'manifest.json', 'routes.json', 'names.db', 'groups.db'}
NAMES = Path('/var/lib/routing/names.db')
GROUPS = Path('/var/lib/routing/groups.db')
SYSCTL = Path('/etc/sysctl.d/99-z-routing-import.conf')
PERSIST = Path('/etc/iptables/rules.v4')
METADATA_BACKUPS = Path('/var/backups/routing-metadata')

def fail(message):
    raise ValueError(message)

def run(*args, input=None):
    p = subprocess.run(args, input=input, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, check=False)
    if p.returncode:
        fail('{}: {}'.format(shlex.join(args), p.stderr.strip() or p.stdout.strip()))
    return p.stdout

def valid_port(value):
    if not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]{0,4}', value):
        fail('Некорректный порт')
    if int(value) > 65535:
        fail('Порт больше 65535')
    return value

def valid_ip(value):
    if not isinstance(value, str):
        fail('IPv4 должен быть строкой')
    ip = ipaddress.IPv4Address(value)
    if ip.is_unspecified or ip.is_multicast or ip.is_loopback or str(ip) == '255.255.255.255':
        fail('Недопустимый destination IP: ' + str(ip))
    return str(ip)

def label(value, maximum=512):
    if not isinstance(value, str) or len(value) > maximum:
        fail('Некорректные метаданные')
    if any(ord(c) < 32 or ord(c) == 127 or c == '|' for c in value):
        fail('Управляющий символ или | в метаданных')
    return value

def validate_routes(routes):
    if not isinstance(routes, list) or not 1 <= len(routes) <= 10000:
        fail('Bundle должен содержать от 1 до 10000 маршрутов')
    seen = set()
    for r in routes:
        if not isinstance(r, dict) or set(r) != {'proto', 'in_port', 'ip', 'out_port'}:
            fail('Неизвестные поля маршрута')
        if r['proto'] not in ('tcp', 'udp'):
            fail('Поддерживаются только TCP/UDP')
        valid_port(r['in_port']); valid_port(r['out_port']); valid_ip(r['ip'])
        key = (r['proto'], r['in_port'])
        if key in seen:
            fail('Повторяющийся входной порт: ' + str(key))
        seen.add(key)
    return routes

def route_key(r):
    return (r['proto'], r['in_port'], r['ip'] + ':' + r['out_port'])

def read_db(raw, maximum=512):
    result = {}
    if any(b < 32 and b != 10 or b == 127 for b in raw):
        fail('Управляющий символ в БД метаданных')
    for line in raw.decode('utf-8').splitlines():
        if not line:
            continue
        fields = line.split('|')
        if len(fields) != 4:
            fail('Некорректная строка names.db/groups.db')
        proto, port, dest, value = fields
        if proto not in ('tcp', 'udp') or ':' not in dest:
            fail('Некорректный ключ метаданных')
        ip, out_port = dest.split(':', 1)
        valid_port(port); valid_ip(ip); valid_port(out_port); label(value, maximum)
        key = (proto, port, dest)
        if key in result:
            fail('Повторяющийся ключ метаданных')
        result[key] = value
    return result

def db_bytes(routes, values):
    return ''.join('|'.join((*route_key(r), values[route_key(r)])) + '\n'
                   for r in routes if values.get(route_key(r))).encode('utf-8')

def parse_source(snapshot):
    routes, comments, table = [], {}, ''
    for line in snapshot.splitlines():
        if line.startswith('*'):
            table = line[1:]
        if table != 'nat' or not line.startswith('-A PREROUTING '):
            continue
        tokens = shlex.split(line)
        fields, modules = {}, []
        i = 2
        while i < len(tokens):
            key = tokens[i]
            if i + 1 >= len(tokens):
                fail('Неподдерживаемое PREROUTING правило: ' + line)
            value = tokens[i + 1]
            if key == '-m':
                modules.append(value)
            elif key in ('-p', '--dport', '-j', '--to-destination', '--comment') and key not in fields:
                fields[key] = value
            else:
                fail('Экспорт остановлен: нестандартное PREROUTING правило: ' + line)
            i += 2
        required = {'-p', '--dport', '-j', '--to-destination'}
        if not required <= fields.keys() or fields['-j'] != 'DNAT':
            fail('Экспорт поддерживает только простые DNAT правила routing.sh: ' + line)
        if any(m not in (fields['-p'], 'comment') for m in modules):
            fail('Неподдерживаемый match module: ' + line)
        dest = fields['--to-destination'].split(':')
        if len(dest) != 2:
            fail('Нужен одиночный IPv4:port: ' + line)
        r = dict(proto=fields['-p'], in_port=fields['--dport'], ip=dest[0], out_port=dest[1])
        routes.append(r)
        comment = fields.get('--comment', '')
        if comment and not comment.startswith('routing:'):
            fail('Чужой comment в DNAT: ' + line)
        if comment:
            comments[route_key(r)] = label(comment[len('routing:'):])
    return validate_routes(routes), comments

def snapshot():
    # iptables-nft -S does NOT instantiate an absent table. A restore of a
    # snapshot that omits nat would therefore leave newly imported DNAT behind.
    # Represent absent touched tables explicitly, without changing the host.
    text = run('iptables-save')
    tables = {line[1:] for line in text.splitlines() if line.startswith('*')}
    for table, chains in (('nat', ('PREROUTING', 'INPUT', 'OUTPUT', 'POSTROUTING')),
                          ('filter', ('INPUT', 'FORWARD', 'OUTPUT'))):
        if table not in tables:
            text += '\n*' + table + '\n'
            text += ''.join(':' + chain + ' ACCEPT [0:0]\n' for chain in chains)
            text += 'COMMIT\n'
    return text

def clean_target(text):
    table = ''
    conflicts = []
    chains, populated, rules = {}, set(), []
    # Disabled UFW can leave unconditional FORWARD jumps to empty user chains.
    # Read the entire table before deciding: a target may have rules later in
    # iptables-save. Only the six known hooks below are eligible, never -g,
    # conditional jumps, undeclared chains, or chains containing any rule.
    ufw_forward_hooks = {
        'ufw-before-logging-forward', 'ufw-before-forward',
        'ufw-after-forward', 'ufw-after-logging-forward',
        'ufw-reject-forward', 'ufw-track-forward',
    }
    for line in text.splitlines():
        if line.startswith('*'):
            table = line[1:]
        elif line.startswith(':'):
            fields = line[1:].split()
            if len(fields) >= 2:
                chains[(table, fields[0])] = fields[1]
        elif line.startswith('-A '):
            tokens = shlex.split(line)
            populated.add((table, tokens[1]))
            rules.append((table, line, tokens))
    for table, line, tokens in rules:
        if table == 'filter' and tokens[1] == 'FORWARD':
            if (len(tokens) == 4 and tokens[2] == '-j'
                    and tokens[3] in ufw_forward_hooks
                    and chains.get(('filter', tokens[3])) == '-'
                    and ('filter', tokens[3]) not in populated):
                continue
        if table != 'filter' or tokens[1] == 'FORWARD':
            conflicts.append((table, line))
    if conflicts:
        details = '\n'.join('  [{}] {}'.format(table, rule) for table, rule in conflicts[:12])
        if len(conflicts) > 12:
            details += '\n  ... ещё {} правил'.format(len(conflicts) - 12)
        fail('Импорт остановлен: найдены существующие правила ({}) в проверяемых цепочках.\n'
             '{}\nПустые цепочки и стандартные политики сами по себе не мешают импорту.\n'
             'Для диагностики выполните iptables-save. Правила не удалены и не изменены.'
             .format(len(conflicts), details))
    for path in (NAMES, GROUPS):
        if path.exists() and path.stat().st_size:
            fail('На целевом сервере уже есть метаданные: ' + str(path))

def json_bytes(obj):
    return (json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode('utf-8')

def export_bundle(path):
    saved = snapshot()
    routes, comments = parse_source(saved)
    names = read_db(NAMES.read_bytes()) if NAMES.exists() else {}
    groups = read_db(GROUPS.read_bytes(), 100) if GROUPS.exists() else {}
    for key, value in comments.items():
        if not names.get(key):
            names[key] = value
    payload = {'routes.json': json_bytes(routes), 'names.db': db_bytes(routes, names),
               'groups.db': db_bytes(routes, groups)}
    manifest = {'format': 'routing-hop', 'version': 1,
                'created_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                'count': len(routes), 'sha256': {k: hashlib.sha256(v).hexdigest() for k, v in payload.items()}}
    payload['manifest.json'] = json_bytes(manifest)
    path = Path(path).absolute()
    if path.exists() or path.is_symlink():
        fail('Файл уже существует; выберите новое имя: ' + str(path))
    # Exclusive creation; never overwrite an earlier export, including via symlink.
    fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream, tarfile.open(fileobj=stream, mode='w:gz') as tar:
            for name, data in payload.items():
                entry = tarfile.TarInfo(name)
                entry.size, entry.mode, entry.mtime = len(data), 0o600, int(time.time())
                tar.addfile(entry, io.BytesIO(data))
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    print('[OK] Bundle: {} ({} правил)'.format(path, len(routes)))
    print('SHA256: ' + hashlib.sha256(path.read_bytes()).hexdigest())
    print('INPUT/OUTPUT, чужие FORWARD, sysctl, интерфейсы и watchdog-state в bundle не входят.')

def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail('Повторяющийся JSON-ключ')
        result[key] = value
    return result

def load_bundle(path):
    payload, total = {}, 0
    if Path(path).stat().st_size > LIMIT:
        fail('Сжатый bundle слишком большой')
    with gzip.open(path, 'rb') as stream:
        raw = stream.read(LIMIT + 65537)
    if len(raw) > LIMIT + 65536:
        fail('Распакованный bundle слишком большой')
    # No extract/extractall: paths, links, ownership and archive permissions never touch disk.
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as tar:
        for entry in tar:
            if entry.name not in MEMBERS or entry.name in payload or not entry.isfile():
                fail('Неизвестный/повторный файл или ссылка в bundle')
            total += entry.size
            if entry.size < 0 or total > LIMIT:
                fail('Bundle слишком большой (лимит 8 MiB без сжатия)')
            payload[entry.name] = tar.extractfile(entry).read(entry.size + 1)
    if set(payload) != MEMBERS:
        fail('Неполный bundle')
    manifest = json.loads(payload['manifest.json'], object_pairs_hook=no_duplicate_keys)
    if (not isinstance(manifest, dict) or manifest.get('format') != 'routing-hop'
            or type(manifest.get('version')) is not int or manifest['version'] != 1):
        fail('Неизвестная версия bundle')
    hashes = manifest.get('sha256')
    if not isinstance(hashes, dict) or set(hashes) != MEMBERS - {'manifest.json'}:
        fail('Некорректный manifest')
    for name, checksum in hashes.items():
        if hashlib.sha256(payload[name]).hexdigest() != checksum:
            fail('SHA256 не совпадает: ' + name)
    routes = validate_routes(json.loads(payload['routes.json'], object_pairs_hook=no_duplicate_keys))
    if type(manifest.get('count')) is not int or manifest['count'] != len(routes):
        fail('Количество правил не совпадает')
    keys = {route_key(r) for r in routes}
    for name, maximum in [('names.db', 512), ('groups.db', 100)]:
        db = read_db(payload[name], maximum)
        if not db.keys() <= keys:
            fail('Метаданные ссылаются на отсутствующий маршрут')
        payload[name] = db_bytes(routes, db)
    return routes, payload

def generate_plan(routes):
    nat, forward, destinations = [], [], {}
    for r in routes:
        proto, port, ip, out = r['proto'], r['in_port'], r['ip'], r['out_port']
        route = json.loads(run('ip', '-j', '-4', 'route', 'get', ip))
        if not route or route[0].get('type', 'unicast') != 'unicast':
            fail('Нет unicast-маршрута до ' + ip)
        iface = route[0].get('dev', '')
        if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', iface) or iface == 'lo':
            fail('Некорректный egress-интерфейс для ' + ip)
        destinations[ip] = iface
        nat.append('-A PREROUTING -p {} --dport {} -j DNAT --to-destination {}:{}'.format(proto, port, ip, out))
        # Keep original routing.sh FORWARD/MASQUERADE shape so replace-hop/group remain compatible.
        for rule in [
            '-A FORWARD -p {} -d {} --dport {} -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT'.format(proto, ip, out),
            '-A FORWARD -p {} -s {} --sport {} -m state --state ESTABLISHED,RELATED -j ACCEPT'.format(proto, ip, out)]:
            # One pair per route, including shared destinations: the existing
            # replace/delete functions remove exactly one pair for each DNAT.
            forward.append(rule)
    for iface in sorted(set(destinations.values())):
        nat.append('-A POSTROUTING -o {} -j MASQUERADE'.format(iface))
    return '*nat\n' + '\n'.join(nat) + '\nCOMMIT\n*filter\n' + '\n'.join(forward) + '\nCOMMIT\n', destinations

def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        fail('Отказ писать через ссылку/специальный файл: ' + str(path))
    fd, temp = tempfile.mkstemp(prefix='.' + path.name, dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)

def check_ufw():
    # ufw.service is oneshot/RemainAfterExit: systemd may say active (exited)
    # even after `ufw disable`. Inspect the firewall's own status instead.
    executable = shutil.which('ufw')
    if executable:
        result = subprocess.run([executable, 'status'], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, LC_ALL='C', LANG='C'),
                                timeout=15, check=False)
        if result.returncode:
            fail('Не удалось проверить UFW: ' + (result.stderr.strip() or result.stdout.strip()))
        lines = result.stdout.strip().splitlines()
        status = lines[0].strip() if lines else ''
        if status == 'Status: inactive':
            return
        if status == 'Status: active':
            fail('UFW включён (ufw status: active). Импорт требует выключенного UFW.')
        fail('Неизвестный ответ ufw status; проверьте состояние UFW вручную.')
    # Missing command is normal when UFW is not installed. An active orphaned
    # unit is ambiguous, however; do not silently bypass that condition.
    result = subprocess.run(['systemctl', 'is-active', '--quiet', 'ufw'], check=False)
    if result.returncode == 0:
        fail('ufw.service активен, но команда ufw не найдена; состояние firewall не проверено.')

def check_managers():
    if not Path('/run/systemd/system').is_dir():
        fail('Автоимпорт поддерживает Debian/Ubuntu с systemd')
    check_ufw()
    for service in ('firewalld', 'docker', 'nftables', 'hop-watchdog'):
        p = subprocess.run(['systemctl', 'is-active', '--quiet', service], check=False)
        if p.returncode == 0:
            fail('Сначала остановите конфликтующий сервис: ' + service)

def install_dependencies(allowed):
    packages = ('iptables', 'iproute2', 'procps', 'conntrack', 'iptables-persistent', 'netfilter-persistent')
    missing = []
    for package in packages:
        p = subprocess.run(['dpkg-query', '-W', '-f=${Status}', package],
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if p.returncode or p.stdout != 'install ok installed':
            missing.append(package)
    if not missing:
        return
    if not allowed:
        fail('Нужны пакеты: ' + ' '.join(missing))
    policy = Path('/usr/sbin/policy-rc.d')
    if policy.exists() or policy.is_symlink():
        fail('Найдена policy-rc.d: установите зависимости самостоятельно: ' + ' '.join(missing))
    # Do not allow package postinst to restore old rules or start/restart services.
    fd = os.open(str(policy), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o755)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write('#!/bin/sh\nexit 101\n')
        os.chmod(policy, 0o755)
        env = dict(os.environ, DEBIAN_FRONTEND='noninteractive')
        subprocess.run(['debconf-set-selections'], input=(
            'iptables-persistent iptables-persistent/autosave_v4 boolean false\n'
            'iptables-persistent iptables-persistent/autosave_v6 boolean false\n'),
            text=True, check=True, env=env)
        subprocess.run(['apt-get', 'update'], check=True, env=env)
        subprocess.run(['apt-get', 'install', '-y', '--no-install-recommends', *missing], check=True, env=env)
    finally:
        policy.unlink()

def save_backup(before):
    root = Path('/var/backups/routing-import')
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S-'), dir=str(root)))
    atomic_write(backup / 'iptables.save', before.encode())
    state = []
    for number, path in enumerate((NAMES, GROUPS, SYSCTL, PERSIST)):
        if path.is_symlink() or (path.exists() and not path.is_file()):
            fail('Нестандартный целевой файл: ' + str(path))
        entry = {'path': str(path), 'existed': path.exists(), 'file': str(number)}
        if path.exists():
            st = path.stat()
            entry.update(mode=st.st_mode & 0o777, uid=st.st_uid, gid=st.st_gid)
            atomic_write(backup / str(number), path.read_bytes())
        state.append(entry)
    atomic_write(backup / 'files.json', json_bytes(state))
    atomic_write(backup / 'ip_forward', run('sysctl', '-n', 'net.ipv4.ip_forward').encode())
    return backup, state

def restore_backup(backup, state):
    errors = []
    # Attempt EVERY rollback part even if an earlier part fails.
    operations = [lambda: run('iptables-restore', '-w', '10', input=(backup / 'iptables.save').read_text()),
                  lambda: run('sysctl', '-w', 'net.ipv4.ip_forward=' + (backup / 'ip_forward').read_text().strip())]
    def restore_file(entry):
        path = Path(entry['path'])
        if entry['existed']:
            atomic_write(path, (backup / entry['file']).read_bytes())
            os.chmod(path, entry['mode']); os.chown(path, entry['uid'], entry['gid'])
        else:
            path.unlink(missing_ok=True)
    operations.extend(lambda e=e: restore_file(e) for e in state)
    for operation in operations:
        try:
            operation()
        except BaseException as exc:
            errors.append(str(exc))
    if errors:
        print('[CRITICAL] Ошибки rollback: ' + '; '.join(errors), file=sys.stderr)
    else:
        print('[ROLLBACK OK] Правила, файлы и ip_forward восстановлены.', file=sys.stderr)

def verify_routes(routes):
    for r in routes:
        p, port, ip, out = r['proto'], r['in_port'], r['ip'], r['out_port']
        run('iptables', '-w', '10', '-t', 'nat', '-C', 'PREROUTING', '-p', p, '--dport', port,
            '-j', 'DNAT', '--to-destination', ip + ':' + out)
        run('iptables', '-w', '10', '-C', 'FORWARD', '-p', p, '-d', ip, '--dport', out,
            '-m', 'state', '--state', 'NEW,ESTABLISHED,RELATED', '-j', 'ACCEPT')
        run('iptables', '-w', '10', '-C', 'FORWARD', '-p', p, '-s', ip, '--sport', out,
            '-m', 'state', '--state', 'ESTABLISHED,RELATED', '-j', 'ACCEPT')

def input_output_rules(text):
    # Table order in iptables-save can change when nft creates a new table.
    # An absent built-in ACCEPT chain and a newly created empty ACCEPT chain
    # are equivalent; rule order WITHIN each existing chain remains significant.
    table = ''
    result = {(t, c): [':' + c + ' ACCEPT [0:0]']
              for t in ('*nat', '*filter') for c in ('INPUT', 'OUTPUT')}
    for line in text.splitlines():
        if line.startswith('*'):
            table = line
        match = re.match(r'^(:|-A )(INPUT|OUTPUT)(?: |$)', line)
        if match:
            key = (table, match[2])
            normalized = re.sub(r'\[[0-9]+:[0-9]+\]', '[0:0]', line)
            if match[1] == ':':
                result[key] = [normalized]
            else:
                result.setdefault(key, []).append(normalized)
    return result

def metadata_counts(payload):
    return (len(read_db(payload['names.db'])), len(read_db(payload['groups.db'], 100)))

def verify_metadata(payload):
    for path, name in ((NAMES, 'names.db'), (GROUPS, 'groups.db')):
        if not path.is_file() or path.read_bytes() != payload[name]:
            fail('Не удалось проверить записанные метаданные: ' + str(path))

def clear_conntrack(routes):
    # Match configure_rule(): flush OLD flow state by original incoming port,
    # not by the translated destination port. Existing UDP can keep a cached
    # NAT/no-NAT binding even after the new iptables rules are installed.
    # Never flush the whole conntrack table. Restrict this to IPv4 TCP/UDP ports
    # included in the imported routes; as in manual setup, clients may reconnect.
    errors, seen = [], set()
    env = dict(os.environ, LC_ALL='C', LANG='C')
    for route in routes:
        key = (route['proto'], route['in_port'])
        if key in seen:
            continue
        seen.add(key)
        selectors = ['-f', 'ipv4', '-p', key[0], '--dport', key[1]]
        deleted = subprocess.run(['conntrack', '-D', *selectors], text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if deleted.returncode == 0:
            continue
        # conntrack also returns 1 when nothing matched. Do not confuse that
        # with EPERM/kernel errors: a successful empty read confirms no old flow.
        if deleted.returncode == 1:
            remaining = subprocess.run(['conntrack', '-L', *selectors], text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            if remaining.returncode == 0 and not remaining.stdout.strip():
                continue
        errors.append('{}/{}: {}'.format(key[0], key[1], deleted.stderr.strip() or 'rc=' + str(deleted.returncode)))
    if errors:
        fail('Очистка conntrack не завершена. Она не изменяла правила и метаданные. '
             'Полный импорт повторять не нужно. Ошибки:\n' + '\n'.join(errors))
    print('[OK] Conntrack обработан для {} импортированных TCP/UDP-портов.'.format(len(seen)))

def refresh_conntrack(args):
    routes, _ = load_bundle(args.bundle)
    if args.udp_only:
        routes = [r for r in routes if r['proto'] == 'udp']
    if not routes:
        fail('В bundle нет выбранных маршрутов.')
    active, _ = parse_source(run('iptables-save', '-t', 'nat'))
    missing = {route_key(r) for r in routes} - {route_key(r) for r in active}
    if missing:
        fail('Сначала нужно восстановить сами DNAT-правила. Conntrack не изменён. Отсутствуют:\n' +
             '\n'.join('  ' + '|'.join(key) for key in sorted(missing)[:5]))
    verify_routes(routes)
    _, destinations = generate_plan(routes)
    for iface in set(destinations.values()):
        run('iptables', '-w', '10', '-t', 'nat', '-C', 'POSTROUTING', '-o', iface, '-j', 'MASQUERADE')
    if run('sysctl', '-n', 'net.ipv4.ip_forward').strip() != '1':
        fail('IPv4 forwarding выключен; conntrack не изменён.')
    print('[OK] Проверены DNAT/FORWARD/MASQUERADE и forwarding; выбранных маршрутов: {}'.format(len(routes)))
    if args.dry_run:
        print('[DRY-RUN OK] Conntrack, правила и метаданные не изменены.')
        return
    clear_conntrack(routes)
    print('[SUCCESS] Состояние соединений обновлено. Проверьте трафик клиента.')

def import_metadata(args):
    routes, payload = load_bundle(args.bundle)
    names_count, groups_count = metadata_counts(payload)
    print('[OK] Bundle: {} маршрутов, имён: {}, назначений групп: {}'.format(
        len(routes), names_count, groups_count), flush=True)
    if not names_count and not groups_count:
        fail('В bundle нет имён и групп для восстановления.')
    # Read only. Never run iptables-restore, install dependencies, or touch sysctl.
    live = run('iptables-save', '-t', 'nat')
    if not any(line.startswith('-A PREROUTING ') for line in live.splitlines()):
        fail('На сервере нет DNAT-маршрутов. Сначала нужен полный import-config; '
             'проверка bundle сама по себе не означает успешный импорт.')
    active, _ = parse_source(live)
    missing = {route_key(r) for r in routes} - {route_key(r) for r in active}
    if missing:
        fail('Маршруты сервера не совпадают с bundle. Метаданные не изменены. Отсутствуют:\n' +
             '\n'.join('  ' + '|'.join(key) for key in sorted(missing)[:5]))
    changes = []
    for path, name, maximum in ((NAMES, 'names.db', 512), (GROUPS, 'groups.db', 100)):
        if path.is_symlink() or (path.exists() and not path.is_file()):
            fail('Нестандартный файл метаданных: ' + str(path))
        original = path.read_bytes() if path.exists() else None
        current = read_db(original, maximum) if original is not None else {}
        incoming = read_db(payload[name], maximum)
        merged = dict(current)
        for key, value in incoming.items():
            if current.get(key) and current[key] != value:
                fail('Уже задано другое имя/группа в {} для {}. Перезаписи нет.'.format(name, '|'.join(key)))
            merged[key] = value
        if merged != current:
            data = ''.join('|'.join((*key, value)) + '\n' for key, value in merged.items()).encode('utf-8')
            changes.append((path, original, data))
    if args.dry_run:
        print('[DRY-RUN OK] Маршруты совпадают. Будет обновлено файлов: {}. Правила не меняются.'.format(len(changes)))
        return
    if not changes:
        print('[OK] Имена и группы из bundle уже сохранены. Изменений нет.')
        return
    METADATA_BACKUPS.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S-'), dir=str(METADATA_BACKUPS)))
    state = []
    for path, original, data in changes:
        entry = {'path': str(path), 'file': path.name, 'existed': original is not None}
        if original is not None:
            stat = path.stat()
            entry.update(mode=stat.st_mode & 0o777, uid=stat.st_uid, gid=stat.st_gid)
            atomic_write(backup / path.name, original)
        state.append(entry)
    atomic_write(backup / 'files.json', json_bytes(state))
    print('[BACKUP] ' + str(backup), flush=True)
    try:
        for path, original, data in changes:
            atomic_write(path, data)
        for path, original, data in changes:
            if path.read_bytes() != data:
                fail('Ошибка проверки записанного файла: ' + str(path))
    except BaseException:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        errors = []
        for entry in state:
            try:
                path = Path(entry['path'])
                if entry['existed']:
                    atomic_write(path, (backup / entry['file']).read_bytes())
                    os.chmod(path, entry['mode']); os.chown(path, entry['uid'], entry['gid'])
                else:
                    path.unlink(missing_ok=True)
            except BaseException as exc:
                errors.append(str(exc))
        if errors:
            print('[CRITICAL] Ошибки отката метаданных: ' + '; '.join(errors), file=sys.stderr)
        else:
            print('[ROLLBACK OK] Предыдущее состояние метаданных восстановлено.', file=sys.stderr)
        raise
    print('[SUCCESS] Метаданные восстановлены: имён {}, назначений групп {}. '
          'Правила и sysctl не изменялись.'.format(names_count, groups_count))

def import_bundle(args):
    routes, payload = load_bundle(args.bundle)
    names_count, groups_count = metadata_counts(payload)
    print('[OK] Bundle проверен: {} правил, имён: {}, назначений групп: {}'.format(
        len(routes), names_count, groups_count), flush=True)
    if args.dry_run:
        for r in routes:
            print('{} {} -> {}:{}'.format(r['proto'], r['in_port'], r['ip'], r['out_port']))
        missing = [x for x in ('iptables', 'iptables-save', 'iptables-restore', 'ip', 'sysctl') if not shutil.which(x)]
        if missing:
            fail('Bundle корректен; проверка хоста не завершена, нужны: ' + ', '.join(missing))
        check_managers()
        clean_target(snapshot())
        plan, destinations = generate_plan(routes)
        run('iptables-restore', '-w', '10', '--test', '--noflush', input=plan)
        print(plan)
        print('[DRY-RUN OK] Системные настройки/пакеты/правила не изменены.')
        return
    if not shutil.which('apt-get') or not shutil.which('dpkg-query'):
        fail('Автоимпорт поддерживает Debian/Ubuntu (apt)')
    check_managers()
    if shutil.which('iptables-save') and shutil.which('iptables'):
        clean_target(snapshot())
    install_dependencies(not args.no_install_deps)
    before = snapshot()
    clean_target(before)
    plan, destinations = generate_plan(routes)
    run('iptables-restore', '-w', '10', '--test', '--noflush', input=plan)
    backup, state = save_backup(before)
    enabled = subprocess.run(['systemctl', 'is-enabled', 'netfilter-persistent.service'],
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip()
    if enabled not in ('enabled', 'disabled'):
        fail('Неожиданное состояние netfilter-persistent: ' + enabled)
    atomic_write(backup / 'service-enabled', (enabled + '\n').encode())
    atomic_write(backup / 'import.rules', plan.encode())
    print('[BACKUP] ' + str(backup), flush=True)
    try:
        # No chain declarations, no policies, no flush: existing INPUT/OUTPUT are retained.
        run('iptables-restore', '-w', '10', '--noflush', input=plan)
        atomic_write(NAMES, payload['names.db'])
        atomic_write(GROUPS, payload['groups.db'])
        atomic_write(SYSCTL, b'# routing.sh import: only the required routing setting\nnet.ipv4.ip_forward=1\n')
        run('sysctl', '-w', 'net.ipv4.ip_forward=1')
        verify_routes(routes)
        for iface in set(destinations.values()):
            run('iptables', '-w', '10', '-t', 'nat', '-C', 'POSTROUTING', '-o', iface, '-j', 'MASQUERADE')
        after = snapshot()
        if input_output_rules(before) != input_output_rules(after):
            fail('INPUT/OUTPUT изменились во время импорта')
        if run('sysctl', '-n', 'net.ipv4.ip_forward').strip() != '1':
            fail('Не удалось включить forwarding')
        atomic_write(PERSIST, after.encode())
        run('iptables-restore', '-w', '10', '--test', input=PERSIST.read_text())
        run('systemctl', 'enable', 'netfilter-persistent.service')
        verify_metadata(payload)
    except BaseException:
        # Prevent a second Ctrl-C/SIGTERM from aborting rollback.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        restore_backup(backup, state)
        if enabled == 'disabled':
            try:
                run('systemctl', 'disable', 'netfilter-persistent.service')
            except Exception as exc:
                print('[CRITICAL] Не удалось восстановить enable-state: ' + str(exc), file=sys.stderr)
        raise
    # Commit configuration BEFORE invalidating flow state, which cannot be
    # restored by an iptables snapshot. An error here must not undo valid rules
    # or remove metadata; report explicitly that configuration is already saved.
    print('[APPLIED] Правила и метаданные проверены и сохранены; обновляю conntrack.', flush=True)
    clear_conntrack(routes)
    print('[SUCCESS] Импорт завершён; правила сохранены для загрузки через netfilter-persistent.')
    print('[OK] Записано и проверено: имён {}, назначений групп {}.'.format(names_count, groups_count))
    print('Проверьте реальный трафик через новый hop, затем добавьте его в standby на ingress.')

def main():
    parser = argparse.ArgumentParser(description='Перенос конфигурации routing.sh на чистый second-hop')
    sub = parser.add_subparsers(dest='command', required=True)
    export = sub.add_parser('export-config')
    export.add_argument('bundle')
    imp = sub.add_parser('import-config')
    imp.add_argument('bundle')
    imp.add_argument('--dry-run', action='store_true')
    imp.add_argument('--no-install-deps', action='store_true')
    meta = sub.add_parser('import-metadata', help='Восстановить имена и группы для существующих маршрутов')
    meta.add_argument('bundle')
    meta.add_argument('--dry-run', action='store_true')
    refresh = sub.add_parser('refresh-conntrack', help='Обновить conntrack для существующих маршрутов из bundle')
    refresh.add_argument('bundle')
    refresh.add_argument('--dry-run', action='store_true')
    refresh.add_argument('--udp-only', action='store_true')
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise InterruptedError('Получен сигнал ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    os.umask(0o077)
    try:
        if args.command == 'export-config':
            export_bundle(args.bundle)
        elif args.command == 'import-metadata':
            import_metadata(args)
        elif args.command == 'refresh-conntrack':
            refresh_conntrack(args)
        else:
            import_bundle(args)
    except (Exception, KeyboardInterrupt) as exc:
        print('[ERROR] ' + str(exc), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
ROUTING_BUNDLE_PY
}

export_config_menu() {
    local bundle
    read -r -p 'Файл bundle [/root/hop-config.tar.gz]: ' bundle
    bundle_cli export-config "${bundle:-/root/hop-config.tar.gz}"
    read -r -p 'Нажмите Enter...'
}

import_config_menu() {
    local bundle answer
    read -r -p 'Путь к bundle: ' bundle
    [[ -n "$bundle" ]] || return
    echo 'Сначала проверка bundle и чистоты сервера (нужны Python и iptables).'
    if ! bundle_cli import-config "$bundle" --dry-run; then
        echo 'Предварительная проверка не завершена. Импорт повторит проверки;'
        echo 'недостающие зависимости будут установлены, конфликтующие правила приведут к отказу.'
    fi
    read -r -p 'Запустить импорт? Введите IMPORT: ' answer
    if [[ "$answer" == IMPORT ]]; then
        bundle_cli import-config "$bundle"
    fi
    read -r -p 'Нажмите Enter...'
}

prepare_configure_rule() {
    prepare_system || return 1
    configure_rule "$@"
}

# --- ЗАПУСК ---
check_root

# Неинтерактивный режим нужен watchdog'у. Он намеренно не запускает
# prepare_system/show_promo/menu и поэтому не может зависнуть на вводе.
if [[ $# -gt 0 ]]; then
    case "$1" in
        export-config|import-config|import-metadata|refresh-conntrack)
            bundle_cli "$@"
            exit $?
            ;;
        replace-hop)
            shift
            replace_hop_cli "$@"
            exit $?
            ;;
        replace-group)
            shift
            replace_group_cli "$@"
            exit $?
            ;;
        --help|-h|help)
            cli_usage
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] Неизвестная команда: $1${NC}" >&2
            cli_usage >&2
            exit 2
            ;;
    esac
fi

# System preparation runs when adding a route; export/import have their own checks.
show_promo_once
show_menu
