# Cloud Agent Farm

A 24/7 agent harness on a cheap cloud VM. You (or your AI assistant) drop
task prompts into a queue; a worker loop runs them with coding agents and
writes back compact summaries. Manage everything from any browser —
desktop or phone.

```
local/windows/Push-FarmConfig.ps1   one command: your local OpenCode /
                                     OpenChamber / Antigravity setup
                                     -> encrypted bundle -> onto the VM
            |
            v
┌──────────────────────────────────────────────────────┐
│ Cloud VM (Ubuntu, ~1 GB RAM is enough)               │
│                                                      │
│  queue/pending/*.task  ──>  agent-loop.sh (systemd)  │
│        (prompt text)         opencode / agy agents    │
│                              │                       │
│  queue/done/*.summary  <────┘  (compact, token-light) │
│                                                      │
│  :3000  OpenChamber web UI   │  :8080  Filebrowser    │
│         (agent dashboard)    │  (file manager — this  │
│                              │   is how you feed the  │
│                              │   worker .task files)  │
└──────────────────────────────────────────────────────┘
            ^
            |
local/bin/remote-supervise.sh  cron every 30 min: reads ONLY summaries,
                               dispatches new tasks, restarts a stuck loop
```

## Quick start

1. **Create a small cloud VM** (Ubuntu 22.04/24.04, 1 vCPU / 1 GB RAM —
   free-tier eligible on most clouds). Open ports **3000** and **8080**.
2. **One file, one command.** Upload `vm/farm-one-click.sh` to the VM
   (file manager `:8080` or web SSH "Upload file"), then run:
   ```bash
   bash ~/farm-one-click.sh
   ```
   If your `openchamber-full-*.zip[.enc]` sits next to it, your skills,
   agents, MCPs, settings and keys are restored too (passphrase asked once).
   (Fresh VM without the repo? This file is self-contained — no `git clone` needed.
   With the repo: `bash vm/setup-farm-vm.sh` does the same minus the bundle import.)
   Save the printed OpenChamber UI password (shown once).
3. **Give the workers brains** (pick what you use):
   - `opencode auth login` — or place your `auth.json` in
     `~/.local/share/opencode/` (chmod 600). Free models via
     [OpenCode Zen](https://opencode.ai/auth) work: the loop probes
     `FARM_MODELS` and takes the first working one.
   - `agy login` — or set `GEMINI_API_KEY` for the Antigravity CLI.
4. **Sync your local setup** (Windows):
   ```powershell
   powershell -ExecutionPolicy Bypass -File local/windows/Push-FarmConfig.ps1
   ```
   Collects your OpenCode / OpenChamber / Antigravity / agy configs, MCP
   servers, skills and keys → AES-256 encrypted bundle (passphrase only you
   know) → uploads through the file manager → then run the one printed
   command in the VM's web terminal and type your passphrase. Nothing
   unencrypted ever leaves your PC.
5. **Give it work**: upload a `<name>.task` file (plain prompt text) into
   `queue/pending/` via the file manager (`:8080`). The worker picks it up
   within ~2 minutes; the result lands in `queue/done/<name>.summary`.
   Optional `<name>.dir` sidecar file = project directory for the task.

## Clone to another computer (one file)

1. On this PC: `powershell -ExecutionPolicy Bypass -File local/windows/Export-OpenChamberFull.ps1`
   Packs skills (7), agents (8), commands (31), MCPs (`opencode.jsonc`), themes,
   OpenChamber settings/projects/chats, `auth.json` into one
   `openchamber-full-<date>.zip` (+ optional AES-256 `.enc`). Chat history
   (`opencode.db`, 1 GB+) is skipped; add `-IncludeHistory` to include it.
2. Copy that ONE file to the other computer.
3. There: Windows `Import-OpenChamberFull.ps1`, Linux `bash local/bin/import-openchamber-full.sh <bundle>`.
   Current config is backed up to `*-backup-<date>` first. Fix provider paths
   (`agy.exe`, python venv) if the OS differs.

## Operating it

- **From any browser**: OpenChamber UI (`:3000`) for the agent dashboard,
  file manager (`:8080`) for tasks and files. Both are password-protected
  (HTTP, no TLS — fine inside your own use, don't reuse the passwords).
- **From your assistant / cron**: `local/bin/remote-supervise.sh` every
  30 minutes with `FARM_TARGET=user@host` and `FARM_SSH_KEY=...` set.
  It reads only compact summaries (cheap), dispatches queued tasks and
  restarts a stuck worker. `local/bin/talk.sh "message"` drops a direct
  message into the worker's inbox.
- **Live logs**: `~/agent-farm/logs/<task>.log` on the VM.

## Security notes

- API keys travel **only** inside the AES-256 encrypted bundle, or are
  typed directly on the VM. They are never in chat, never in this repo.
- The bundle is deleted from the VM after a successful import; the local
  copy is deleted after upload.
- This repo contains **no credentials** — only placeholders (`YOUR_VM_IP`,
  `farm` as the example user). Verify with:
  `grep -rniE "sk-|AIza|ghp_|BEGIN.*PRIVATE|password\s*=\s*['\"][^'\"]" .`
- Free-model providers may use your prompts for training — don't send secrets
  to free tiers.

## Costs

Designed for cloud free tiers (1× small VM). Nothing here provisions paid
resources. Set a billing alert anyway — your cloud, your responsibility.

## Layout

```
vm/                 everything that runs ON the cloud VM
  bin/              agent-loop.sh (worker), import-farm-config.sh,
                    openchamber-run.sh, install-agy.sh
  systemd/          farm-agent, openchamber, filebrowser units
  .farm.env.example worker config (models, timeouts)
  setup-farm-vm.sh  one-shot VM installer
local/              everything that runs on YOUR machine
  bin/              remote-supervise.sh (cron), dispatch.sh, talk.sh,
                    status.sh, keepalive.sh, run-agent.sh
  windows/          Push-FarmConfig.ps1 (full sync), Export-FarmConfig.ps1
docs/               architecture notes
```

## License

MIT — see LICENSE.
