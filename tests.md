# Test Plan: cli-roundtable

## Status Legend
- [ ] Not started
- [~] In progress
- [x] Passed
- [!] Failed / Blocked

---

## Phase 0 — Environment Sanity
- [x] **Prep:** Check free disk + LXD pool
- [x] **Run:** `lxc launch ubuntu:24.04 tmp-verify && lxc exec tmp-verify -- echo ok`
- [x] **Clean:** `lxc delete tmp-verify --force`

## Phase 1 — Golden Image Build
- [x] **Prep:** Source .env
- [x] **Run:** `sudo ./roundtable image-base build v2026.5.29.2`
- [x] **Verify:** `lxc image list roundtable-agent` → 1415.16MiB

## Phase 2 — VPN (wg-easy)
- [x] **Prep:** .env has WG_HOST + WG_PASSWORD_HASH
- [x] **Run:** `sudo ./roundtable wg up`
- [x] **Verify:** `docker ps --filter name=wg-easy` → Up (health: starting)
- [x] **Verify:** `ss -tlnp | grep 51821` → absent
- [x] **Verify:** Dashboard accessible on Docker internal net → HTTP 200

## Phase 3 — Agent Creation
- [ ] **Prep:** Golden image exists + wg-easy up
- [ ] **Run:** `sudo ./roundtable agent create test-1`
- [ ] **Verify:** `lxc list roundtable-test-1` → RUNNING
- [ ] **Verify:** `ls -la .agents/test-1/volume/` → exists
- [ ] **Verify:** `lxc exec roundtable-test-1 -- cat /etc/wireguard/wg0.conf` → non-empty
- [ ] **Verify:** `sudo ./roundtable wg peer list` → shows test-1
- [ ] **Clean:** `sudo ./roundtable agent delete test-1`

## Phase 4 — Agent Lifecycle
- [ ] **Prep:** Create `sudo ./roundtable agent create test-2`
- [ ] **Run:** `sudo ./roundtable agent stop test-2` → STOPPED
- [ ] **Run:** `sudo ./roundtable agent start test-2` → RUNNING
- [ ] **Run:** `sudo ./roundtable agent restart test-2` → RUNNING
- [ ] **Run:** `sudo ./roundtable agent shell test-2` → echo ok
- [ ] **Run:** `sudo ./roundtable agent logs test-2` → no error
- [ ] **Run:** `sudo ./roundtable agent setup test-2` → runs hermes setup
- [ ] **Clean:** `sudo ./roundtable agent delete test-2`

## Phase 5 — Hermes Gateway Inside Agent
- [ ] **Prep:** Create + setup agent (test-3)
- [ ] **Run:** Start Hermes gateway inside agent
- [ ] **Verify:** Dashboard responds on WG IP
- [ ] **Verify:** Dashboard NOT accessible outside VPN
- [ ] **Clean:** `sudo ./roundtable agent delete test-3`

## Phase 6 — Full Tear Down
- [ ] **Run:** Delete all agents
- [ ] **Run:** `sudo ./roundtable wg down`
- [ ] **Run:** Delete golden image
- [ ] **Verify:** No orphaned containers or volumes

---

## Issues Log

| Phase | Date | Issue | Resolution |
|-------|------|-------|------------|
| — | — | — | — |
