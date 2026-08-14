#!/usr/bin/env bash
# Где именно теряется соединение с сервером: на вашем Mac, у провайдера
# или всё-таки на сервере. Ничего не меняет, только смотрит.
set -u

IP="143.110.157.152"
REPORT="$HOME/Desktop/server-set.txt"
[ -d "$HOME/Desktop" ] || REPORT="$HOME/server-set.txt"

say() { echo "$@"; echo "$@" >> "$REPORT"; }
rule() { say "--------------------------------------------------"; }

: > "$REPORT"
say "Проверка сети — $(date)"
rule

# Возвращает "СОСТОЯНИЕ|секунды|первые байты ответа".
#
# Ключевая мысль: успешный TCP-хендшейк сам по себе НИЧЕГО не доказывает —
# его подделывает и VPN на компьютере, и оборудование провайдера. Доказывают
# только пришедшие в ответ данные. Поэтому различаем три исхода:
#   ОТКАЗ   — хост честно ответил «порт закрыт», сеть до него живая
#   ТИШИНА  — соединились, но за 5 секунд не пришло ни байта
#   ТАЙМАУТ — соединиться не удалось вовсе, пакеты пропали молча
#
# Пробуем через встроенный в bash /dev/tcp, без nc и timeout: на разных
# системах у них слишком разные флаги, а bash есть везде.
probe() {
  local h="$1" p="$2" d t0 el st data i
  d="$(mktemp -d)" || { echo "ОШИБКА|0|"; return; }
  t0=$SECONDS
  (
    if ! exec 3<>"/dev/tcp/$h/$p" 2>/dev/null; then
      echo refused > "$d/state"
    else
      echo connected > "$d/state"
      IFS= read -r -t 5 line <&3 2>/dev/null && printf '%s' "$line" > "$d/data"
    fi
    : > "$d/done"
  ) &
  pid=$!
  i=0
  while [ ! -f "$d/done" ] && [ "$i" -lt 120 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  el=$((SECONDS - t0))
  st="$(cat "$d/state" 2>/dev/null)"
  data=""
  [ -f "$d/data" ] && data="$(LC_ALL=C tr -cd '[:print:]' < "$d/data" | cut -c1-40)"
  rm -rf "$d"
  if [ "$st" = "refused" ]; then      echo "ОТКАЗ|$el|"
  elif [ -z "$st" ]; then             echo "ТАЙМАУТ|$el|"
  elif [ -n "$data" ]; then           echo "ДАННЫЕ|$el|$data"
  else                                echo "ТИШИНА|$el|"
  fi
}

# Результат кладём в STATE, а не отдаём через stdout: иначе подстановка
# команды проглотит и печать на экран.
STATE=""
show() {
  local label="$1" h="$2" p="$3" r
  r="$(probe "$h" "$p")"
  # Без printf-выравнивания: он считает байты, а в кириллице их по два
  # на символ, и колонки всё равно разъезжаются.
  say "  $label: $(echo "$r" | awk -F'|' '{printf "%s (%sс) %s", $1, $2, $3}')"
  STATE="$(echo "$r" | awk -F'|' '{print $1}')"
}

say "1. КОНТРОЛЬНЫЕ ТОЧКИ — так выглядит нормальная сеть"
say ""
show 'GitHub, порт 22'           github.com     22;   C_GH22="$STATE"
show 'GitHub, порт 443'          ssh.github.com 443;  C_GH443="$STATE"
show 'Cloudflare, закрытый порт' 1.1.1.1        9999; C_CF="$STATE"
say ""
say "2. ВАШ СЕРВЕР"
say ""
show 'сервер, порт 22'     "$IP" 22;   S_22="$STATE"
show 'сервер, порт 443'    "$IP" 443;  S_443="$STATE"
show 'сервер, ПУСТОЙ порт' "$IP" 9999; S_DEAD="$STATE"

say ""
say "3. ICMP"
PING="нет"
# -W у ping означает разное: на macOS миллисекунды, на Linux секунды.
if [ "$(uname -s)" = "Darwin" ]; then
  ping -c 3 -W 3000 "$IP" >/dev/null 2>&1 && PING="да"
else
  ping -c 3 -W 3 "$IP" >/dev/null 2>&1 && PING="да"
fi
say "  ping сервера: $PING"
{ echo "--- traceroute ---"; traceroute -n -w 1 -q 1 -m 12 "$IP" 2>&1; } >> "$REPORT"

say ""
say "4. ЧТО НА ЭТОМ MAC МОЖЕТ ПЕРЕХВАТЫВАТЬ ТРАФИК"
TUN="$(ifconfig 2>/dev/null | grep -oE '^(utun|ipsec|ppp|tun|tap)[0-9]*' | tr '\n' ' ')"
say "  туннельные интерфейсы: ${TUN:-нет}"
APPS="$(pgrep -fl 'Tailscale|WARP|AdGuard|Clash|[Vv]2[Rr]ay|[Xx]ray|sing-box|OpenVPN|WireGuard|Little Snitch|Proxyman|Charles|Surge|Outline|NekoRay|Hiddify|Shadowsocks|Nord|ExpressVPN|Proton' 2>/dev/null | sed 's/^[0-9]* *//' | sort -u | head -8)"
if [ -n "$APPS" ]; then
  say "  запущены VPN/прокси-программы:"
  echo "$APPS" | while read -r a; do say "    $a"; done
else
  say "  VPN/прокси-программы: не найдены"
fi
PROXY="$(scutil --proxy 2>/dev/null | grep -E 'Enable.*: 1' | tr -d ' ' | tr '\n' ' ')"
say "  системные прокси: ${PROXY:-выключены}"
{ echo "--- scutil --proxy ---"; scutil --proxy 2>&1; echo "--- scutil --nc list ---"; scutil --nc list 2>&1; } >> "$REPORT"
if grep -qiE '^[[:space:]]*(ProxyCommand|ProxyJump)' "$HOME/.ssh/config" 2>/dev/null; then
  say "  ВНИМАНИЕ: в ~/.ssh/config есть ProxyCommand/ProxyJump:"
  grep -inE '^[[:space:]]*(ProxyCommand|ProxyJump)' "$HOME/.ssh/config" | while read -r l; do say "    $l"; done
else
  say "  ProxyCommand в ~/.ssh/config: нет"
fi

# ------------------------------------------------------------- вердикт ---
rule
say "ВЕРДИКТ"
rule

CONTROLS_OK="no"
[ "$C_GH22" = "ДАННЫЕ" ] && [ "$C_GH443" = "ДАННЫЕ" ] && CONTROLS_OK="yes"

if [ "$S_22" = "ДАННЫЕ" ] || [ "$S_443" = "ДАННЫЕ" ]; then
  say "СЕРВЕР ОТВЕЧАЕТ. Соединение есть — запустите mac-setup.sh, он всё настроит."

elif [ "$S_DEAD" = "ТИШИНА" ] && [ "$C_CF" = "ТИШИНА" ]; then
  say "ТРАФИК ПЕРЕХВАТЫВАЕТСЯ НА ЭТОМ MAC (или на вашем роутере)."
  say ""
  say "Доказательство: «подключились» и к пустому порту сервера, и к закрытому"
  say "порту Cloudflare. Так не бывает — на закрытый порт нормальная сеть"
  say "отвечает отказом. Значит соединения принимает программа у вас"
  say "на компьютере, а не удалённый хост."
  say ""
  say "Что делать: выключить VPN / прокси / сетевой фильтр (список выше,"
  say "пункт 4) и запустить эту проверку снова."

elif [ "$S_DEAD" = "ТИШИНА" ] && [ "$CONTROLS_OK" = "yes" ]; then
  say "IP СЕРВЕРА ЗАБЛОКИРОВАН ПО ДОРОГЕ — сам сервер тут не виноват."
  say ""
  say "Доказательство: до GitHub данные доходят и по 22, и по 443 — сеть"
  say "и SSH у вас исправны. А у сервера «открыт» даже пустой порт 9999,"
  say "где заведомо ничего не слушает: хендшейк подделывает оборудование"
  say "по пути, дальше пакеты выбрасываются. Плюс не проходит ping."
  say ""
  say "Адрес $IP принадлежит DigitalOcean (диапазон 143.110.128.0/17)."
  say "Диапазоны DigitalOcean часто целиком блокируют на уровне провайдера."
  say ""
  say "Переносом SSH на 443 это не лечится: блокировка по адресу, а не по порту."
  say "Именно поэтому «перенесли на 443, и всё равно ничего»."
  say ""
  say "Что делать — по возрастанию усилий:"
  say "  1. Включить любой VPN на Mac и запустить эту проверку снова."
  say "     Заработало — значит диагноз верный."
  say "  2. Проверить с телефона в режиме модема: другой оператор,"
  say "     другая блокировка."
  say "  3. Постоянное решение без VPN — Tailscale на сервере."
  say "     Ставится через Web Console DigitalOcean, SSH для этого не нужен."
  say "     Подробности: файл BLOKIROVKA-IP.md"

elif [ "$S_22" = "ТАЙМАУТ" ] && [ "$S_DEAD" = "ТАЙМАУТ" ] && [ "$CONTROLS_OK" = "yes" ]; then
  say "ПАКЕТЫ ДО СЕРВЕРА МОЛЧА ПРОПАДАЮТ."
  say ""
  say "Похоже на фаервол: либо облачный фаервол DigitalOcean, либо ufw"
  say "на сервере, либо ваш IP забанен fail2ban."
  say ""
  say "Чинить с сервера: DigitalOcean → Web Console → root → server-repair.sh"
  say "И проверьте в панели DO: Networking → Firewalls."

elif [ "$S_22" = "ОТКАЗ" ] || [ "$S_443" = "ОТКАЗ" ]; then
  say "ДО СЕРВЕРА ДОХОДИМ, НО SSH НА НЁМ НЕ ЗАПУЩЕН."
  say ""
  say "Отказ означает, что сервер честно ответил «здесь закрыто» — сеть в порядке."
  say "Чинить с сервера: DigitalOcean → Web Console → root → server-repair.sh"

elif [ "$CONTROLS_OK" != "yes" ]; then
  say "ПРОБЛЕМА ШИРЕ, ЧЕМ ЭТОТ СЕРВЕР."
  say ""
  say "Даже до GitHub данные не доходят нормально, а он точно работает."
  say "Проверьте интернет, выключите VPN и запустите проверку снова."

else
  say "КАРТИНА НЕОДНОЗНАЧНАЯ — нужен полный лог."
  say "Пришлите файл $REPORT"
fi

rule
say "Полный лог (с traceroute и настройками прокси): $REPORT"
echo
read -r -p "Нажмите Enter, чтобы закрыть..." _ || true
echo
