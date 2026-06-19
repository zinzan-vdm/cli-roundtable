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
- [x] **Prep:** Golden image exists + wg-easy up
- [x] **Run:** `sudo ./roundtable agent create test-1`
- [x] **Verify:** `lxc list roundtable-test-1` → RUNNING
- [x] **Verify:** `ls -la .agents/test-1/volume/` → exists
- [x] **Verify:** `lxc exec roundtable-test-1 -- cat /etc/wireguard/wg0.conf` → non-empty
- [x] **Verify:** `sudo ./roundtable wg peer list` → shows test-1
- [x] **Clean:** `sudo ./roundtable agent delete test-1`

## Phase 4 — Agent Lifecycle
- [x] **Prep:** Create `sudo ./roundtable agent create test-1`
- [x] **Run:** `sudo ./roundtable agent stop test-1` → STOPPED
- [x] **Run:** `sudo ./roundtable agent start test-1` → RUNNING
- [x] **Run:** `sudo ./roundtable agent restart test-1` → RUNNING
- [x] **Run:** `sudo ./roundtable agent shell test-1` → echo ok
- [x] **Run:** `sudo ./roundtable agent logs test-1` → no error
- [x] **Run:** `sudo ./roundtable agent setup test-1` → runs hermes setup
- [x] **Clean:** Deleted in Phase 3

## Phase 5 — Hermes Gateway Inside Agent
- [x] **Prep:** Agent running + configured API key
- [x] **Run:** `hermes gateway install --system --force --run-as-user root` → service active
- [x] **Verify:** `ss -tlnp | grep 8642` → listening
- [x] **Verify:** `curl http://localhost:8642/health` → HTTP 200
- [x] **Clean:** Deleted in Phase 6

## Phase 6 — Full Tear Down
- [x] **Run:** Delete all agents → test-1 deleted
- [x] **Run:** `sudo ./roundtable wg down` → wg-easy removed
- [x] **Run:** Delete golden image → roundtable-agent removed
- [x] **Verify:** No orphaned containers or volumes → clean

---

## Issues Log

| Phase | Date | Issue | Resolution |
|-------|------|-------|------------|
| 0 | 19 Jun | unsquashfs OOM-killed on 4GB host | Added 1GB swap file |
| 1 | 19 Jun | LXD container no outbound network | Added iptables DOCKER-USER rules for lxdbr0 |
| 1 | 19 Jun | golden image publish timeout at 300s | Increased image build timeout to 600s |
| 2 | 19 Jun | Docker snap can't access /opt | Switched to apt docker.io |
| 2 | 19 Jun | wg-easy v14 requires PASSWORD_HASH | Switched from PASSWORD to bcrypt PASSWORD_HASH |
| 2 | 19 Jun | compose IP 10.10.0.1 conflicts with bridge gateway | Changed container to 10.10.0.2 |
| 3 | 19 Jun | LXD rejects 768M memory format | Fixed to 768MB |
| 3 | 19 Jun | wg-easy v14 API uses UUID not name for config | Updated script to resolve UUID via Python |
| 3 | 19 Jun | .env $ signs corrupt on source | Single-quote bcrypt hash values in .env |
| 5 | 19 Jun | gateway install requires --run-as-user root in LXC | Added --run-as-user root flag |
