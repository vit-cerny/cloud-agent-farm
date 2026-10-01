# Architecture

## The loop

1. A task is a text file: `queue/pending/<name>.task` (the prompt).
   An optional `<name>.dir` sidecar holds the project directory.
2. `agent-loop.sh` (systemd `farm-agent`, `Restart=always`) picks up the
   oldest task, moves it to `queue/doing/`, and runs it:
   `opencode run --model <first working free model> --dir <project> <prompt>`.
3. Full output goes to `logs/<name>.log`. A compact summary
   (last 30 lines, max 4 KB) goes to `queue/done/<name>.summary`.
4. If the task fails, the worker drops a `NEEDS DECISION` message into
   `outbox/` and blanks the model so the next task probes a fresh one.
5. A heartbeat (`queue/heartbeat`, unix timestamp) is written every 60 s.

## The supervisor

`local/bin/remote-supervise.sh`, run from cron every 30 minutes, does four
things over SSH and nothing else:

- reads heartbeat/status (two tiny files),
- dispatches new `.task` files from the local queue to the VM,
- reads only `queue/done/*.summary` and `outbox/*.msg` (token-cheap),
- restarts `farm-agent` if the heartbeat is older than 15 minutes.

It prints `NOTIFY:` lines for exactly three events: task done, loop stuck,
outbox message. Everything else stays silent.

## The sync

`local/windows/Push-FarmConfig.ps1`:

```
collect (opencode, openchamber, antigravity, agy CLI, + extra folders)
  -> zip -> AES-256-CBC (PBKDF2, passphrase only the user knows)
  -> upload via Filebrowser API (X-Auth header) to the farm root
  -> local bundle deleted
```

On the VM, `vm/bin/import-farm-config.sh <bundle>` (run as the farm user)
asks for the passphrase, decrypts with openssl, and restores:

| bundle dir              | VM destination              |
|-------------------------|-----------------------------|
| `config/opencode`       | `~/.config/opencode`        |
| `config/openchamber`    | `~/.config/openchamber`     |
| `config/antigravity`    | `~/.config/antigravity`     |
| `config/antigravity-cli`| `~/.gemini/antigravity-cli` |
| `auth/opencode`         | `~/.local/share/opencode` (600) |
| `custom/*`              | `~/farm-import/` (manual review) |
| `projects/*`            | `~/agent-farm/projects/`    |

Existing configs are backed up as `.bak-<timestamp>`. The bundle is deleted
after a successful import. Services are restarted so the new config applies.

## Design choices

- **Batch tasks, not live sessions.** The worker runs `opencode run`
  non-interactively. This is deliberate: it survives disconnects, needs no
  open browser tab, and summaries are cheap to read.
- **Two agent engines.** `opencode` (many free models via Zen) is the
  default worker; `agy` (Antigravity CLI, `agy -p`) is available for
  background tasks in `projects-agy/`. Separate project dirs keep them
  from stepping on each other.
- **No secrets in the repo.** Keys live in credential files (chmod 600)
  and travel only inside the encrypted bundle. The `.gitignore` blocks the
  usual suspects; CI should grep for key patterns on every push.
- **Free-tier shaped.** e2-micro-class VM, no static IP required, no paid
  services. The worker idles at ~2 min sleeps and does nothing when the
  queue is empty.
