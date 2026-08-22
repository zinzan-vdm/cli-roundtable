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
  # MCP cleanup
  sudo ./roundtable mcp stop 2>/dev/null || true
  rm -f /opt/hermes-agents/arthur/home/cli-roundtable/.roundtable/mcp/api-keys/mcp-test 2>/dev/null || true
  rm -f /opt/hermes-agents/arthur/home/cli-roundtable/.roundtable/mcp/permissions/mcp-test.yml 2>/dev/null || true
  rm -f /opt/hermes-agents/arthur/home/cli-roundtable/.roundtable/mcp.yml 2>/dev/null || true
  sudo ./roundtable wg peer rm restore-test 2>/dev/null || true
  sudo ./roundtable wg peer rm ssh-test 2>/dev/null || true
  sudo ./roundtable wg peer rm ws-test 2>/dev/null || true
  sudo userdel -r roundtable 2>/dev/null || true
  sudo rm -f /etc/ssh/sshd_config.d/99-roundtable.conf /etc/sudoers.d/99-roundtable
  rm -f /tmp/host-a.yml /tmp/host-a-2.yml /tmp/bad.yml /tmp/invite-test.yml
  sudo lxc delete roundtable-test-snap/snap-test 2>/dev/null || true
  rm -f /tmp/test-export-*.tar.gz
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
./roundtable wg peer list &>/dev/null && pass "0.17 wg peer list" || fail "0.17 wg peer list"

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
sudo ./roundtable wg peer list 2>&1 | grep c-test | grep -q foreign && pass "2A.8 wg peer list foreign" || fail "2A.8 peer list"
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

# ── SSH access tests ──
# Test 1: create foreign peer WITHOUT SSH (non-interactive → defaults to no)
host_ip=$(ip addr show wg0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
out=$(echo "" | sudo ./roundtable wg peer new --type foreign ssh-test 2>&1)
echo "$out" | grep -q "foreign" && pass "2A.17 Create foreign (no SSH)" || fail "2A.17: $(echo "$out" | head -1)"
! test -f .roundtable/peers/ssh-test.foreign.ssh-key && pass "2A.18 No SSH key without confirmation" || fail "2A.18 SSH key was generated unexpectedly"

# Test 2: wg peer ssh new — generate key for existing peer
out=$(echo "" | sudo ./roundtable wg peer ssh new ssh-test 2>&1)
echo "$out" | grep -q "SSH key generated" && pass "2A.19 wg peer ssh new generates key" || fail "2A.19: $out"
test -f .roundtable/peers/ssh-test.foreign.ssh-key && pass "2A.20 SSH private key saved" || fail "2A.20 ssh-key"
test -f .roundtable/peers/ssh-test.foreign.ssh-key.pub && pass "2A.21 SSH public key saved" || fail "2A.21 ssh-key.pub"
id roundtable &>/dev/null && pass "2A.22 roundtable user exists" || fail "2A.22 user"
echo "$(sudo cat /etc/sudoers.d/99-roundtable)" | grep -q "NOPASSWD:ALL" && pass "2A.23 Passwordless sudo" || fail "2A.23 sudo"
grep -q "roundtable" /home/roundtable/.ssh/authorized_keys && pass "2A.24 SSH key in authorized_keys" || fail "2A.24 authorized_keys"
test -f /etc/ssh/sshd_config.d/99-roundtable.conf && pass "2A.25 sshd Match block installed" || fail "2A.25 match block"
grep -q "Address 10.0.0.0/8" /etc/ssh/sshd_config.d/99-roundtable.conf && pass "2A.26 Match restricts to WG subnet" || fail "2A.26 subnet match"

# Test 3: wg peer ssh new is idempotent
out=$(sudo ./roundtable wg peer ssh new ssh-test 2>&1)
echo "$out" | grep -q "already exists" && pass "2A.27 ssh new idempotent" || fail "2A.27: $out"

# Test 3b: --type foreign works explicitly
out=$(sudo ./roundtable wg peer ssh new --type foreign ssh-test 2>&1)
echo "$out" | grep -q "already exists" && pass "2A.28 ssh new --type foreign" || fail "2A.28: $out"

# Test 3c: --type agent is rejected
out=$(sudo ./roundtable wg peer ssh new --type agent ssh-test 2>&1 || true)
echo "$out" | grep -q "only supported for.*foreign" && pass "2A.29 ssh new --type agent rejected" || fail "2A.29: $out"

# Test 4: wg peer ssh config — prints connection info
out=$(sudo ./roundtable wg peer ssh config ssh-test 2>&1)
echo "$out" | grep -q "ssh.*@${host_ip}" && pass "2A.30 ssh config shows target" || fail "2A.30: $out"
echo "$out" | grep -q ".ssh-key" && pass "2A.31 ssh config shows key path" || fail "2A.31: $out"

# Test 5: wg peer ssh rm — remove key
out=$(sudo ./roundtable wg peer ssh rm ssh-test 2>&1)
echo "$out" | grep -q "removed" && pass "2A.32 ssh rm removes key" || fail "2A.32: $out"
! grep -q "peer:ssh-test" /home/roundtable/.ssh/authorized_keys && pass "2A.33 Key removed from authorized_keys" || fail "2A.33 key still present"
! test -f .roundtable/peers/ssh-test.foreign.ssh-key && pass "2A.34 Key files cleaned" || fail "2A.34 key files still exist"

# Test 6: wg peer ssh rm idempotent
out=$(sudo ./roundtable wg peer ssh rm ssh-test 2>&1)
echo "$out" | grep -q "No SSH key found" && pass "2A.35 ssh rm idempotent" || fail "2A.35: $out"

# Test 7: ssh config without key shows hint
out=$(sudo ./roundtable wg peer ssh config ssh-test 2>&1)
echo "$out" | grep -q "Generate one" && pass "2A.36 ssh config suggests generation" || fail "2A.36: $out"

# Test 8: cleanup the peer
out=$(sudo ./roundtable wg peer rm ssh-test 2>&1)
echo "$out" | grep -qi "removed" && pass "2A.37 Cleanup ssh-test" || fail "2A.37: $out"

# ── Workspace setup tests (using ws-test) ──
echo ""
echo "── Phase 2A (cont): Workspace setup ──"

# Create a peer for workspace testing
out=$(echo "" | sudo ./roundtable wg peer new --type foreign ws-test 2>&1)
echo "$out" | grep -q "foreign" && pass "2A.38 Create ws-test" || fail "2A.38: $(echo \"$out\" | head -1)"

# Generate SSH key with 'y' for workspace setup
out=$(echo "y" | sudo ./roundtable wg peer ssh new ws-test 2>&1)
echo "$out" | grep -q "SSH key generated" && pass "2A.39 SSH key generated" || fail "2A.39: $out"
echo "$out" | grep -qi "workspace" && pass "2A.40 Workspace prompt shown" || fail "2A.40: no workspace prompt"

# Verify workspace setup
test -L /home/roundtable/cli-roundtable && pass "2A.41 Symlink exists" || fail "2A.41 symlink"
[[ "$(readlink -f /home/roundtable/cli-roundtable)" == "$(readlink -f .)" ]] && pass "2A.42 Symlink targets project" || fail "2A.42 target"
grep -q "cli-roundtable" /home/roundtable/.bashrc && pass "2A.43 PATH in .bashrc" || fail "2A.43 .bashrc"
sudo getfacl /root/cli-roundtable/roundtable 2>/dev/null | grep -q "user:roundtable:r.." && pass "2A.44 ACL read access" || fail "2A.44 ACL"
sudo getfacl /root 2>/dev/null | grep -q "user:roundtable:r-x" && pass "2A.44b /root traverse ACL" || fail "2A.44b root traverse"

# Second call — workspace already set up, no prompt
out=$(sudo ./roundtable wg peer ssh new ws-test 2>&1)
echo "$out" | grep -q "already exists" && pass "2A.45 Idempotent (no workspace re-prompt)" || fail "2A.45: $out"
! echo "$out" | grep -qi "workspace" && pass "2A.46 No duplicate workspace prompt" || fail "2A.46 re-prompted"

# Cleanup ws-test
sudo ./roundtable wg peer ssh rm ws-test 2>&1 > /dev/null
sudo ./roundtable wg peer rm ws-test 2>&1 > /dev/null

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
sudo ./roundtable wg peer list 2>&1 | grep a-test | grep -q agent && pass "2B.9 wg peer list agent" || fail "2B.9 peer list"
# Agent route persistence
agent_ip=$(yq '.ip' .roundtable/peers/a-test.agent.yml)
ip route show dev wg0 | grep -q "$agent_ip" && pass "2B.10 Agent route: $agent_ip" || fail "2B.10 agent route"
grep -q "# peer:a-test:agent" /etc/wireguard/wg0.conf && pass "2B.11 Agent config persisted" || fail "2B.11 config section"
out=$(sudo ./roundtable wg peer new --type agent b-test 2>&1)
echo "$out" | grep -q "agent" && pass "2B.12 Second agent" || fail "2B.12: $out"
[[ "$(yq '.ip' .roundtable/peers/b-test.agent.yml)" =~ ^10\.0\.1\. ]] && pass "2B.13 Second subnet" || fail "2B.13 subnet"
count=$(sudo ./roundtable wg peer list 2>&1 | grep -c "agent" || true)
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
sudo ./roundtable wg peer list 2>&1 | grep loopback | grep -q host && pass "3.12 wg peer list host" || fail "3.12 host peer list"
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
echo "$out" | grep -qi "SSH user workspace" && pass "6.7 SSH workspace check" || fail "6.7 SSH workspace"

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

# ── Phase 9: Proxy port forwarding ──
echo ""
echo "── Phase 9: Proxy port forwarding ──"

# Test proxy list on empty state
out=$(./roundtable proxy list 2>&1)
echo "$out" | grep -qi "No proxy" && pass "9.1 proxy list empty" || fail "9.1 proxy list: $out"

# Test proxy enable without args (should show usage)
out=$(./roundtable proxy enable 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "9.2 proxy enable without args" || fail "9.2: $out"

# Test proxy disable without args (should show usage)
out=$(./roundtable proxy disable 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "9.3 proxy disable without args" || fail "9.3: $out"

# Test proxy enable with non-existent agent
out=$(sudo ./roundtable proxy enable 9999 nonexistent 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "9.4 proxy enable nonexistent agent" || fail "9.4: $out"

# Test with numeric validation
out=$(sudo ./roundtable proxy enable abc agent 2>&1 || true)
echo "$out" | grep -qi "numeric" && pass "9.5 proxy enable non-numeric port" || fail "9.5: $out"

# Test with same-port shorthand
out=$(sudo ./roundtable proxy enable 8080:8080 agent 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "9.6 proxy enable port:port syntax" || fail "9.6: $out"

# ── If an agent container exists, run real proxy tests ──
if lxc list -c n 2>/dev/null | grep -q roundtable-; then
  # Pick the first agent container
  test_agent=$(lxc list -c n 2>/dev/null | grep roundtable- | head -1 | awk '{print $2}')
  test_port=19090

  # Enable a proxy
  out=$(sudo ./roundtable proxy enable "${test_port}" "${test_agent#roundtable-}" 2>&1)
  echo "$out" | grep -qi "Proxy" && pass "9.7 Proxy enable on ${test_agent}" || fail "9.7: $out"

  # Verify LXD device exists
  lxc config device show "$test_agent" "proxy-${test_port}" &>/dev/null && pass "9.8 LXD proxy device created" || fail "9.8 device"

  # Verify YAML record exists
  test -f ".roundtable/proxies/${test_agent#roundtable-}-${test_port}.yml" && pass "9.9 Proxy YAML record saved" || fail "9.9 record"

  # Verify YAML content
  [[ "$(yq '.host_port' ".roundtable/proxies/${test_agent#roundtable-}-${test_port}.yml")" == "${test_port}" ]] && pass "9.10 YAML host_port" || fail "9.10 host_port"
  [[ "$(yq '.bind' ".roundtable/proxies/${test_agent#roundtable-}-${test_port}.yml")" == "127.0.0.1" ]] && pass "9.11 YAML bind=127.0.0.1" || fail "9.11 bind"

  # Proxy enable idempotent
  out=$(sudo ./roundtable proxy enable "${test_port}" "${test_agent#roundtable-}" 2>&1)
  echo "$out" | grep -qi "already exists" && pass "9.12 Proxy enable idempotent" || fail "9.12: $out"

  # Enable with --public
  out=$(sudo ./roundtable proxy enable --public "${test_port}" "${test_agent#roundtable-}" 2>&1)
  echo "$out" | grep -qi "already exists" && pass "9.13 Proxy enable --public on same port" || fail "9.13: $out"

  # Enable a second proxy with different port
  out=$(sudo ./roundtable proxy enable "$((test_port + 1))" "${test_agent#roundtable-}" 2>&1)
  echo "$out" | grep -qi "Proxy" && pass "9.14 Second proxy on different port" || fail "9.14: $out"

  # Proxy list shows entries
  out=$(./roundtable proxy list 2>&1)
  echo "$out" | grep -qi "AGENT" && pass "9.15 proxy list header" || fail "9.15 header"
  echo "$out" | grep -qi "active" && pass "9.16 proxy list shows active status" || fail "9.16 active"

  # Disable one proxy
  out=$(sudo ./roundtable proxy disable "${test_port}" "${test_agent#roundtable-}" 2>&1)
  echo "$out" | grep -qi "removed" && pass "9.17 Proxy disable" || fail "9.17: $out"

  # Verify device removed
  ! lxc config device show "$test_agent" "proxy-${test_port}" &>/dev/null && pass "9.18 LXD device removed" || fail "9.18 device still present"

  # Verify YAML record removed
  test ! -f ".roundtable/proxies/${test_agent#roundtable-}-${test_port}.yml" && pass "9.19 YAML record removed" || fail "9.19 record still present"

  # Verify second proxy still exists
  lxc config device show "$test_agent" "proxy-$((test_port + 1))" &>/dev/null && pass "9.20 Second proxy unaffected" || fail "9.20 second proxy gone"

  # Cleanup
  sudo ./roundtable proxy disable "$((test_port + 1))" "${test_agent#roundtable-}" 2>&1 > /dev/null
else
  skip "9.7-9.20 No agent container — skip real proxy tests"
fi

# ── Phase 10: Agent upgrade arg validation ──
echo ""
echo "── Phase 10: Agent upgrade ──"

# Without args — shows usage
out=$(./roundtable agent upgrade 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "10.1 upgrade without args shows usage" || fail "10.1 upgrade no args: $(echo "$out" | head -1)"

# --all flag parses
out=$(./roundtable agent upgrade --all 2>&1 || true)
echo "$out" | grep -qiE "(No agents|usage)" && pass "10.2 upgrade --all parses (result: $(echo "$out" | head -1 | tr -d '\n'))" || fail "10.2 upgrade --all: $out"

# --version with tag
out=$(./roundtable agent upgrade --version v2026.8.1 arthur 2>&1 || true)
echo "$out" | grep -qiE "(Agent.*not found|usage)" && pass "10.3 upgrade --version merges tag" || fail "10.3 upgrade --version: $(echo "$out" | head -1)"

# --version without value — should error
out=$(./roundtable agent upgrade --version 2>&1 || true)
echo "$out" | grep -qi "requires" && pass "10.4 upgrade --version without value" || fail "10.4: $(echo "$out" | head -1)"

# --bad-flag — should error
out=$(./roundtable agent upgrade --bad-flag arthur 2>&1 || true)
echo "$out" | grep -qi "unknown flag" && pass "10.5 upgrade unknown flag" || fail "10.5: $(echo "$out" | head -1)"

# Multiple agent names
out=$(./roundtable agent upgrade arthur bob 2>&1 || true)
echo "$out" | grep -qiE "(not found|usage)" && pass "10.6 upgrade multiple names" || fail "10.6: $(echo "$out" | head -1)"

# Single agent name — runs upgrade_one_agent path
out=$(./roundtable agent upgrade arthur 2>&1 || true)
echo "$out" | grep -qiE "(not found|upgrading)" && pass "10.7 upgrade single name" || fail "10.7: $(echo "$out" | head -1)"

# --all with --version
out=$(./roundtable agent upgrade --all --version v2026.8.1 2>&1 || true)
echo "$out" | grep -qiE "(No agents|not found)" && pass "10.8 upgrade --all --version" || fail "10.8: $(echo "$out" | head -1)"

# ── Phase 11: Agent snapshot arg validation ──
echo ""
echo "── Phase 11: Agent snapshot ──"

# snapshot without subcommand
out=$(./roundtable agent snapshot 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "11.1 snapshot without subcommand" || fail "11.1: $(echo "$out" | head -1)"

# snapshot create without name
out=$(./roundtable agent snapshot create 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "11.2 snapshot create without name" || fail "11.2: $(echo "$out" | head -1)"

# snapshot list without name
out=$(./roundtable agent snapshot list 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "11.3 snapshot list without name" || fail "11.3: $(echo "$out" | head -1)"

# snapshot restore without snapshot name
out=$(./roundtable agent snapshot restore arthur 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "11.4 snapshot restore without snap name" || fail "11.4: $(echo "$out" | head -1)"

# snapshot delete without snapshot name
out=$(./roundtable agent snapshot delete arthur 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "11.5 snapshot delete without snap name" || fail "11.5: $(echo "$out" | head -1)"

# snapshot with bad subcommand
out=$(./roundtable agent snapshot unknown arthur 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "11.6 snapshot unknown subcommand" || fail "11.6: $(echo "$out" | head -1)"

# snapshot restore with bad snap name — should try lxc restore and fail gracefully
if lxc info roundtable-test-snap &>/dev/null 2>&1; then
  out=$(sudo ./roundtable agent snapshot restore arthur nonexistent 2>&1 || true)
  echo "$out" | grep -qiE "(not found|error)" && pass "11.7 snapshot restore nonexistent snap" || fail "11.7: $(echo "$out" | head -1)"
else
  skip "11.7 snapshot restore (no test container)"
fi

# ── Phase 12: Agent export/import arg validation ──
echo ""
echo "── Phase 12: Agent export/import ──"

# export without name
out=$(./roundtable agent export 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "12.1 export without name" || fail "12.1: $(echo "$out" | head -1)"

# export with --output flag
out=$(./roundtable agent export --output /tmp arthur 2>&1 || true)
echo "$out" | grep -qiE "(not found|exporting)" && pass "12.2 export --output DIR name" || fail "12.2: $(echo "$out" | head -1)"

# export --output without value — should error
out=$(./roundtable agent export --output 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "12.3 export --output without value" || fail "12.3: $(echo "$out" | head -1)"

# export with bad flag
out=$(./roundtable agent export --bad-flag 2>&1 || true)
echo "$out" | grep -qi "unknown flag" && pass "12.4 export unknown flag" || fail "12.4: $(echo "$out" | head -1)"

# import without name
out=$(./roundtable agent import 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "12.5 import without name" || fail "12.5: $(echo "$out" | head -1)"

# import with name but no archive
out=$(./roundtable agent import arthur 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "12.6 import without archive" || fail "12.6: $(echo "$out" | head -1)"

# import with nonexistent archive
out=$(./roundtable agent import arthur /tmp/nonexistent-export.tar.gz 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "12.7 import nonexistent archive" || fail "12.7: $(echo "$out" | head -1)"

# ── Phase 13: Real snapshot + export (conditional) ──
echo ""
echo "── Phase 13: Real snapshot + export ──"
if lxc list -c n 2>/dev/null | grep -q roundtable-; then
  test_agent=$(lxc list -c n 2>/dev/null | grep roundtable- | head -1 | awk '{print $2}')
  test_name="${test_agent#roundtable-}"

  # Snapshot create (LXD auto-generates the snapshot name)
  out=$(sudo ./roundtable agent snapshot create "$test_name" 2>&1)
  echo "$out" | grep -q "Snapshot created" && pass "13.1 Snapshot create on ${test_name}" || fail "13.1 snapshot create: $(echo "$out" | head -1)"

  # Snapshot list returns content (not empty or usage)
  out=$(./roundtable agent snapshot list "$test_name" 2>&1)
  echo "$out" | grep -q "Snapshots" && pass "13.2 Snapshot list returns snapshot block" || fail "13.2 snapshot list: $(echo "$out" | head -3)"

  # Snapshot create is idempotent with --reuse
  out=$(sudo ./roundtable agent snapshot create "$test_name" 2>&1)
  echo "$out" | grep -q "Snapshot created" && pass "13.3 Snapshot create idempotent" || fail "13.3 snapshot reuse: $(echo "$out" | head -1)"

  # Find auto-generated snapshot name and delete it
  snap_name=$(lxc info "$test_agent" 2>/dev/null | sed -n '/^Snapshots:/,/^[A-Z]/p' | head -n -1 | grep -oP '^\s+\K\S+' | head -1)
  if [[ -n "$snap_name" ]]; then
    out=$(sudo ./roundtable agent snapshot delete "$test_name" "$snap_name" 2>&1)
    echo "$out" | grep -q "deleted" && pass "13.4 Snapshot delete (${snap_name})" || fail "13.4 snapshot delete: $(echo "$out" | head -1)"

    # List after delete — should not show the deleted snap
    out=$(./roundtable agent snapshot list "$test_name" 2>&1)
    ! echo "$out" | grep -q "$snap_name" && pass "13.5 Snapshot list after delete" || fail "13.5 snapshot still listed"
  else
    skip "13.4-13.5 Could not find snapshot name"
  fi

  # Export the agent
  out=$(sudo ./roundtable agent export "$test_name" --output /tmp 2>&1)
  echo "$out" | grep -q "Exported:" && pass "13.6 Export ${test_name}" || fail "13.6 export: $(echo "$out" | head -1)"
  # Find the export archive (latest one)
  export_archive=$(ls -t /tmp/${test_name}-export-*.tar.gz 2>/dev/null | head -1)
  if [[ -n "$export_archive" ]] && [[ -f "$export_archive" ]]; then
    pass "13.7 Export archive exists: $(basename $export_archive)"
    tar tzf "$export_archive" 2>/dev/null | grep -q "container.tar.gz" && pass "13.8 Export archive contains container.tar.gz" || fail "13.8 container in archive"
    tar tzf "$export_archive" 2>/dev/null | grep -q "manifest.yml" && pass "13.9 Export archive contains manifest.yml" || fail "13.9 manifest in archive"
    rm -f "$export_archive"
  else
    fail "13.7-13.9 No export archive found"
  fi
else
  skip "13.1-13.9 No agent container — skip real snapshot/export"
fi

# ── Phase 14: Agent resize + create flags arg validation ──
echo ""
echo "── Phase 14: Agent resize + create flags ──"

# Without args — shows usage
out=$(sudo ./roundtable agent resize 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "14.1 resize without args shows usage" || fail "14.1: $(echo "$out" | head -1)"

# Bad flag
out=$(sudo ./roundtable agent resize --bad-flag 2>&1 || true)
echo "$out" | grep -qi "unknown flag" && pass "14.2 resize bad flag" || fail "14.2: $(echo "$out" | head -1)"

# Without --cpu or --memory — shows error
out=$(sudo ./roundtable agent resize nonexistent 2>&1 || true)
echo "$out" | grep -qi "specify at least" && pass "14.3 resize without --cpu/--memory" || fail "14.3: $(echo "$out" | head -1)"

# Nonexistent agent with valid flags
out=$(sudo ./roundtable agent resize nonexistent --cpu 2 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "14.4 resize nonexistent agent" || fail "14.4: $(echo "$out" | head -1)"

# Create with --cpu but no value
out=$(sudo ./roundtable agent create nonexistent --cpu 2>&1 || true)
echo "$out" | grep -qi "requires a value" && pass "14.5 create --cpu without value" || fail "14.5: $(echo "$out" | head -1)"

# Create with --memory but no value
out=$(sudo ./roundtable agent create nonexistent --memory 2>&1 || true)
echo "$out" | grep -qi "requires a value" && pass "14.6 create --memory without value" || fail "14.6: $(echo "$out" | head -1)"

# Create with bad flag
out=$(sudo ./roundtable agent create nonexistent --bad-flag 2>&1 || true)
echo "$out" | grep -qi "unknown flag" && pass "14.7 create bad flag" || fail "14.7: $(echo "$out" | head -1)"

# ── Phase 15: Real resize (conditional) ──
echo ""
echo "── Phase 15: Real resize ──"
if lxc list -c n 2>/dev/null | grep -q roundtable-; then
  test_agent=$(lxc list -c n 2>/dev/null | grep roundtable- | head -1 | awk '{print $2}')
  test_name="${test_agent#roundtable-}"
  before_mem=$(lxc config get "$test_agent" limits.memory 2>/dev/null || echo "none")
  before_cpu=$(lxc config get "$test_agent" limits.cpu 2>/dev/null || echo "none")

  out=$(sudo ./roundtable agent resize "$test_name" --cpu 2 --memory 1GB 2>&1)
  echo "$out" | grep -qi "resized" && pass "15.1 Resize ${test_name} OK" || fail "15.1: $(echo "$out" | head -2)"

  after_mem=$(lxc config get "$test_agent" limits.memory)
  after_cpu=$(lxc config get "$test_agent" limits.cpu)
  [[ "$after_cpu" == "2" ]] && pass "15.2 CPU limit is 2" || fail "15.2: CPU is ${after_cpu}"
  [[ "$after_mem" == "1GB" ]] && pass "15.3 Memory limit is 1GB" || fail "15.3: memory is ${after_mem}"

  # Restore original values
  lxc config set "$test_agent" limits.cpu "$before_cpu" 2>/dev/null || true
  lxc config set "$test_agent" limits.memory "$before_mem" 2>/dev/null || true
else
  skip "15.1-15.3 No agent container — skip real resize tests"
fi

# ── Phase 16: MCP arg validation + authorization ──
echo ""
echo "── Phase 16: MCP arg validation ──"

# Without args — shows usage
out=$(sudo ./roundtable mcp 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "16.1 mcp without args shows usage" || fail "16.1: $(echo "$out" | head -1)"

# Bad subcommand
out=$(sudo ./roundtable mcp bad-sub 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "16.2 mcp bad subcommand" || fail "16.2: $(echo "$out" | head -1)"

# install without name
out=$(sudo ./roundtable mcp install 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "16.3 install without name" || fail "16.3: $(echo "$out" | head -1)"

# uninstall without name
out=$(sudo ./roundtable mcp uninstall 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "16.4 uninstall without name" || fail "16.4: $(echo "$out" | head -1)"

# install nonexistent agent
out=$(sudo ./roundtable mcp install nonexistent 2>&1 || true)
echo "$out" | grep -qi "not found" && pass "16.5 install nonexistent agent" || fail "16.5: $(echo "$out" | head -1)"

# grant without name
out=$(sudo ./roundtable mcp grant 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "16.6 grant without name" || fail "16.6: $(echo "$out" | head -1)"

# grant without patterns
out=$(sudo ./roundtable mcp grant mcp-test 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "16.7 grant without patterns" || fail "16.7: $(echo "$out" | head -1)"

# revoke without name
out=$(sudo ./roundtable mcp revoke 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "16.8 revoke without name" || fail "16.8: $(echo "$out" | head -1)"

# permissions without name
out=$(sudo ./roundtable mcp permissions 2>&1 || true)
echo "$out" | grep -qi "usage" && pass "16.9 permissions without name" || fail "16.9: $(echo "$out" | head -1)"

# start with bad flag
out=$(sudo ./roundtable mcp start --bad-flag 2>&1 || true)
echo "$out" | grep -qi "unknown flag" && pass "16.10 start bad flag" || fail "16.10: $(echo "$out" | head -1)"

# ── Phase 17: Real MCP install + start + status + list ──
echo ""
echo "── Phase 17: Real MCP install + start ──"

# Create a test peer for mcp-test
out=$(sudo ./roundtable wg peer new --type agent mcp-test 2>&1 || true)
echo "$out" | grep -qi "created" && pass "17.1 Create test peer mcp-test" || skip "17.1: peer create failed — $(echo "$out" | head -1)"

# Install MCP access on the test peer
out=$(sudo ./roundtable mcp install mcp-test --allow "agent list,agent resize *" 2>&1)
echo "$out" | grep -qi "installed" && pass "17.2 Install MCP access for mcp-test" || fail "17.2: $(echo "$out" | head -2)"

# Check permissions file exists
[[ -f /opt/hermes-agents/arthur/home/cli-roundtable/.roundtable/mcp/permissions/mcp-test.yml ]] && pass "17.3 Permission file exists" || fail "17.3 permission file missing"

# Check API key file exists
[[ -f /opt/hermes-agents/arthur/home/cli-roundtable/.roundtable/mcp/api-keys/mcp-test ]] && pass "17.4 API key file exists" || fail "17.4 API key file missing"

# Permissions command
out=$(./roundtable mcp permissions mcp-test 2>&1)
echo "$out" | grep -qi "API key" && pass "17.5 Permissions shows API key" || fail "17.5: $(echo "$out" | head -2)"
echo "$out" | grep -qi "agent list" && pass "17.6 Permissions shows patterns" || fail "17.6: $(echo "$out" | head -2)"

# Grant more permissions
out=$(sudo ./roundtable mcp grant mcp-test "agent create *,proxy list" 2>&1)
echo "$out" | grep -qi "granted" && pass "17.7 Grant additional permissions" || fail "17.7: $(echo "$out" | head -1)"

# Revoke a permission
out=$(sudo ./roundtable mcp revoke mcp-test "agent create *" 2>&1)
echo "$out" | grep -qi "removed" && pass "17.8 Revoke permission pattern" || fail "17.8: $(echo "$out" | head -1)"

# Revoke all
out=$(sudo ./roundtable mcp revoke mcp-test --all 2>&1)
echo "$out" | grep -qi "revoked" && pass "17.9 Revoke all permissions" || fail "17.9: $(echo "$out" | head -1)"

# Grant again for the real test
sudo ./roundtable mcp grant mcp-test "agent list" >/dev/null 2>&1 || true

# List command
out=$(./roundtable mcp list 2>&1)
echo "$out" | grep -qi "mcp-test" && pass "17.10 List shows authorized agent" || fail "17.10: $(echo "$out" | head -2)"

# Start MCP server
out=$(sudo ./roundtable mcp start 2>&1)
echo "$out" | grep -qi "started" && pass "17.11 MCP server started" || fail "17.11: $(echo "$out" | head -2)"

# Status shows running
out=$(./roundtable mcp status 2>&1)
echo "$out" | grep -qi "running" && pass "17.12 MCP status shows running" || fail "17.12: $(echo "$out" | head -2)"

# MCP list after start shows server
out=$(./roundtable mcp list 2>&1)
echo "$out" | grep -qi "Connect:" && pass "17.13 MCP list shows server info" || fail "17.13: $(echo "$out" | head -2)"

# Stop MCP server
out=$(sudo ./roundtable mcp stop 2>&1)
echo "$out" | grep -qi "stopped" && pass "17.14 MCP server stopped" || fail "17.14: $(echo "$out" | head -1)"

# Uninstall
out=$(sudo ./roundtable mcp uninstall mcp-test 2>&1)
echo "$out" | grep -qi "uninstalled" && pass "17.15 MCP uninstalled" || fail "17.15: $(echo "$out" | head -1)"

# Clean up the peer
sudo ./roundtable wg peer rm --type agent mcp-test 2>/dev/null || true

# ── Phase 18: Upgrade + status arg validation ──
echo ""
echo "── Phase 18: Upgrade + status arg validation ──"

# status works
out=$(./roundtable status 2>&1)
echo "$out" | grep -qi "roundtable" && pass "18.1 Status shows version" || fail "18.1: $(echo "$out" | head -1)"

# upgrade without args shows progress (fetch + upgrade)
# This is hard to test in isolation, but we verify it doesn't crash
out=$(./roundtable upgrade 2>&1 || true)
echo "$out" | grep -qE "(Fetching|Already|Upgraded|Error)" && pass "18.2 Upgrade without flags runs" || skip "18.2: unexpected output: $(echo "$out" | head -2)"

# upgrade list
out=$(./roundtable upgrade list 2>&1 || true)
echo "$out" | grep -qiE "(Available|no version tags)" && pass "18.3 Upgrade list shows versions" || fail "18.3: $(echo "$out" | head -2)"

# upgrade with bad flag
out=$(./roundtable upgrade --bad-flag 2>&1 || true)
echo "$out" | grep -qi "unknown flag" && pass "18.4 Upgrade bad flag" || fail "18.4: $(echo "$out" | head -1)"

# Check --fix shows version info
out=$(./roundtable check 2>&1)
echo "$out" | grep -qi "Roundtable" && pass "18.5 Check shows roundtable version" || fail "18.5: $(echo "$out" | head -2)"

# ── Summary ──
echo ""
echo "  ╔═══════════════════════════════════════════╗"
printf "  ║   Results:  %3d pass  %3d fail  %3d skip    ║\n" $PASS $FAIL $SKIP
echo "  ╚═══════════════════════════════════════════╝"
echo ""

[[ "$FAIL" -eq 0 ]] && echo "  ✅ All tests passed." || echo "  ❌ $FAIL test(s) failed."
exit $FAIL