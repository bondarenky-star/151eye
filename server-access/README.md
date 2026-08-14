# Восстановление доступа к серверу

Набор для случая «работало, потом перенесли SSH на 443, и всё отвалилось».

| Файл | Для чего | Где запускать |
|---|---|---|
| `mac-setup.sh` | Диагностика + настройка доступа и VS Code | На своём Mac |
| `server-repair.sh` | Поднимает sshd на 22 и 443, чинит ufw, ключи, снимает баны | На сервере, от root |
| `console-paste.txt` | То же самое, но коротким блоком для Web Console DigitalOcean | На сервере, от root |
| `DIAGNOSTIKA.md` | Подробно: что означает каждая ошибка и почему сломалось | Читать |

## С чего начать

Одна команда в Терминале на Mac — скачает скрипт в папку с ключами и запустит:

```
cd ~/Downloads/SERVER-MAC && curl -fsSL https://raw.githubusercontent.com/bondarenky-star/151eye/cursor/restore-ssh-access-vscode-96cf/server-access/mac-setup.sh -o mac-setup.sh && chmod +x mac-setup.sh && ./mac-setup.sh
```

Важно запускать именно из папки распакованного архива: рядом должна лежать
папка `keys/` с ключом `do-agents`. Если архив распакован в другое место —
подставьте свой путь вместо `~/Downloads/SERVER-MAC`.

Скрипт сам скажет, что делать дальше. Если он попросит починить сервер —
откройте `DIAGNOSTIKA.md`, шаг 2.

## Данные сервера

| | |
|---|---|
| IP | `143.110.157.152` |
| Пользователь | `admin` |
| Порты SSH | 22 и 443 (после ремонта) |
| Рабочая папка | `/home/admin/projects` |
| Аварийный вход | DigitalOcean → дроплет → Access → Launch Web Console |

Приватные ключи в репозиторий не кладутся. `mac-setup.sh` берёт ключ из папки
`keys/` рядом с собой, из `~/Downloads/SERVER-MAC/keys/` или из `~/.ssh/do-agents`.
