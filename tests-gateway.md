# Gateway test roadmap

## Prerequisites

All tests assume a functioning cli-roundtable cluster:

- Host prepared (`roundtable prepare --fix`)
- VPN running (`roundtable wg up`)
- Golden image built (`roundtable golden-image build v2026.5.29.2`)
- A test agent exists, started, and set up (`agent create`, `agent start`, `agent setup`)

The `agent gateway up|down` command manages the **Hermes messaging gateway** — a user systemd service that connects the agent to messaging platforms (Discord, Telegram, etc.). It is **not** the same as `hermes dashboard` (port 9119) or an API server — those are separate commands.

One-time: create the test agent:

```bash
sudo ./roundtable agent create test-gw
sudo ./roundtable agent start test-gw
sudo ./roundtable agent setup test-gw
# Set an API key inside the container so the gateway can start:
lxc exec roundtable-test-gw -- sed -i 's/^# OPENROUTER_API_KEY=.*/OPENROUTER_API_KEY=your-key/' /root/.hermes/.env
```

---

## Phase 1 — Gateway up

**Goal:** Verify `agent gateway up` installs, starts, and enables the messaging gateway.

### Prep

Ensure agent is running:

```bash
sudo ./roundtable agent list | grep test-gw
```

### Run

```bash
sudo ./roundtable agent gateway up test-gw
```

### Verify

```bash
# 1. Gateway status via hermes CLI — shows loaded, enabled, running
lxc exec roundtable-test-gw -- hermes gateway status

# 2. User systemd unit exists and is enabled (check via file)
lxc exec roundtable-test-gw -- ls -la /root/.config/systemd/user/default.target.wants/hermes-gateway.service

# 3. Process is running
lxc exec roundtable-test-gw -- ps aux | grep 'hermes.*gateway' | grep -v grep

# 4. Systemd linger is enabled (survives logout/reboot)
lxc exec roundtable-test-gw -- loginctl show-user root | grep Linger
```

### Clean

None — leave gateway running for next phases.

---

## Phase 2 — Idempotency (gateway up when already up)

**Goal:** Running `gateway up` on an already-running gateway is harmless.

### Prep

Gateway must be running from Phase 1.

### Run

```bash
sudo ./roundtable agent gateway up test-gw
```

### Verify

- Command exits cleanly (no errors)
- Gateway still running (check via `hermes gateway status`)
- Journal log shows it detected existing service (no duplicate installs)

### Clean

None.

---

## Phase 3 — Gateway down

**Goal:** Verify `agent gateway down` stops the gateway cleanly.

### Prep

Gateway running from Phase 1.

### Run

```bash
sudo ./roundtable agent gateway down test-gw
```

### Verify

```bash
# 1. Gateway status shows not running
lxc exec roundtable-test-gw -- hermes gateway status | head -5

# 2. Process is gone
lxc exec roundtable-test-gw -- ps aux | grep 'hermes.*gateway' | grep -v grep || echo "no process (expected)"
```

### Clean

None — gateway is stopped.

---

## Phase 4 — Gateway down when already down

**Goal:** Running `gateway down` on a stopped gateway is harmless.

### Prep

Gateway must be stopped from Phase 3.

### Run

```bash
sudo ./roundtable agent gateway down test-gw
```

### Verify

- Command exits cleanly (no errors)
- No change in state (still stopped)

### Clean

Bring gateway back up for next phase:

```bash
sudo ./roundtable agent gateway up test-gw
```

---

## Phase 5 — Persistence across container restart

**Goal:** Gateway survives an agent container restart via user systemd service + linger.

### Prep

Gateway running from Phase 4 clean step.

### Run

```bash
sudo ./roundtable agent restart test-gw
# Wait for container to fully boot
sleep 15
```

### Verify

```bash
# 1. Container is running
sudo ./roundtable agent list | grep test-gw | grep -i running

# 2. Gateway status shows it auto-started
lxc exec roundtable-test-gw -- hermes gateway status | head -10

# 3. Journal shows service started after boot
lxc exec roundtable-test-gw -- journalctl --user -u hermes-gateway --no-pager -n 5
```

### Clean

None — leave gateway running.

---

## Phase 6 — Cleanup

**Goal:** Remove the test agent.

### Run

```bash
sudo ./roundtable agent delete test-gw
```

### Verify

```bash
# Container gone
sudo ./roundtable agent list | grep test-gw || echo "deleted (expected)"

# WG peer gone
sudo ./roundtable wg peer list | grep test-gw || echo "peer removed (expected)"

# Files cleaned
ls .agents/test-gw 2>/dev/null && echo "UNEXPECTED" || echo "volume cleaned (expected)"
```

### Clean

Done.