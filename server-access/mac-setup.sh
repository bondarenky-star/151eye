#!/usr/bin/env bash
# Восстановление доступа к серверу + настройка VS Code (macOS / Linux).
#
# Отличие от старого setup.sh: скрипт сначала ВЫЯСНЯЕТ, почему не работает,
# и только потом настраивает. Он умеет подключаться не только по порту 22,
# но и по 443 / 2222, и сам прописывает в конфиг тот порт, который реально живой.
set -u

IP="143.110.157.152"
RUSER="admin"
ALIAS="do-agents"
PORTS="22 443 2222"
EXPECT_HOST="agents-s-2vcpu-8gb-160gb-intel-sfo3"

SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/do-agents"
CFG="$SSH_DIR/config"
KNOWN="$SSH_DIR/known_hosts"
REPORT="$HOME/Desktop/server-diagnostika.txt"
[ -d "$HOME/Desktop" ] || REPORT="$HOME/server-diagnostika.txt"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { echo "$@"; echo "$@" >> "$REPORT"; }
rule() { say "--------------------------------------------------"; }

: > "$REPORT"
say "Диагностика доступа к серверу — $(date)"
rule

# ---------------------------------------------------------------- 1. ключ ---
# Ключ ищем в нескольких местах: рядом со скриптом, в распакованном архиве,
# и там, куда его мог положить прошлый запуск установщика.
find_key() {
  for c in "$DIR/keys/do-agents" "$DIR/do-agents" \
           "$HOME/Downloads/SERVER-MAC/keys/do-agents" \
           "$HOME/Загрузки/SERVER-MAC/keys/do-agents" \
           "$KEY"; do
    [ -f "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

SRC="$(find_key)" || {
  say "ОШИБКА: не найден файл ключа do-agents."
  say "Положите скрипт рядом с папкой keys/ из архива и запустите снова."
  exit 1
}
say "[1/7] Ключ найден: $SRC"

mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
if [ "$SRC" != "$KEY" ]; then
  cp "$SRC" "$KEY"
  say "      Скопирован в $KEY"
fi
chmod 600 "$KEY"
# macOS помечает скачанные файлы карантином — ssh на это не смотрит,
# но заодно убираем, чтобы не мешало другим инструментам.
command -v xattr >/dev/null 2>&1 && xattr -d com.apple.quarantine "$KEY" 2>/dev/null

# Проверяем, что ключ не побился при передаче: из живого приватного ключа
# всегда выводится публичный. Если нет — файл повреждён, дальше смысла нет.
if ! ssh-keygen -y -f "$KEY" >/dev/null 2>&1; then
  say "ОШИБКА: файл ключа повреждён (ssh-keygen не может его прочитать)."
  say "Скачайте архив заново и запустите скрипт из свежей распаковки."
  exit 1
fi
say "      Ключ читается корректно, права 600"

# ------------------------------------------------------- 2. known_hosts ---
# Самая частая причина «работало и перестало»: сервер переставили на другой
# порт или пересоздали, а в known_hosts лежит старый отпечаток. ssh тогда
# отказывается соединяться вообще, независимо от ключа.
if [ -f "$KNOWN" ]; then
  cp "$KNOWN" "$KNOWN.backup" 2>/dev/null
  for h in "$IP" "[$IP]:443" "[$IP]:2222" "$ALIAS" "[$ALIAS]:443" "[$ALIAS]:2222"; do
    ssh-keygen -R "$h" -f "$KNOWN" >/dev/null 2>&1
  done
  say "[2/7] Старые отпечатки сервера удалены из known_hosts (копия: $KNOWN.backup)"
else
  say "[2/7] known_hosts пуст — чистить нечего"
fi

# ------------------------------------------------------------- 3. пробы ---
# Пробуем каждый порт и классифицируем ответ. Разные ошибки означают
# принципиально разные проблемы, и лечатся они по-разному.
probe() {
  local port="$1" out
  out="$(ssh -o BatchMode=yes \
             -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null \
             -o IdentitiesOnly=yes \
             -o ConnectTimeout=10 \
             -o LogLevel=ERROR \
             -i "$KEY" -p "$port" "$RUSER@$IP" 'echo __OK__; hostname' 2>&1)"
  echo "--- порт $port ---" >> "$REPORT"
  echo "$out" >> "$REPORT"
  case "$out" in
    *__OK__*)                       echo "OK" ;;
    *"banner exchange"*)            echo "NOBANNER" ;;
    *"Permission denied"*)          echo "AUTH" ;;
    *"refused"*|*"Refused"*)        echo "REFUSED" ;;
    *"imed out"*|*"imeout"*)        echo "FILTERED" ;;
    *"No route to host"*)           echo "NOROUTE" ;;
    *"Host key verification"*)      echo "HOSTKEY" ;;
    *)                              echo "OTHER" ;;
  esac
}

say "[3/7] Проверяю порты $PORTS (до 10 секунд на каждый)..."
GOOD_PORT=""
ANY_AUTH="no"
ANY_REFUSED="no"
ANY_NOBANNER="no"
for p in $PORTS; do
  r="$(probe "$p")"
  case "$r" in
    OK)       say "      порт $p: РАБОТАЕТ"; [ -z "$GOOD_PORT" ] && GOOD_PORT="$p" ;;
    AUTH)     say "      порт $p: сервер отвечает, но ключ отклонён"; ANY_AUTH="yes" ;;
    NOBANNER) say "      порт $p: соединение есть, но это не SSH (или sshd завис)"; ANY_NOBANNER="yes" ;;
    REFUSED)  say "      порт $p: соединение сброшено — на этом порту никто не слушает"; ANY_REFUSED="yes" ;;
    FILTERED) say "      порт $p: тишина, пакеты дропаются (фаервол, бан или ваш провайдер)" ;;
    NOROUTE)  say "      порт $p: нет маршрута до сервера" ;;
    HOSTKEY)  say "      порт $p: конфликт отпечатка хоста" ;;
    *)        say "      порт $p: непонятный ответ, подробности в $REPORT" ;;
  esac
done

# ------------------------------------------------- 4. контрольные замеры ---
# Если сервер молчит, надо понять, чья это вина: сервера или вашей сети.
# GitHub принимает SSH и на 22, и на 443 — это идеальные «контрольные» точки.
if [ -z "$GOOD_PORT" ]; then
  say "[4/7] Сервер не ответил. Проверяю, пропускает ли SSH ваша сеть..."
  NET22="нет"; NET443="нет"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -T git@github.com 2>&1 | grep -qiE 'successfully authenticated|Permission denied' && NET22="да"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -T -p 443 git@ssh.github.com 2>&1 | grep -qiE 'successfully authenticated|Permission denied' && NET443="да"
  say "      исходящий порт 22 из вашей сети работает:  $NET22"
  say "      исходящий порт 443 из вашей сети работает: $NET443"

  # -W у ping означает разное: на macOS миллисекунды, на Linux секунды.
  PING="нет"
  if [ "$(uname -s)" = "Darwin" ]; then
    ping -c 3 -W 3000 "$IP" >/dev/null 2>&1 && PING="да"
  else
    ping -c 3 -W 3 "$IP" >/dev/null 2>&1 && PING="да"
  fi
  say "      сервер отвечает на ping: $PING"
else
  say "[4/7] Контрольные замеры не нужны — подключение уже работает"
  NET22="да"; NET443="да"; PING="да"
fi

# -------------------------------------------------------- 5. ssh/config ---
# Старый блок Host do-agents заменяем целиком: недоделанная ручная правка
# иначе тихо переживёт установку и сломает вход.
PORT_TO_WRITE="${GOOD_PORT:-22}"
touch "$CFG"
if grep -qiE '^[[:space:]]*Host[[:space:]]+do-agents' "$CFG"; then
  cp "$CFG" "$CFG.backup"
  awk '
    /^[[:space:]]*[Hh]ost[[:space:]]+/ {
      skip = ($0 ~ /^[[:space:]]*[Hh]ost[[:space:]]+do-agents/)
    }
    !skip { print }
  ' "$CFG.backup" > "$CFG"
  say "[5/7] Старые записи do-agents заменены (копия: $CFG.backup)"
else
  say "[5/7] Добавляю хост do-agents в $CFG"
fi

cat >> "$CFG" << EOF

Host do-agents
    HostName $IP
    User $RUSER
    Port $PORT_TO_WRITE
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 4
    TCPKeepAlive yes

Host do-agents-22
    HostName $IP
    User $RUSER
    Port 22
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 4

Host do-agents-443
    HostName $IP
    User $RUSER
    Port 443
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 4
EOF
chmod 600 "$CFG"
say "      Основной хост do-agents настроен на порт $PORT_TO_WRITE"
say "      Запасные псевдонимы: do-agents-22, do-agents-443"

# ------------------------------------------------------------ 6. VS Code ---
# remotePlatform — иначе VS Code спросит платформу, а выбор Windows ломает
# подключение. configFile — явный путь, потому что ssh из VS Code не всегда
# находит ~/.ssh/config сам.
setup_editor() {
  local name="$1" settings="$2"
  [ -d "$(dirname "$(dirname "$settings")")" ] || return 1
  mkdir -p "$(dirname "$settings")" 2>/dev/null
  [ -f "$settings" ] || echo '{}' > "$settings"
  command -v python3 >/dev/null 2>&1 || { say "      $name: нет python3, настройте вручную (см. DIAGNOSTIKA.md)"; return 1; }
  cp "$settings" "$settings.backup" 2>/dev/null
  if python3 - "$settings" "$CFG" << 'PYEOF'
import json, sys
path, cfg = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding='utf-8') as f:
        data = json.loads(f.read().strip() or '{}')
except Exception:
    sys.exit(1)
plat = data.get('remote.SSH.remotePlatform') or {}
for h in ('do-agents', 'do-agents-22', 'do-agents-443'):
    plat[h] = 'linux'
data['remote.SSH.remotePlatform'] = plat
data['remote.SSH.configFile'] = cfg
data['remote.SSH.connectTimeout'] = 60
ext = data.get('remote.SSH.defaultExtensions') or []
if 'anthropic.claude-code' not in ext:
    ext.append('anthropic.claude-code')
data['remote.SSH.defaultExtensions'] = ext
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
PYEOF
  then
    say "      $name: настройки обновлены (платформа Linux, путь к SSH-config)"
  else
    say "      $name: не удалось обновить автоматически — вероятно, в settings.json есть комментарии."
    say "               Если спросит «Select platform» — выбирайте LINUX."
  fi
}

say "[6/7] Настраиваю редакторы"
setup_editor "VS Code" "$HOME/Library/Application Support/Code/User/settings.json"
setup_editor "Cursor"  "$HOME/Library/Application Support/Cursor/User/settings.json"

CODE_BIN=""
if command -v code >/dev/null 2>&1; then
  CODE_BIN="code"
elif [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]; then
  CODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
fi
if [ -n "$CODE_BIN" ]; then
  if "$CODE_BIN" --list-extensions 2>/dev/null | grep -qi 'ms-vscode-remote.remote-ssh'; then
    say "      Расширение Remote-SSH уже установлено"
  else
    "$CODE_BIN" --install-extension ms-vscode-remote.remote-ssh >/dev/null 2>&1 \
      && say "      Расширение Remote-SSH установлено" \
      || say "      Remote-SSH не поставился автоматически — поставьте вручную через Extensions"
  fi
else
  say "      VS Code не найден. Скачайте: https://code.visualstudio.com"
fi

# ------------------------------------------------------------- 7. вывод ---
rule
say "[7/7] ИТОГ"
rule

if [ -n "$GOOD_PORT" ]; then
  say "ГОТОВО. Подключение работает через порт $GOOD_PORT."
  # Сверяем имя машины: подтверждает, что мы попали именно на свой сервер,
  # а не на подставленный провайдером или VPN адрес.
  REAL_HOST="$(ssh -o BatchMode=yes -o ConnectTimeout=15 do-agents hostname 2>/dev/null)"
  if [ "$REAL_HOST" = "$EXPECT_HOST" ]; then
    say "Сервер представился как $REAL_HOST — это он."
  elif [ -n "$REAL_HOST" ]; then
    say "ВНИМАНИЕ: сервер назвался «$REAL_HOST», а ожидался «$EXPECT_HOST»."
    say "Возможно, вы попали не на ту машину."
  fi
  say ""
  say "Что дальше:"
  say "  1. Полностью закройте VS Code (Cmd+Q) и откройте заново."
  say "  2. Cmd+Shift+P → Remote-SSH: Connect to Host → do-agents"
  say "  3. File → Open Folder → /home/admin/projects"
  say ""
  say "Если VS Code всё равно не подключается, а терминал подключается:"
  say "  Cmd+Shift+P → Remote-SSH: Kill VS Code Server on Host → do-agents,"
  say "  потом подключитесь заново."
elif [ "$ANY_AUTH" = "yes" ]; then
  say "СЕРВЕР ЖИВ, НО НЕ ПРИНИМАЕТ КЛЮЧ."
  say ""
  say "Значит на сервере испортился файл /home/admin/.ssh/authorized_keys"
  say "(или права на него). Чинится только с самого сервера:"
  say "  DigitalOcean → дроплет agents-... → кнопка Web Console → войти как root"
  say "  и выполнить server-repair.sh (или вставить блок из console-paste.txt)."
elif [ "$ANY_REFUSED" = "yes" ]; then
  say "СЕРВЕР ЖИВ, НО SSH НА НЁМ НЕ ЗАПУЩЕН."
  say ""
  say "Порт активно отказывает — значит сеть до сервера в порядке, а sshd лежит."
  say "Скорее всего его уронили при переносе на порт 443: в Ubuntu 24.04"
  say "SSH запускается через ssh.socket, и строчка «Port 443» в sshd_config"
  say "сама по себе не работает."
  say ""
  say "Чинить с сервера: DigitalOcean → Web Console → root → server-repair.sh"
elif [ "$ANY_NOBANNER" = "yes" ]; then
  say "НА ПОРТУ КТО-ТО ЕСТЬ, НО ЭТО НЕ SSH."
  say ""
  say "Либо на 443 повесили не sshd, либо sshd завис и не отвечает."
  say "Чинить с сервера: DigitalOcean → Web Console → root → server-repair.sh"
elif [ "$NET22" = "нет" ] && [ "$NET443" = "да" ]; then
  say "ВАША СЕТЬ РЕЖЕТ ПОРТ 22."
  say ""
  say "Наружу проходит только 443. Поэтому и переносили SSH на 443 —"
  say "но на сервере это до конца не доделано."
  say ""
  say "Чинить с сервера: DigitalOcean → Web Console → root → server-repair.sh"
  say "Он поднимет SSH одновременно на 22 и 443. После этого запустите"
  say "этот скрипт ещё раз — он сам переключится на 443."
elif [ "$PING" = "нет" ]; then
  say "СЕРВЕР НЕ ОТВЕЧАЕТ ВООБЩЕ (даже на ping)."
  say ""
  say "Проверьте в панели DigitalOcean, что дроплет включён и не приостановлен"
  say "за неоплату, и что в Networking → Firewalls его не закрыли целиком."
else
  say "СЕРВЕР МОЛЧИТ: пакеты уходят, ответа нет."
  say ""
  say "Так выглядит блокировка фаерволом. Два самых вероятных варианта:"
  say "  - ufw на сервере не открыл нужный порт (например, 443 забыли разрешить);"
  say "  - fail2ban забанил ваш домашний IP после серии неудачных попыток входа."
  say ""
  say "И то, и другое лечится только с сервера:"
  say "  DigitalOcean → Web Console → root → server-repair.sh"
fi

rule
say "Полный лог сохранён: $REPORT"
say "Если понадобится помощь — пришлите этот файл."
echo
read -r -p "Нажмите Enter, чтобы закрыть..." _ || true
echo
