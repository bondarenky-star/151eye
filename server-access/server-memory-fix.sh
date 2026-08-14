#!/usr/bin/env bash
# Лечение настоящей причины пропажи доступа: сервер упирался в память,
# уходил в свап и переставал успевать отвечать на новые SSH-соединения.
#
# Запускать НА СЕРВЕРЕ пользователем admin (sudo без пароля уже есть):
#   bash server-memory-fix.sh
#
# Ничего не ломает в настройке SSH: порты 22 / 443 / 2222 подняты через
# ssh.socket и остаются как есть.
set -u

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'
ok()   { echo "${GRN}  ✓${OFF} $*"; }
warn() { echo "${YEL}  !${OFF} $*"; }
bad()  { echo "${RED}  ✗${OFF} $*"; }
head_() { echo; echo "=== $* ==="; }

SWAP_GB="${SWAP_GB:-8}"
MEM_HIGH="${MEM_HIGH:-3G}"

head_ "ДО"
free -h
uptime
echo "Редакторы съедают, МБ:"
ps -eo rss,args --no-headers | awk '
  /vscode-server/ {v+=$1} /cursor-server/ {c+=$1}
  END {printf "  vscode-server: %d\n  cursor-server: %d\n", v/1024, c/1024}'

# --------------------------------------------------- 1. SSH вне очереди ---
# Главное изменение. Пока sshd мог быть убит нехваткой памяти наравне
# со всем остальным, любая перегрузка означала полную потерю доступа
# к серверу. Теперь ядро будет убивать sshd последним.
head_ "1. ЗАЩИТА SSH ОТ НЕХВАТКИ ПАМЯТИ"
# Правим только ssh.service: у ssh.socket своего процесса нет, слушающие
# сокеты держит systemd, поэтому защищать там нечего.
sudo mkdir -p /etc/systemd/system/ssh.service.d
printf '[Service]\nOOMScoreAdjust=-900\nOOMPolicy=continue\n' \
  | sudo tee /etc/systemd/system/ssh.service.d/override-oom.conf >/dev/null
sudo systemctl daemon-reload
ok "sshd помечен как неприкосновенный при нехватке памяти (постоянно)"

# То же самое для уже запущенного процесса — без перезапуска службы,
# чтобы не оборвать текущие сессии.
if command -v choom >/dev/null 2>&1; then
  for P in $(pgrep -x sshd); do sudo choom -p "$P" -n -900 >/dev/null 2>&1; done
  ok "живым процессам sshd приоритет выставлен сразу (choom)"
else
  for P in $(pgrep -x sshd); do echo -900 | sudo tee "/proc/$P/oom_score_adj" >/dev/null 2>&1; done
  ok "живым процессам sshd приоритет выставлен сразу"
fi

# ------------------------------------------------------------- 2. свап ---
# 2 ГБ свапа на 8 ГБ памяти мало: он был занят под завязку, и ядро
# принималось выбрасывать страницы, из-за чего load average улетал за 140
# при двух ядрах. Это не нагрузка на процессор, это дисковая молотилка.
head_ "2. РАСШИРЕНИЕ СВАПА ДО ${SWAP_GB} ГБ"
CUR_SWAP_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
WANT_KB=$((SWAP_GB * 1024 * 1024))
if [ "$CUR_SWAP_KB" -ge "$((WANT_KB - 102400))" ]; then
  ok "свап уже $((CUR_SWAP_KB / 1024 / 1024)) ГБ — не трогаю"
else
  FREE_GB="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
  if [ "${FREE_GB:-0}" -lt $((SWAP_GB + 5)) ]; then
    warn "на диске свободно всего ${FREE_GB} ГБ — расширение свапа пропускаю"
  else
    sudo swapoff /swapfile 2>/dev/null || warn "swapoff не сработал (свап занят) — попробуйте после разгрузки"
    if sudo fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || \
       sudo dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=none; then
      sudo chmod 600 /swapfile
      sudo mkswap /swapfile >/dev/null 2>&1
      sudo swapon /swapfile && ok "свап расширен до ${SWAP_GB} ГБ"
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    else
      bad "не удалось создать файл свапа"
      sudo swapon /swapfile 2>/dev/null
    fi
  fi
fi

# --------------------------------------------------------- 3. earlyoom ---
# Штатный OOM-killer ядра вступает в дело слишком поздно: к этому моменту
# машина уже полчаса молотит свап и не отвечает по сети. earlyoom убивает
# самого жирного процесса заранее, пока система ещё живая.
head_ "3. EARLYOOM — РАННЯЯ РАЗГРУЗКА"
if command -v earlyoom >/dev/null 2>&1; then
  ok "earlyoom уже установлен"
else
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq earlyoom >/dev/null 2>&1; then
    ok "earlyoom установлен"
  else
    warn "earlyoom не установился (нет сети или пакета) — пропускаю"
  fi
fi
if command -v earlyoom >/dev/null 2>&1; then
  sudo mkdir -p /etc/default
  printf '%s\n' \
    '# Вмешиваться, когда свободной памяти меньше 8% и свапа меньше 10%.' \
    '# Первыми под нож идут серверные части редакторов, sshd защищён.' \
    'EARLYOOM_ARGS="-m 8 -s 10 --avoid ^(sshd|systemd|tmux.*|bash|claude)$ --prefer ^(node|MainThread|obsidian)$"' \
    | sudo tee /etc/default/earlyoom >/dev/null
  sudo systemctl enable --now earlyoom >/dev/null 2>&1
  sudo systemctl restart earlyoom >/dev/null 2>&1
  systemctl is-active earlyoom >/dev/null 2>&1 \
    && ok "earlyoom работает: порог 8% памяти, sshd в списке неприкосновенных" \
    || warn "earlyoom не запустился"
fi

# ------------------------------------------------- 4. лимиты на юзеров ---
# Мягкий потолок: при превышении systemd начинает придавливать процессы
# пользователя, а не даёт им сожрать всю машину целиком. Именно из-за
# отсутствия этого потолка два пользователя с редакторами уложили сервер.
head_ "4. МЯГКИЙ ПОТОЛОК ПАМЯТИ НА ПОЛЬЗОВАТЕЛЯ ($MEM_HIGH)"
for UID_N in 1000 1001; do
  D="/etc/systemd/system/user-${UID_N}.slice.d"
  sudo mkdir -p "$D"
  printf '[Slice]\nMemoryHigh=%s\nMemorySwapMax=4G\n' "$MEM_HIGH" \
    | sudo tee "$D/override-mem.conf" >/dev/null
  ok "user-${UID_N}.slice: MemoryHigh=$MEM_HIGH"
done
sudo systemctl daemon-reload

# -------------------------------------------- 5. разгрузка прямо сейчас ---
# Серверные части редакторов копятся: каждое новое окно VS Code / Cursor
# оставляет свой процесс, и они не убираются сами. Их безопасно убить —
# при следующем подключении редактор поднимет их заново.
head_ "5. ЧИСТКА НАКОПИВШИХСЯ СЕРВЕРОВ РЕДАКТОРОВ"
BEFORE_FREE="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
for PAT in '/home/admin/.vscode-server' '/home/admin/.cursor-server'; do
  # pgrep -c при нуле совпадений возвращает ненулевой код, поэтому считаем
  # строки сами: иначе в переменную попадает мусор и арифметика падает.
  N="$(pgrep -f "$PAT" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$N" -gt 0 ]; then
    pkill -f "$PAT" 2>/dev/null
    sleep 2
    pkill -9 -f "$PAT" 2>/dev/null
    ok "остановлено процессов ($PAT): $N"
  else
    ok "нет процессов $PAT"
  fi
done
sleep 3
AFTER_FREE="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
ok "освободилось примерно $((AFTER_FREE - BEFORE_FREE)) МБ"

WINPC="$(pgrep -f '/home/winpc/.vscode-server' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$WINPC" -gt 0 ]; then
  warn "у пользователя winpc работает свой VS Code ($WINPC процессов, ~1.4 ГБ)."
  warn "Не трогаю: возможно, там кто-то работает. Если сессия ничья:"
  warn "  sudo pkill -f /home/winpc/.vscode-server"
fi

# ------------------------------------------- 6. утилита для будущего ---
head_ "6. КОМАНДА ДЛЯ РУЧНОЙ РАЗГРУЗКИ"
sudo mkdir -p /usr/local/bin
sudo tee /usr/local/bin/free-editors >/dev/null << 'EOF'
#!/usr/bin/env bash
# Прибить накопившиеся серверные части VS Code / Cursor. Они поднимутся
# заново при следующем подключении — терять нечего, кроме открытых панелей.
echo "Было свободно: $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) МБ"
pkill -f '.vscode-server' 2>/dev/null
pkill -f '.cursor-server' 2>/dev/null
sleep 2
pkill -9 -f '.vscode-server' 2>/dev/null
pkill -9 -f '.cursor-server' 2>/dev/null
sleep 2
echo "Стало свободно: $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) МБ"
EOF
sudo chmod +x /usr/local/bin/free-editors
ok "добавлена команда: free-editors"

head_ "ПОСЛЕ"
free -h
uptime
echo
echo "SSH слушает:"
sudo ss -tln | grep -E ':(22|443|2222)\b' | sed 's/^/  /'
echo
echo "Порты 22 / 443 / 2222 не менялись — они и раньше работали."
echo "Проверьте с Mac:  ssh do-agents-443 'uptime'"
