Routing for AWG \ VLESS
# 🌊 Route Traffic Manager

Универсальный скрипт для настройки каскадных соединений, переадресации трафика (NAT) и ускорения сети на Linux.

Идеальное решение от VPN-сервиса WieldVPN для создания "мостов" к VPN (AmneziaWG, WireGuard) и Proxy (VLESS, XRay).

![Bash](https://img.shields.io/badge/Language-Bash-green)
![System](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian-orange)
![License](https://img.shields.io/badge/License-MIT-blue)

---

##  Возможности

* High Speed Core: работа базируется на iptables (Kernel NAT). Отсутствие лишних процессов гарантирует, что скорость ограничивается только пропускной способностью вашего сервера.
* BBR Turbo: система автоматически активирует алгоритм Google BBR, что позволяет выжать максимум из TCP-соединений.
* Универсальность протоколов:
    * Поддержка UDP (AmneziaWG, WireGuard).
    * Поддержка TCP (VLESS, VMess, Reality).

* Мульти-туннелирование: возможность запускать 2, 5 или даже 10 параллельных соединений на разных портах одновременно.
* Интеллектуальная конфигурация:
    * Автоматическая настройка правил в фаерволе UFW.
    * Оптимизация параметров сети (отключение `rp_filter` для корректной работы VPN).
    * Гарантированное сохранение всех правил после перезагрузки сервера через `netfilter-persistent`.

* Интуитивное управление: удобное меню для мониторинга активных правил, выборочного удаления или полной очистки конфигурации.

---

##  Быстрая установка

Подключитесь к вашему VPS серверу в РФ (Ubuntu/Debian) и выполните одну команду, далее просто следуйте инструкциям:

```bash
wget -O routing.sh https://raw.githubusercontent.com/GRTUBORG/routing/refs/heads/master/routing.sh && chmod +x routing.sh && ./routing.sh
