#!/usr/bin/env bash
# cli-roundtable test runner
# Peer files: .roundtable/peers/{name}.{type}.yml + .conf
# Config: config.yml at root
# Agent volumes: .roundtable/volumes/
#
# Run from repo root or from .tests/ — auto-detects repo root.

set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

PASS=0 FAIL=0 SKIP=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

pass() { PASS=$((PASS+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { FAIL=$((FAIL+1)); echo -e "  ${RED}✗${NC} $1"; }
skip() { SKIP=$((SKIP+1)); echo -e "  ${YELLOW}⊘${NC} $1"; }

cleanup() {
  sudo ./roundtable wg peer rm --type agent a-test 2>/dev/null || true
  sudo ./roundtable wg peer rm --type agent b-test 2>/dev/null || true
  sudo ./roundtable wg peer rm c-test 2>/dev/null || true
  sudo ./roundtable wg leave loopback 2>/dev/null || true
  sudo ./roundtable wg peer rm --type agent persist-test 2>/dev/null || true
  sudo ./roundtable wg peer rm restore-test 2>/dev/null || true
  sudo ./roundtable wg peer rm ssh-test 2>/dev/null || true
  sudo userdel -r roundtable 2>/dev/null || true
  sudo rm -f /etc/ssh/sshd_config.d/99-roundtable.conf /etc/sudoers.d/99-roundtable
  rm -f /tmp/host-a.yml /tmp/host-a-2.yml /tmp/bad.yml /tmp/invite-test.yml
}

trap cleanup EXIT

echo ""
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   cli-roundtable — Test Runner            ║"
echo "  ╚═══════════════════════════════════════════╝"
echo ""

# ── Phase 0: Pre-flight ──
echo "── Phase 0: Pre-flight ──"

bash -n roundtable && pass "0.1 Bash syntax check" || fail "0.1 Bash"
test -x roundtable && pass "0.2 Script executable" || fail "0.2 Executable"
test -f config.example.yml && pass "0.3 Config template" || fail "0.3 Template"
test -f config.yml && pass "0.4 Active config" || fail "0.4 Config"
yq eval '.' config.yml >/dev/null 2>&1 && pass "0.5 Config is valid YAML" || fail "0.5 YAML"
[[ -n "$(yq '.network.host // ""' config.yml 2>/dev/null)" ]] && pass "0.6 Config has network.host" || fail "0.6 host"
yq '.network.wg.subnets.agents // ""' config.yml | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.0/24$' && pass "0.7 Agents subnet" || fail "0.7 Agents subnet"
yq --version 2>&1 | grep -qi mikefarah && pass "0.8 yq is mikefarah" || fail "0.8 yq"
command -v wg &>/dev/null && pass "0.9 wireguard-tools" || fail "0.9 wg"
lxc list &>/dev/null && pass "0.10 LXD running" || fail "0.10 LXD"
ip link show wg0 &>/dev/null && pass "0.11 wg0 exists" || fail "0.11 wg0"
test -f .roundtable/ip-pool && pass "0.12 IP pool" || fail "0.12 pool"
test -d .roundtable/peers && pass "0.13 Peers dir" || fail "0.13 peers"
! git check-ignore config.example.yml &>/dev/null && pass "0.14 Config not gitignored" || fail "0.14 gitignored"
command -v ssh-keygen &>/dev/null && pass "0.15 ssh-keygen" || fail "0.15 ssh-keygen"
command -v ssh &>/dev/null && pass "0.16 ssh client" || fail "0.16 ssh"

# ── Phase 1: wg state ──
echo ""
echo "── Phase 1: wg state ──"

WG0_IP=$(ip addr show wg0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
[[ -n "$WG0_IP" ]] && pass "1.1 wg0 IP: $WG0_IP" || fail "1.1 wg0 IP"
WG_PORT=$(wg show wg0 listen-port 2>/dev/null || echo "")
[[ "$WG_PORT" == "$(yq '.network.wg.port // 51820' config.yml)" ]] && pass "1.2 wg0 port: $WG_PORT" || fail "1.2 wg0 port"
head -3 .roundtable/ip-pool | grep -qv '^#' && pass "1.3 IP pool ready" || fail "1.3 pool"
[[ -s /etc/wireguard/publickey ]] && pass "1.4 Host pubkey" || fail "1.4 pubkey"
systemctl is-enabled wg-quick@wg0 &>/dev/null && pass "1.5 wg-quick enabled" || fail "1.5 wg-quick"
[[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] && pass "1.6 IP forwarding" || fail "1.6 forwarding"
test -f .roundtable/foreign-ip-pool && pass "1.7 Foreign pool exists" || fail "1.7 foreign pool"

# ── Phase 2A: Foreign peer lifecycle ──
echo ""
echo "── Phase 2A: Foreign peer lifecycle ──"

out=$(sudo ./roundtable wg peer new c-test 2>&1)
echo "$out" | grep -q "foreign" && pass "2A.1 Create foreign (default)" || fail "2A.1 Create: $out"
test -f .roundtable/peers/c-test.foreign.yml && pass "2A.2 Foreign record" || fail "2A.2 record"
test -f .roundtable/peers/c-test.foreign.conf && pass "2A.3 Foreign config" || fail "2A.3 config"
[[ "$(yq '.type' .roundtable/peers/c-test.foreign.yml)" == "foreign" ]] && pass "2A.4 type=foreign" || fail "2A.4 type"
[[ "$(yq '.ip' .roundtable/peers/c-test.foreign.yml)" =~ ^10\.0\.2\. ]] && pass "2A.5 Foreign subnet" || fail "2A.5 subnet"
wg show wg0 | grep -qF "$(yq '.public_key' .roundtable/peers/c-test.foreign.yml)" && pass "2A.6 In wg0" || fail "2A.6 wg0"
out=$(sudo ./roundtable wg peer config c-test 2>&1)
echo "$out" | grep -q "Address" && pass "2A.7 Config retrievable" || fail "2A.7 config: $out"
sudo ./roundtable wg peers 2>&1 | grep c-test | grep -q foreign && pass "2A.8 wg peers foreign" || fail "2A.8 peers"
out=$(sudo ./roundtable wg peer new c-test 2>&1 || true)
echo "$out" | grep -q "already exists" && pass "2A.9 Duplicate detection" || fail "2A.9 dup: $(echo "$out" | head -1)"
# Route persistence check
peer_ip=$(yq '.ip' .roundtable/peers/c-test.foreign.yml)
ip route show dev wg0 | grep -q "$peer_ip" && pass "2A.10 Route installed: $peer_ip" || fail "2A.10 route for $peer_ip"
grep -q "# peer:c-test:foreign" /etc/wireguard/wg0.conf && pass "2A.11 Config section persisted" || fail "2A.11 config section"
out=$(sudo ./roundtable wg peer rm c-test 2>&1)
echo "$out" | grep -qi "removed" && pass "2A.12 rm foreign" || fail "2A.12 rm: $out"
test ! -f .roundtable/peers/c-test.foreign.yml && pass "2A.13 Record deleted" || fail "2A.13 record"
test ! -f .roundtable/peers/c-test.foreign.conf && pass "2A.14 Config deleted" || fail "2A.14 config"
! ip route show dev wg0 | grep -q "$peer_ip" && pass "2A.15 Route removed" || fail "2A.15 route still present"
! grep -q "peer:c-test" /etc/wireguard/wg0.conf && pass "2A.16 Config section cleaned" || fail "2A.16 config still has section"

# ── SSH access test ──
out=$(sudo ./roundtable wg peer new --type foreign ssh-test 2>&1)
echo "$out" | grep -q "SSH:" && pass "2A.17 SSH command printed" || fail "2A.17: $(echo "$out" | head -1)"
host_ip=$(ip addr show wg0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
echo "$out" | grep -q "ssh.*@${host_ip}" && pass "2A.18 SSH target is WG mesh IP (${host_ip})" || fail "2A.18 ssh target"
test -f .roundtable/peers/ssh-test.foreign.ssh-key && pass "2A.19 SSH private key saved" || fail "2A.19 ssh-key"
test -f .roundtable/peers/ssh-test.foreign.ssh-key.pub && pass "2A.20 SSH public key saved" || fail "2A.20 ssh-key.pub"
id roundtable &>/dev/null && pass "2A.21 roundtable user exists" || fail "2A.21 user"
echo "$(sudo cat /etc/sudoers.d/99-roundtable)" | grep -q "NOPASSWD:ALL" && pass "2A.22 Passwordless sudo" || fail "2A.22 sudo"
grep -q "roundtable" /home/roundtable/.ssh/authorized_keys && pass "2A.23 SSH key in authorized_keys" || fail "2A.23 authorized_keys"
test -f /etc/ssh/sshd_config.d/99-roundtable.conf && pass "2A.24 sshd Match block installed" || fail "2A.24 match block"
grep -q "Address 10.0.0.0/8" /etc/ssh/sshd_config.d/99-roundtable.conf && pass "2A.25 Match restricts to WG subnet" || fail "2A.25 subnet match"
out=$(sudo ./roundtable wg peer rm ssh-test 2>&1)
echo "$out" | grep -qi "removed" && pass "2A.26 Cleanup ssh-test" || fail "2A.26: $out"
! grep -q "peer:ssh-test" /home/roundtable/.ssh/authorized_keys && pass "2A.27 SSH key removed from authorized_keys" || fail "2A.27 key still present"
! test -f .roundtable/peers/ssh-test.foreign.ssh-key && pass "2A.28 SSH key files cleaned" || fail "2A.28 ssh-key files still exist"

# ── Phase 2B: Agent peer lifecycle ──
echo ""
echo "── Phase 2B: Agent peer lifecycle ──"

out=$(sudo ./roundtable wg peer new --type agent a-test 2>&1)
echo "$out" | grep -q "agent" && pass "2B.1 Create agent" || fail "2B.1 Create: $out"
test -f .roundtable/peers/a-test.agent.yml && pass "2B.2 Agent record" || fail "2B.2 record"
test -f .roundtable/peers/a-test.agent.conf && pass "2B.3 Agent config" || fail "2B.3 config"
[[ "$(yq '.type' .roundtable/peers/a-test.agent.yml)" == "agent" ]] && pass "2B.4 type=agent" || fail "2B.4 type"
[[ "$(yq '.ip' .roundtable/peers/a-test.agent.yml)" =~ ^10\.0\.1\. ]] && pass "2B.5 Agent subnet" || fail "2B.5 subnet"
grep -q "PostUp" .roundtable/peers/a-test.agent.conf && pass "2B.6 PostUp fix" || fail "2B.6 PostUp"
grep -q "AllowedIPs = 10.0.0.0/8" .roundtable/peers/a-test.agent.conf && pass "2B.7 AllowedIPs" || fail "2B.7 AllowedIPs"
out=$(sudo ./roundtable wg peer config --type agent a-test 2>&1)
echo "$out" | grep -q "Address" && pass "2B.8 Agent config retrieve" || fail "2B.8 config: $out"
sudo ./roundtable wg peers 2>&1 | grep a-test | grep -q agent && pass "2B.9 wg peers agent" || fail "2B.9 peers"
# Agent route persistence
agent_ip=$(yq '.ip' .roundtable/peers/a-test.agent.yml)
ip route show dev wg0 | grep -q "$agent_ip" && pass "2B.10 Agent route: $agent_ip" || fail "2B.10 agent route"
grep -q "# peer:a-test:agent" /etc/wireguard/wg0.conf && pass "2B.11 Agent config persisted" || fail "2B.11 config section"
out=$(sudo ./roundtable wg peer new --type agent b-test 2>&1)
echo "$out" | grep -q "agent" && pass "2B.12 Second agent" || fail "2B.12: $out"
[[ "$(yq '.ip' .roundtable/peers/b-test.agent.yml)" =~ ^10\.0\.1\. ]] && pass "2B.13 Second subnet" || fail "2B.13 subnet"
count=$(sudo ./roundtable wg peers 2>&1 | grep -c "agent" || true)
[[ "$count" -ge 2 ]] && pass "2B.14 Both agents visible ($count)" || fail "2B.14 count=$count"
# Clean up agents
out=$(sudo ./roundtable wg peer rm --type agent a-test 2>&1)
echo "$out" | grep -qi "removed" && pass "2B.15 rm agent a" || fail "2B.15: $out"
test ! -f .roundtable/peers/a-test.agent.yml && pass "2B.16 Agent record deleted" || fail "2B.16 record"
test ! -f .roundtable/peers/a-test.agent.conf && pass "2B.17 Agent config deleted" || fail "2B.17 config"
! ip route show dev wg0 | grep -q "$agent_ip" && pass "2B.18 Agent route removed" || fail "2B.18 route still present"
! grep -q "peer:a-test" /etc/wireguard/wg0.conf && pass "2B.19 Agent config cleaned" || fail "2B.19 config still present"
out=$(sudo ./roundtable wg peer rm --type agent b-test 2>&1)
echo "$out" | grep -qi "removed" && pass "2B.20 rm agent b" || fail "2B.20: $out"

# ── Phase 2C: Edge cases ──
echo ""
echo "── Phase 2C: Edge cases ──"

out=$(sudo ./roundtable wg peer new 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "2C.1 peer new without name" || fail "2C.1: $(echo "$out" | head -1)"
out=$(sudo ./roundtable wg peer config --type agent nonexistent 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "2C.2 config nonexistent" || fail "2C.2: $(echo "$out" | head -1)"
out=$(sudo ./roundtable wg peer rm --type agent nonexistent 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "2C.3 rm nonexistent agent" || fail "2C.3: $(echo "$out" | head -1)"
out=$(sudo ./roundtable wg peer rm nonexistent 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "2C.4 rm nonexistent foreign" || fail "2C.4: $(echo "$out" | head -1)"

# ── Phase 3: Invite/join/leave ──
echo ""
echo "── Phase 3: Invite/join/leave ──"

./roundtable wg invite > /tmp/host-a.yml && pass "3.1 Generate invite" || fail "3.1 invite"
yq eval '.' /tmp/host-a.yml &>/dev/null && pass "3.2 Invite valid YAML" || fail "3.2 YAML"
[[ -n "$(yq '.public_key' /tmp/host-a.yml)" ]] && pass "3.3 Invite has pubkey" || fail "3.3 pubkey"
[[ "$(yq '.endpoint' /tmp/host-a.yml)" =~ :[0-9]+$ ]] && pass "3.4 Invite endpoint:port" || fail "3.4 endpoint"
agents_invite=$(yq '.agents' /tmp/host-a.yml)
agents_config=$(yq '.network.wg.subnets.agents' config.yml)
[[ "$agents_invite" == "$agents_config" && -n "$agents_invite" ]] && pass "3.5 Invite agents=$agents_invite" || fail "3.5 agents: $agents_invite vs $agents_config"
[[ -n "$(yq '.foreign' /tmp/host-a.yml)" ]] && pass "3.6 Invite foreign" || fail "3.6 foreign"
[[ -n "$(yq '.cluster' /tmp/host-a.yml)" ]] && pass "3.7 Invite cluster" || fail "3.7 cluster"
./roundtable wg invite > /tmp/host-a-2.yml
diff /tmp/host-a.yml /tmp/host-a-2.yml &>/dev/null && pass "3.8 Invite idempotent" || fail "3.8 idempotent"
out=$(sudo ./roundtable wg join loopback /tmp/host-a.yml 2>&1)
echo "$out" | grep -qE "(Joined|already connected)" && pass "3.9 Join self-invite" || fail "3.9 join: $out"
test -f .roundtable/peers/loopback.host.yml && pass "3.10 Host record created" || fail "3.10 host record"
[[ "$(yq '.type' .roundtable/peers/loopback.host.yml)" == "host" ]] && pass "3.11 Host type=host" || fail "3.11 host type"
sudo ./roundtable wg peers 2>&1 | grep loopback | grep -q host && pass "3.12 wg peers host" || fail "3.12 host peers"
# Cluster route persistence: agents subnet should be routed via wg0
agents_sub=$(yq '.subnets.agents' .roundtable/peers/loopback.host.yml)
ip route show dev wg0 | grep -q "$agents_sub" && pass "3.13 Cluster subnet route: $agents_sub" || fail "3.13 cluster subnet route"
grep -q "# peer:loopback:host" /etc/wireguard/wg0.conf && pass "3.14 Host config persisted" || fail "3.14 host config section"
out=$(sudo ./roundtable wg leave loopback 2>&1)
echo "$out" | grep -q "Leaving" && pass "3.15 Leave peer" || fail "3.15 leave: $out"
test ! -f .roundtable/peers/loopback.host.yml && pass "3.16 Host record cleaned" || fail "3.16 cleaned"
! ip route show dev wg0 | grep -q "$agents_sub" && pass "3.17 Cluster route removed" || fail "3.17 cluster route still present"
! grep -q "peer:loopback" /etc/wireguard/wg0.conf && pass "3.18 Host config cleaned" || fail "3.18 config still has host section"
out=$(sudo ./roundtable wg leave nonexistent 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "3.19 Leave nonexistent" || fail "3.19: $(echo "$out" | head -1)"
echo "bad: yaml" > /tmp/bad.yml
out=$(sudo ./roundtable wg join broken /tmp/bad.yml 2>&1 || true)
echo "$out" | grep -qi "missing" && pass "3.20 Malformed invite error" || fail "3.20: $(echo "$out" | head -1)"

# ── Phase 4: Golden image (skip) ──
echo ""
echo "── Phase 4: Golden image ──"
skip "4.1-4.6 Golden image (manual — ~3-4 min build)"

# ── Phase 5: Agent lifecycle (wg portion only) ──
echo ""
echo "── Phase 5: Agent lifecycle ──"
if lxc image alias list 2>/dev/null | grep -q roundtable-agent; then
  pass "5.0 Golden image exists"
  out=$(sudo ./roundtable wg peer new --type agent agent-test 2>&1)
  echo "$out" | grep -q "agent" && pass "5.1 Create agent peer" || fail "5.1: $out"
  test -f .roundtable/peers/agent-test.agent.conf && pass "5.2 Agent config saved" || fail "5.2 config"
  grep -q "PostUp" .roundtable/peers/agent-test.agent.conf && pass "5.3 Agent PostUp fix" || fail "5.3 PostUp"
  out=$(sudo ./roundtable wg peer rm --type agent agent-test 2>&1)
  echo "$out" | grep -qi "removed" && pass "5.4 Cleanup agent" || fail "5.4: $out"
else
  skip "5.0-5.4 No golden image — skip agent lifecycle"
fi

# ── Phase 6: Host checks ──
echo ""
echo "── Phase 6: Host checks ──"

out=$(sudo ./roundtable check 2>&1)
echo "$out" | grep -q "All checks passed" && pass "6.1 check passes" || fail "6.1 check"
echo "$out" | grep -qi "mikefarah" && pass "6.2 yq check" || fail "6.2 yq"
echo "$out" | grep -q "config.yml" && pass "6.3 Config check" || fail "6.3 config"
echo "$out" | grep -qi "forward" && pass "6.4 Forwarding check" || fail "6.4 forward"
echo "$out" | grep -qi "swap" && pass "6.5 Swap check" || fail "6.5 swap"
echo "$out" | grep -qi "Python" && pass "6.6 Python check" || fail "6.6 Python"

# ── Phase 7: Reboot resilience ──
echo ""
echo "── Phase 7: Reboot resilience ──"

out=$(sudo ./roundtable wg peer new --type agent persist-test 2>&1)
echo "$out" | grep -q "agent" && pass "7.1 Create persist peer" || fail "7.1: $out"
# State on disk
test -f .roundtable/peers/persist-test.agent.yml && pass "7.2 Peer record on disk" || fail "7.2 peer record"
test -f .roundtable/peers/persist-test.agent.conf && pass "7.3 Peer config on disk" || fail "7.3 peer config"
test -f .roundtable/ip-pool && pass "7.4 IP pool on disk" || fail "7.4 ip pool"
# Route is installed
persist_ip=$(yq '.ip' .roundtable/peers/persist-test.agent.yml)
ip route show dev wg0 | grep -q "$persist_ip" && pass "7.5 Route installed: $persist_ip" || fail "7.5 route installed"
# Peer section in wg-quick config
grep -q "# peer:persist-test:agent" /etc/wireguard/wg0.conf && pass "7.6 Config section persisted" || fail "7.6 config section"
# wg-quick strip preserves the peer for boot restoration
wg-quick strip /etc/wireguard/wg0.conf 2>/dev/null | grep -q "persist-test" && pass "7.7 wg-quick strip preserves peer" || fail "7.7 wg-quick strip"
# Config retrievable
sudo ./roundtable wg peer config --type agent persist-test > /dev/null 2>&1 && pass "7.8 Config retrievable from disk" || fail "7.8 config retrieve"
# Cleanup
out=$(sudo ./roundtable wg peer rm --type agent persist-test 2>&1)
echo "$out" | grep -qi "removed" && pass "7.9 Cleanup persist" || fail "7.9: $out"
# Verify cleanup
! ip route show dev wg0 | grep -q "$persist_ip" && pass "7.10 Route removed" || fail "7.10 route still present"
! grep -q "peer:persist-test" /etc/wireguard/wg0.conf && pass "7.11 Config section cleaned" || fail "7.11 config still has section"

# ── Phase 8: Restore command ──
echo ""
echo "── Phase 8: Restore command ──"

# Run restore on empty state (should be a no-op)
out=$(sudo ./roundtable wg restore 2>&1)
echo "$out" | grep -q "0 peers processed" && pass "8.1 Restore on empty state" || fail "8.1: $out"

# Create a foreign peer
out=$(sudo ./roundtable wg peer new restore-test 2>&1)
echo "$out" | grep -q "foreign" && pass "8.2 Create restore-test" || fail "8.2: $(echo "$out" | head -1)"

restore_ip=$(yq '.ip' .roundtable/peers/restore-test.foreign.yml)
restore_conf_sec=$(grep -c "# peer:restore-test:foreign" /etc/wireguard/wg0.conf || true)

# Run restore (should skip — already synced)
out=$(sudo ./roundtable wg restore 2>&1)
echo "$out" | grep -q "already current" && pass "8.3 Restore idempotent (skips existing)" || fail "8.3: $out"

# Simulate old state: remove config section + route
sudo sed -i "/# peer:restore-test:foreign/,+5d" /etc/wireguard/wg0.conf
sudo ip route del "${restore_ip}/32" dev wg0 2>/dev/null || true
! grep -q "restore-test" /etc/wireguard/wg0.conf && pass "8.4 Config removed (simulated old state)" || fail "8.4 config still present"
! ip route show dev wg0 | grep -q "$restore_ip" && pass "8.5 Route removed" || fail "8.5 route still present"

# Restore should re-add config + route
out=$(sudo ./roundtable wg restore 2>&1)
echo "$out" | grep -q "config.*added foreign" && pass "8.6 Restore re-adds config section" || fail "8.6: $out"
grep -q "# peer:restore-test:foreign" /etc/wireguard/wg0.conf && pass "8.7 Config present after restore" || fail "8.7 config missing"
ip route show dev wg0 | grep -q "$restore_ip" && pass "8.8 Route present after restore" || fail "8.8 route missing"

# Second run should skip (idempotent)
out=$(sudo ./roundtable wg restore 2>&1)
echo "$out" | grep -q "already current" && pass "8.9 Re-restore idempotent" || fail "8.9: $out"

# Cleanup
out=$(sudo ./roundtable wg peer rm restore-test 2>&1)
echo "$out" | grep -qi "removed" && pass "8.10 Cleanup restore-test" || fail "8.10: $out"
! grep -q "peer:restore-test" /etc/wireguard/wg0.conf && pass "8.11 Config cleaned" || fail "8.11 config still present"
! ip route show dev wg0 | grep -q "$restore_ip" && pass "8.12 Route cleaned" || fail "8.12 route still present"

# ── Summary ──
echo ""
echo "  ╔═══════════════════════════════════════════╗"
printf "  ║   Results:  %3d pass  %3d fail  %3d skip    ║\n" $PASS $FAIL $SKIP
echo "  ╚═══════════════════════════════════════════╝"
echo ""

[[ "$FAIL" -eq 0 ]] && echo "  ✅ All tests passed." || echo "  ❌ $FAIL test(s) failed."
exit $FAIL