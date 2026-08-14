# my-project

## Cursor Cloud specific instructions

This repository is a **Bash-based SSH access-recovery toolkit** (see
`server-access/`). It is not a compiled/served application: there is no package
manager, build step, or automated test suite. The "product" is three artifacts:

| File | Role | Where it is meant to run |
|---|---|---|
| `server-access/mac-setup.sh` | Client-side diagnostics: probes the target server, classifies the failure, writes `~/.ssh/config`, configures VS Code/Cursor. | On a user's macOS/Linux machine |
| `server-access/server-repair.sh` | Server-side repair: rebuilds `sshd` on ports 22+443, fixes `ufw`, clears `fail2ban` bans, restores `authorized_keys`. | On the target server, as `root` |
| `server-access/console-paste.txt` | The same repair as a copy-paste block for the DigitalOcean Web Console. | On the target server, as `root` |

Docs are in Russian: `server-access/README.md` and `server-access/DIAGNOSTIKA.md`.

### Lint / verify

- Lint: `shellcheck server-access/mac-setup.sh server-access/server-repair.sh`.
  ShellCheck is not preinstalled on a bare image — install with
  `sudo apt-get install -y shellcheck` (the startup update script does this).
  The only findings are two intentional `SC2015` (`A && B || C`) info notes in
  the logging lines; there are no warnings/errors.
- Syntax check: `bash -n server-access/*.sh`.

### Running the tools (non-obvious caveats)

- `mac-setup.sh` targets a **real external DigitalOcean droplet**
  (`143.110.157.152`, user `admin`, ports 22/443/2222). Running it makes
  outbound SSH probes to that host (up to ~10s per port). It needs a private key
  named `do-agents`; the key is **not** committed. The script searches for it in
  `keys/do-agents` next to the script, `~/Downloads/SERVER-MAC/keys/do-agents`,
  or `~/.ssh/do-agents`, and aborts at step 1 if none is found.
  - To exercise it safely in the cloud VM without touching your real `~/.ssh`,
    run it with an isolated `HOME` and a throwaway key placed at `keys/do-agents`
    beside a copy of the script:
    `ssh-keygen -t ed25519 -N "" -f <dir>/keys/do-agents` then
    `HOME=<sandbox> bash <dir>/mac-setup.sh </dev/null`. It will run the full
    pipeline and produce `$HOME/.ssh/config` plus a diagnostic report
    (`$HOME/Desktop/server-diagnostika.txt`, or `$HOME/server-diagnostika.txt`
    when there is no Desktop). The final `read` prompt is why `</dev/null` is
    used.
- `server-repair.sh` is **destructive to the host it runs on**: it rewrites
  `/etc/ssh/sshd_config*`, toggles `ssh.socket`/`ssh.service`, edits `ufw`, and
  restarts SSH. **Do not run its repair path against the cloud VM** — only on the
  intended target server (or a throwaway box). It self-guards and exits when not
  run as `root`, so `bash server-access/server-repair.sh` as a normal user just
  prints usage and is safe.
