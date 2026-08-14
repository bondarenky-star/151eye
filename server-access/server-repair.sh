#!/usr/bin/env bash
# Восстановление SSH на сервере. Запускать НА САМОМ СЕРВЕРЕ от root:
#   DigitalOcean → дроплет agents-... → Access → Launch Web Console
#
# Что делает:
#   - поднимает sshd одновременно на портах 22 и 443
#   - открывает оба порта в ufw
#   - снимает баны fail2ban
#   - восстанавливает authorized_keys пользователя admin
#
# Безопасно запускать повторно.
set -u

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
ok()   { echo "${GRN}  ✓${OFF} $*"; }
warn() { echo "${YEL}  !${OFF} $*"; }
bad()  { echo "${RED}  ✗${OFF} $*"; }
head_() { echo; echo "=== $* ==="; }

if [ "$(id -u)" != "0" ]; then
  echo "Запустите от root:  sudo bash $0"
  exit 1
fi

RESCUE="no"
FORCE="no"
for a in "$@"; do
  [ "$a" = "--rescue" ] && RESCUE="yes"
  [ "$a" = "--force" ]  && FORCE="yes"
done

# ПРЕДОХРАНИТЕЛЬ. На этом сервере порты 22/443/2222 подняты через ssh.socket,
# и это рабочая настройка. Скрипт же переводит SSH в режим обычной службы —
# если запустить его «на всякий случай», он сломает то, что работает.
# Поэтому: сначала смотрим, не всё ли уже хорошо.
if [ "$FORCE" != "yes" ]; then
  L22="no"; L443="no"
  ss -tln 2>/dev/null | grep -qE ':22\b'  && L22="yes"
  ss -tln 2>/dev/null | grep -qE ':443\b' && L443="yes"
  if [ "$L22" = "yes" ] && [ "$L443" = "yes" ]; then
    echo
    echo "${GRN}SSH УЖЕ СЛУШАЕТ И 22, И 443 — ремонт не нужен.${OFF}"
    echo
    ss -tlnp 2>/dev/null | grep -E ':(22|443|2222)\b' | sed 's/^/  /'
    echo
    echo "Если доступа всё равно нет, причина не в настройке SSH. Самая частая —"
    echo "нехватка памяти: сервер уходит в свап и не успевает ответить на новое"
    echo "соединение в отведённое время. Снаружи это выглядит как «подключились,"
    echo "но SSH молчит». Проверьте:"
    echo
    echo "    free -h; uptime"
    echo
    echo "Если свободной памяти почти нет, а load average в разы больше числа"
    echo "ядер — запускайте server-memory-fix.sh, а не этот скрипт."
    echo
    echo "Если всё-таки нужно перевести SSH в режим обычной службы, добавьте"
    echo "--force. Учтите: это отключит socket-активацию."
    echo
    exit 0
  fi
fi

# --------------------------------------------------------- что сейчас есть ---
head_ "СОСТОЯНИЕ ДО РЕМОНТА"
echo "-- systemd --"
systemctl is-active ssh.service  2>/dev/null | sed 's/^/  ssh.service: /'
systemctl is-enabled ssh.service 2>/dev/null | sed 's/^/  ssh.service enabled: /'
systemctl is-active ssh.socket   2>/dev/null | sed 's/^/  ssh.socket:  /'
systemctl is-enabled ssh.socket  2>/dev/null | sed 's/^/  ssh.socket enabled:  /'
echo "-- кто слушает --"
ss -tlnp 2>/dev/null | grep -E ':(22|443|2222)\b' || echo "  никто не слушает 22/443/2222"
echo "-- ufw --"
ufw status 2>/dev/null | head -20 || echo "  ufw не установлен"
echo "-- fail2ban --"
fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || echo "  jail sshd не активен"

# --------------------------------------------------------------- ключи ---
# Если authorized_keys потёрли или испортили права, вход невозможен даже
# при живом sshd. Кладём оба известных публичных ключа.
head_ "1. КЛЮЧИ ДОСТУПА"
AUTH_DIR="/home/admin/.ssh"
AUTH="$AUTH_DIR/authorized_keys"
mkdir -p "$AUTH_DIR"
touch "$AUTH"
for K in \
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDK+pPutPNMQJgJz7yQooYCTMGa/9Tb+VAOHx54pntrA arsen-do-vps" \
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHFIkUA1oTsfCs04tpL9PUKIxuZvNryh8WpiQPj9k9sG Mars"
do
  FP="$(echo "$K" | awk '{print $2}')"
  if grep -qF "$FP" "$AUTH"; then
    ok "ключ $(echo "$K" | awk '{print $3}') уже есть"
  else
    echo "$K" >> "$AUTH"
    ok "ключ $(echo "$K" | awk '{print $3}') добавлен"
  fi
done
chown -R admin:admin "$AUTH_DIR"
chmod 700 "$AUTH_DIR"
chmod 600 "$AUTH"
ok "права на ~/.ssh восстановлены (700 / 600)"

# ------------------------------------------------------------ sshd_config ---
# Настройки кладём отдельным файлом в sshd_config.d, а не правим основной:
# так ничего не ломается и легко откатить удалением одного файла.
head_ "2. КОНФИГ SSHD (порты 22 и 443)"
MAIN="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN="$DROPIN_DIR/10-ports.conf"
mkdir -p "$DROPIN_DIR"

STAMP="$(date +%s)"
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN"; then
  cp "$MAIN" "$MAIN.backup.$STAMP"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n%s\n' "$(cat "$MAIN")" > "$MAIN"
  warn "в sshd_config не было Include — добавил в начало"
fi

# Директива Port в sshd НАКАПЛИВАЕТСЯ, а не переопределяется. Если оставить
# старые Port где-то ещё, sshd попытается занять один и тот же порт дважды
# и засыплет журнал ошибками привязки. Поэтому все прежние Port гасим,
# а единственным источником портов делаем наш файл.
if grep -qE '^[[:space:]]*Port[[:space:]]' "$MAIN"; then
  cp "$MAIN" "$MAIN.backup.$STAMP" 2>/dev/null
  sed -i -E 's/^[[:space:]]*(Port[[:space:]])/#\1/' "$MAIN"
  ok "старые строки Port в sshd_config закомментированы (копия: $MAIN.backup.$STAMP)"
fi
for f in "$DROPIN_DIR"/*.conf; do
  [ -e "$f" ] || continue
  [ "$f" = "$DROPIN" ] && continue
  if grep -qE '^[[:space:]]*Port[[:space:]]' "$f"; then
    cp "$f" "$f.backup.$STAMP"
    sed -i -E 's/^[[:space:]]*(Port[[:space:]])/#\1/' "$f"
    ok "старые строки Port убраны из $(basename "$f")"
  fi
done

cat > "$DROPIN" << 'EOF'
# Восстановление доступа: SSH слушает и обычный 22, и 443 —
# 443 нужен потому, что многие корпоративные сети и VPN режут исходящий 22.
Port 22
Port 443
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitRootLogin prohibit-password
EOF
ok "записан $DROPIN"

if sshd -t 2>/tmp/sshd-test.err; then
  ok "конфиг валиден (sshd -t)"
else
  bad "конфиг НЕвалиден:"
  sed 's/^/    /' /tmp/sshd-test.err
  rm -f "$DROPIN"
  bad "изменения откачены, sshd не трогаю. Разберитесь с ошибкой выше."
  exit 1
fi

# ----------------------------------------------------------- запуск sshd ---
# Ключевой момент. В Ubuntu 24.04 ssh по умолчанию запускается через
# ssh.socket, и тогда порты берутся ИЗ СОКЕТА, а строчки Port в sshd_config
# просто игнорируются. Именно на этом обычно всё и ломается при переезде
# на 443. Поэтому переводим SSH в обычный режим службы.
head_ "3. ЗАПУСК SSHD"
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
  systemctl stop ssh.socket 2>/dev/null
  systemctl disable ssh.socket 2>/dev/null
  ok "socket-активация отключена (иначе порт 443 из конфига игнорируется)"
fi
systemctl unmask ssh.service 2>/dev/null
systemctl enable ssh.service >/dev/null 2>&1
if systemctl restart ssh.service; then
  ok "ssh.service перезапущен"
else
  bad "ssh.service не стартовал. Последние строки журнала:"
  journalctl -u ssh.service -n 20 --no-pager | sed 's/^/    /'
  exit 1
fi

# ------------------------------------------------------------------ ufw ---
head_ "4. ФАЕРВОЛ"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp  >/dev/null 2>&1 && ok "22/tcp разрешён"
  ufw allow 443/tcp >/dev/null 2>&1 && ok "443/tcp разрешён"
  [ "$RESCUE" = "yes" ] && ufw allow 2222/tcp >/dev/null 2>&1 && ok "2222/tcp разрешён (запасной)"
  ufw --force enable >/dev/null 2>&1
  ufw status | sed 's/^/  /'
else
  warn "ufw не установлен — пропускаю"
fi

# ------------------------------------------------------------- fail2ban ---
# Забаненный домашний IP выглядит для пользователя ровно как «сервер умер»:
# пакеты дропаются молча, без всякой ошибки.
head_ "5. FAIL2BAN — СНИМАЮ БАНЫ"
if command -v fail2ban-client >/dev/null 2>&1; then
  BANNED="$(fail2ban-client get sshd banip 2>/dev/null)"
  if [ -n "$BANNED" ]; then
    echo "  Были забанены: $BANNED"
  else
    echo "  Забаненных адресов нет"
  fi
  fail2ban-client unban --all >/dev/null 2>&1 && ok "все баны сняты"
  systemctl restart fail2ban 2>/dev/null && ok "fail2ban перезапущен"
else
  warn "fail2ban не установлен — пропускаю"
fi

# ------------------------------------------------------ запасной sshd ---
if [ "$RESCUE" = "yes" ]; then
  head_ "6. ЗАПАСНОЙ SSHD НА 2222"
  pkill -f 'sshd.*rescue' 2>/dev/null
  /usr/sbin/sshd -o Port=2222 -o PidFile=/run/sshd-rescue.pid 2>/dev/null \
    && ok "запасной sshd поднят на 2222 (живёт до перезагрузки)" \
    || warn "запасной sshd не стартовал"
fi

# --------------------------------------------------------------- проверка ---
head_ "РЕЗУЛЬТАТ"
sleep 1
echo "-- слушающие порты --"
ss -tlnp 2>/dev/null | grep -E ':(22|443|2222)\b' | sed 's/^/  /' || bad "SSH не слушает ни один порт!"
echo
L22="нет"; L443="нет"
ss -tln 2>/dev/null | grep -qE ':22\b'  && L22="да"
ss -tln 2>/dev/null | grep -qE ':443\b' && L443="да"
echo "  SSH на порту 22:  $L22"
echo "  SSH на порту 443: $L443"
echo
if [ "$L22" = "да" ] && [ "$L443" = "да" ]; then
  ok "ГОТОВО. Теперь на своём Mac запустите mac-setup.sh — он сам выберет рабочий порт."
  echo
  echo "  Быстрая проверка вручную с Mac:"
  echo "    ssh -i ~/.ssh/do-agents -p 443 admin@143.110.157.152 hostname"
else
  bad "Что-то не поднялось. Пришлите вывод этой команды:"
  echo "    journalctl -u ssh.service -n 40 --no-pager"
fi
echo
echo "Отдельно проверьте в панели DigitalOcean: Networking → Firewalls."
echo "Облачный фаервол DO работает ДО сервера — если 443 закрыт там,"
echo "изнутри это никак не видно и ufw тут ни при чём."
echo
