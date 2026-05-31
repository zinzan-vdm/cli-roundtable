---
name: enable-hermes-dashboard
description: "Use when setting up or reconfiguring the Hermes Agent web dashboard (port 9119) and API server (port 8642) on a non-Docker VPS — configure .env vars, start the dashboard, set up a watchdog cron job so it survives restarts."
version: 1.0.0
author: Hermes Agent (Arthur)
license: MIT
metadata:
  hermes:
    tags: [dashboard, api-server, devops, setup, watchdog, cron]
    related_skills: [hermes-agent, cronjob]
---

# Enable Hermes Agent Dashboard

## Overview

Hermes Agent has two dashboard-related services:

1. **Web Dashboard** (port 9119) — browser-based UI for managing config, API keys, sessions, logs, analytics, cron jobs, and skills. Served by `hermes dashboard`.
2. **API Server** (port 8642) — OpenAI-compatible HTTP API that runs inside the gateway process. Used by external frontends like Open WebUI.

On a non-Docker VPS (e.g. Hetzner), the dashboard is a **separate process** from the gateway. This skill covers:
- Enabling the API server via `.env` variables (survives gateway restarts)
- Starting the dashboard web UI
- Setting up a watchdog cron job so the dashboard auto-restarts on crash

## Prerequisites

- Hermes Agent installed and the gateway running (via systemd or background process)
- Web frontend already built at `hermes_cli/web_dist/` (check with `ls $(hermes config path | xargs dirname)/../hermes_cli/web_dist/ 2>/dev/null`)
  - If it doesn't exist, run: `cd $(pip3 show hermes-agent 2>/dev/null | grep Location | cut -d' ' -f2)/../web && npm run build`
- `ss` or `netstat` available (usually provided by `iproute2` / `net-tools`)

## Step 1: Enable the API Server (in-gateway)

The API server runs **inside the gateway process** and is enabled via env vars. Add these to the Hermes `.env` file (located at `$HERMES_HOME/.env`):

```bash
cat >> "$HERMES_HOME/.env" << 'EOF'
API_SERVER_ENABLED=true
API_SERVER_KEY=<generate-a-secret-key>
API_SERVER_HOST=127.0.0.1
API_SERVER_PORT=8642
EOF
```

Generate a key with: `openssl rand -hex 32`

The gateway loads `.env` via `load_hermes_dotenv()` at startup. To pick up the vars without restarting the gateway:

```bash
# If running under systemd:
sudo systemctl restart hermes-gateway   # or the profile-named service

# If running as a foreground process:
kill <gateway-pid> && hermes gateway run
```

**Verify** the API server is listening:

```bash
ss -tlnp | grep 8642
# → LISTEN 0 128 127.0.0.1:8642 0.0.0.0:*  users:((\"hermes\",...))

# Test:
curl -s http://127.0.0.1:8642/health
# → {\"status\":\"ok\"}
```

## Step 2: Start the Dashboard (web UI)

Start the dashboard as a background process, binding only to loopback:

```bash
hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build &
```

- `--host 127.0.0.1` — binds to loopback only (safe behind firewall)
- `--port 9119` — default dashboard port
- `--no-open` — don't try to open a browser (no display server on VPS)
- `--skip-build` — use existing pre-built frontend (skip npm)

On first run, Hermes may lazy-install FastAPI/Uvicorn dependencies automatically.

**Verify:**

```bash
ss -tlnp | grep 9119
# → LISTEN 0 2048 127.0.0.1:9119 0.0.0.0:*  users:((\"hermes\",...))

curl -s http://127.0.0.1:9119/api/status | python3 -m json.tool
# → {\"version\": \"0.15.2\", \"gateway_running\": true, ...}
```

## Step 3: Set Up a Watchdog Cron Job

The dashboard is a **separate process** — if it crashes, it won't restart on its own. Unlike the gateway (which has systemd auto-restart), the dashboard needs a watchdog.

### 3a: Create the watchdog script

Write a bash script at `$HERMES_HOME/scripts/dashboard-watchdog.sh`:

```bash
mkdir -p \"$HERMES_HOME/scripts\"
```

```bash
#!/usr/bin/env bash
# Watchdog: check if dashboard is listening on PORT, restart if not.
# Designed for cron with no_agent=true (zero tokens).
set -euo pipefail

PORT=9119
HOST=127.0.0.1
DASHBOARD_BIN=\"$(dirname \"$0\")/../../.venv/bin/hermes\"
PIDFILE=\"/tmp/hermes-dashboard-watchdog.pid\"

# Check if already listening
if ss -tlnp src \":${PORT}\" | grep -q \"hermes\"; then
    exit 0  # Healthy — silent exit
fi

# Not running — start it
rm -f \"$PIDFILE\"
nohup \"$DASHBOARD_BIN\" dashboard \\
    --host \"$HOST\" --port \"$PORT\" --no-open --skip-build \\
    &>/tmp/hermes-dashboard.log &
echo \"$!\" > \"$PIDFILE\"
sleep 5

if ss -tlnp src \":${PORT}\" | grep -q \"hermes\"; then
    echo \"✅ Hermes dashboard restarted on ${HOST}:${PORT} (PID $(cat \"$PIDFILE\"))\"
else
    echo \"❌ Failed to start Hermes dashboard — check /tmp/hermes-dashboard.log\"
    exit 1
fi
```

Make it executable:

```bash
chmod +x \"$HERMES_HOME/scripts/dashboard-watchdog.sh\"
```

### 3b: Create the cron job via the cronjob tool

```python
# From within a Hermes session, use the cronjob tool:
cronjob(
    action=\"create\",
    name=\"Dashboard Watchdog\",
    schedule=\"5m\",         # Check every 5 minutes
    no_agent=True,         # Zero-token mode — runs the script directly
    script=\"dashboard-watchdog.sh\",
    # 'script' resolves relative to $HERMES_HOME/scripts/
)
```

**no_agent=True** means:
- No LLM involved — the script runs directly
- Empty stdout → silent (no message delivered) — correct for \"still running\"
- Non-empty stdout → delivered as the message — correct for \"just restarted\"

### 3c: Verify the cron job

```bash
cronjob(action=\"list\")
# → Should show the Dashboard Watchdog with state=\"scheduled\", repeat=\"forever\"

# Test it immediately:
cronjob(action=\"run\", job_id=\"<job-id>\")
```

## Access via SSH Tunnel

Both services bind to `127.0.0.1` (loopback). Access them from your local machine by SSH-tunneling:

```bash
# Single tunnel for both services:
ssh -L 9119:127.0.0.1:9119 -L 8642:127.0.0.1:8642 root@<vps-ip>
```

Then in your browser: **http://localhost:9119**

## Summary: What Survives What

| Event | API Server (8642) | Dashboard (9119) |
|-------|-------------------|-------------------|
| Gateway restarts | ✅ Comes back (via .env) | ⚠️ Stays up (separate process) |
| Dashboard crashes | ✅ Unaffected | ✅ Watchdog restarts within 5 min |
| Full VPS reboot | ✅ Gateway systemd → .env loaded | ✅ Watchdog kicks in within 5 min |
| Process killed | ✅ Systemd restarts gateway | ✅ Watchdog restarts dashboard |

## Common Pitfalls

1. **API server refuses to start** — `API_SERVER_KEY` must be set and non-empty (the server checks this even for loopback binds). Generate one with `openssl rand -hex 32`.
2. **Dashboard says \"Install web/pty extras\"** — Run `pip install 'hermes-agent[web,pty]'` or let the lazy installer handle it on first launch.
3. **Portal OAuth error on dashboard** — The default `127.0.0.1` bind skips OAuth entirely. Only hits this if you bind to `0.0.0.0`.
4. **Watchdog cron repeats=\"once\"** — Make sure to pass `repeat` or explicitly set it to forever; otherwise the cron job self-terminates after one run.

## Verification Checklist

- [ ] `API_SERVER_ENABLED=true` and `API_SERVER_KEY` set in `.env`
- [ ] `ss -tlnp | grep 8642` shows the API server listening
- [ ] `curl http://127.0.0.1:8642/health` returns `{\"status\":\"ok\"}`
- [ ] Dashboard is running: `ss -tlnp | grep 9119` or `hermes dashboard --status`
- [ ] `curl http://127.0.0.1:9119/api/status` returns version + gateway status
- [ ] Watchdog cron job created with `no_agent=True` and `repeat=\"forever\"`
- [ ] Watchdog script is executable: `ls -la \"$HERMES_HOME/scripts/dashboard-watchdog.sh\"`
- [ ] SSH tunnel works: `ssh -L 9119:127.0.0.1:9119 -L 8642:127.0.0.1:8642 root@<vps-ip>`
- [ ] Browser at `http://localhost:9119` loads the dashboard UI
- [ ] Dashboard notifies on restart (non-empty stdout from watchdog script)
