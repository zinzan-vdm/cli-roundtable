# Gateway test roadmap

## Prerequisites

All tests assume a functioning cli-roundtable cluster:

- Host prepared (`roundtable prepare --fix`)
- VPN running (`roundtable wg up`)
- Golden image built (`roundtable golden-image build v2026.5.29.2`)
- A test agent exists, started, and set up (`agent create`, `agent start`, `agent setup`)

One-time: create the test agent:

```bash
sudo ./roundtable agent create test-gw
sudo ./roundtable agent start test-gw
sudo ./roundtable agent setup test-gw
```

---

## Phase 1 — Gateway up

**Goal:** Verify `agent gateway up` installs, starts, and enables the gateway.

### Prep

Ensure agent is running:

```bash
sudo ./roundtable agent list | grep test-gw
```

Verify gateway is NOT already running (should fail or show inactive):

```bash
sudo ./roundtable agent gateway up test-gw 2>&1 || true
```

### Run

```bash
sudo ./roundtable agent gateway up test-gw
```

### Verify

```bash
# 1. Gateway systemd unit exists and is enabled
lxc exec roundtable-test-gw -- systemctl is-enabled hermes-gateway-*.service

# 2. Service is active (running)
lxc exec roundtable-test-gw -- systemctl is-active hermes-gateway-*.service

# 3. Hermes API responds on :8642
lxc exec roundtable-test-gw -- curl -sf http://127.0.0.1:8642/health 2>/dev/null || \
lxc exec roundtable-test-gw -- curl -sf http://127.0.0.1:8642 2>/dev/null || echo "check endpoint"

# 4. Hermes dashboard responds on :9119
lxc exec roundtable-test-gw -- curl -sf -o /dev/null http://127.0.0.1:9119 && echo "dashboard ok"

# 5. Gateway status via hermes CLI
lxc exec roundtable-test-gw -- hermes gateway status
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
- No duplicate systemd units or port conflicts

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
# 1. Service is stopped
lxc exec roundtable-test-gw -- systemctl is-active hermes-gateway-*.service 2>/dev/null || echo "inactive (expected)"

# 2. API endpoint no longer responds
lxc exec roundtable-test-gw -- curl -sf --connect-timeout 3 http://127.0.0.1:8642 2>/dev/null && echo "UNEXPECTED" || echo "API down (expected)"

# 3. Dashboard no longer responds
lxc exec roundtable-test-gw -- curl -sf --connect-timeout 3 http://127.0.0.1:9119 2>/dev/null && echo "UNEXPECTED" || echo "dashboard down (expected)"
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

**Goal:** Gateway survives an agent container restart.

### Prep

Gateway running from Phase 4 clean step.

### Run

```bash
sudo ./roundtable agent restart test-gw
# Wait for container to fully boot
sleep 10
```

### Verify

```bash
# 1. Container is running
sudo ./roundtable agent list | grep test-gw | grep -i running

# 2. Gateway service auto-started
lxc exec roundtable-test-gw -- systemctl is-active hermes-gateway-*.service

# 3. API endpoint responds
lxc exec roundtable-test-gw -- curl -sf http://127.0.0.1:8642 2>/dev/null && echo "API ok"

# 4. Dashboard responds
lxc exec roundtable-test-gw -- curl -sf -o /dev/null http://127.0.0.1:9119 && echo "dashboard ok"
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