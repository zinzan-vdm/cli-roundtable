# cli-roundtable

**LXD-based Hermes Agent cluster manager.** Spin up isolated Hermes agents as LXD system containers behind a WireGuard mesh, orchestrated from a single CLI.

---

## How it works

Each agent is a **full Ubuntu 24.04 LXD system container** cloned from a `roundtable-agent` golden image with Hermes Agent pre-installed.

WireGuard (wg0) runs **natively on the host** — no Docker, no wg-easy. Agents route cluster traffic through the host, and the host's wg0 manages all peer connections (local agents + remote cluster hosts).

```
                                     +-----------------------------------------------------------------------+
                                     | Server/Host                                                           |
                                     |                                            +---------------------+    |
                                     |                            +---------------|  agent-00           |    |
                                     |                            |  VPN Peer     +---------------------+    |
                                     |                            |  10.10.1.2    LXD Container              |
                                     |                            |               eth → lxbr0 (internet)     |
                                     |                            |               wg0 → 10.10.1.2 (VPN)      |
                                     |                            |                                          |
                                     |                            |                                          |
+--------------------+               |    +--------------------+  |               +---------------------+    |
|  Admin             |---------------+----|  VPN               |--+---------------|  agent-01           |    |
+--------------------+  VPN Peer     |    +--------------------+  |  VPN Peer     +---------------------+    |
Your local machine      10.10.1.1    |    Wireguard VPN Server    |  10.10.1.3    LXD Container              |
                                     |    Runs on host            |               eth → lxbr0 (internet)     |
                                     |    Mesh (10.10.1.0/24)     |               wg0 → 10.10.1.3 (VPN)      |
                                     |    Mesh IP 10.10.1.0       |                                          |
                                     |                            |                                          |
                                     |                            |               +---------------------+    |
                                     |                            +---------------|  agent-XX           |    |
                                     |                               VPN Peer     +---------------------+    |
                                     |                               10.10.1.x    eth → lxbr0 (internet)     |
                                     |                                            wg0 → 10.10.1.4 (VPN)      |
                                     |                                                                       |
                                     +-----------------------------------------------------------------------+

```

**Key design decisions:**
- **Agents are orchestrators, not runners.** LLM inference on OpenRouter's GPUs — agents orchestrate tool calls and relay API calls.
- **Cluster topology lives on host wg0 only.** Agents are topology-agnostic — their wg0 targets just the host with `AllowedIPs = 10.0.0.0/8`. No agent config changes when hosts join/leave the cluster.
- **Config file transport for clustering.** Invite files are YAML configs exchanged out-of-band. No SSH dependency.
- **Golden image pattern.** Build once (~1.4 GB, ~3-4 min), clone many (~30s each).
- **Dir storage.** LXD uses `dir` backend — simple, no kernel module dependencies.

---

## Prerequisites

| Requirement | Min. version | Install |
|-------------|-------------|---------|
| **LXD** | 5.x+ | `snap install lxd && lxd init --auto --storage-backend dir` |
| **wireguard-tools** | — | `apt install -y wireguard-tools` |
| **yq** (mikefarah/yq) | v4.44.6 | `curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.6/yq_linux_amd64 -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq` |
| **Python 3** | 3.x | `apt install -y python3` |
| **Swap** | ≥1 GB | `fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` |
| **iptables rule** | — | `iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT && iptables -I DOCKER-USER -o lxdbr0 -j ACCEPT` |
| **DNS** | — | `cloud-images.ubuntu.com` must be resolvable |
| **Free disk** | ≥5 GB | — |

> Tested on Ubuntu 26.04 / Linux 7.0.0-15 / Hetzner CX22 (4 GB RAM, 2 vCPU, ~21 GB free). LXD 6.8, yq v4.44.6.

**Why the iptables rule?** LXD containers connect via bridge `lxdbr0`. Docker's `DOCKER-USER` chain defaults to `FORWARD DROP`, which blocks LXD container outbound traffic. Adding `lxdbr0` ACCEPT rules restores connectivity.

**Quick check:** `sudo ./roundtable check` runs all checks. Add `--fix` to auto-install.

---

## Quick start

```bash
# 1. Configure
cp config.example.yml config.yml
# Edit config.yml → set network.host to your VPS IP/domain

# 2. Check host readiness (auto-fixes with --fix)
sudo ./roundtable check --fix

# 3. Initialize host WireGuard mesh
sudo ./roundtable wg init

# 4. Build the golden image (one-time, ~3-4 min)
sudo ./roundtable golden-image build v2026.5.29.2

# 5. Create and start agents
sudo ./roundtable agent create arthur
sudo ./roundtable agent setup arthur
sudo ./roundtable agent gateway up arthur

# 6. Generate a WireGuard config for your laptop (optional)
./roundtable wg peer new laptop    # creates a foreign peer (default), prints WG config
# Save the output to a file and import it in your laptop's WireGuard app
```

### What happens during setup

| Step | What runs | Time |
|------|-----------|------|
| `wg init` | Creates wg0, generates keys, enables systemd, inits state dir | ~3s |
| `golden-image build vX` | Launches LXD temp container, installs Hermes + yq, publishes image | ~3–4 min |
| `agent create arthur` | Clones golden image, creates WG peer, injects wg0.conf, enables tunnel | ~1 min |
| `agent setup arthur` | Runs `hermes setup --run-as-user root` inside container | ~30s |
| `agent gateway up arthur` | Installs & starts messaging gateway | ~10s |

---

## CLI reference

### `wg` — WireGuard networking

```bash
roundtable wg init [--force]          # Initialize host wg0 mesh (idempotent)
roundtable wg up|down                 # Bring wg0 up/down
roundtable wg peer new <name>         # Create foreign WireGuard peer (laptop/admin, default)
roundtable wg peer new --type agent <name>  # Create agent WireGuard peer
roundtable wg peer config <name>      # Print foreign peer config (default type: foreign)
roundtable wg peer config --type agent <name>  # Print agent peer config
roundtable wg peer rm <name>          # Remove foreign peer (default type: foreign)
roundtable wg peer rm --type agent <name>  # Remove agent peer
roundtable wg invite                  # Generate anonymous cluster invitation
roundtable wg join <name> <invite>    # Connect to a remote mesh (host type)
roundtable wg leave <name>            # Disconnect from a remote mesh
roundtable wg peers                   # List all peers (agent, foreign, host)
```

### `golden-image` — Agent base image

```bash
roundtable golden-image build <version>    # Build golden image
roundtable golden-image rebuild <version>  # Delete existing and rebuild
```

`<version>` is a Hermes Agent release tag (e.g. `v2026.5.29.2`). Published as `roundtable-agent` LXD alias.

### `agent` — Agent lifecycle

```bash
roundtable agent list                  # List containers
roundtable agent create <name>         # Clone golden image + create WG peer
roundtable agent start|stop|restart    # Container lifecycle
roundtable agent shell <name>          # Open root shell
roundtable agent logs <name>           # Follow container journal
roundtable agent setup <name>          # Run hermes setup inside container
roundtable agent gateway up|down       # Start/stop the messaging gateway
roundtable agent delete <name>         # Destroy container + remove peer
```

Agent containers are namespaced (`roundtable-<name>`) with `boot.autostart=true`. The messaging gateway runs as a user systemd service with linger enabled.

### `check` — Host readiness

```bash
roundtable check              # Check all prerequisites
roundtable check --fix        # Auto-install missing prerequisites
```

---

## Configuration

```yaml
# config.yml — copy config.example.yml and edit
network:
  host: vps-ip-or-domain              # Your VPS IP/domain (required)
  wg:
    interface: wg0                     # WG interface name
    port: 51820                        # WG listen port (public UDP)
    subnets:
      cluster: 10.0.0.0/8             # Agent routing scope (AllowedIPs)
      agents: 10.0.1.0/24             # Local agent IP pool (.1 = host mesh IP)
      foreign: 10.0.2.0/24            # Admin/laptop VPN peer range
    opts:
      persistent_keepalive: 25        # WG keepalive interval (seconds)
agents:
  limits:
    cpu: 1
    memory: 768MB
golden-image:
  base: ubuntu:24.04                  # LXD image for golden image base
```

Each host needs unique `agents` and `foreign` subnets. Typical layout:

| Host | agents | foreign |
|------|--------|---------|
| Host A | `10.0.1.0/24` | `10.0.2.0/24` |
| Host B | `10.0.3.0/24` | `10.0.4.0/24` |

---

## Clustering

Connect multiple hosts' meshes together so agents on any host can reach agents on any other host.

### How it works

Each host runs its own wg0 on a unique `/24` subnet. Agents route all `10.x.x.x` traffic through their host. Cross-host routing is handled by host-to-host WireGuard peer entries — agents never know about remote hosts.

```
Host A wg0 (10.0.1.1)          Host B wg0 (10.0.3.1)
  ├── agent-01 (10.0.1.2)        ├── agent-02 (10.0.3.2)
  ├── agent-03 (10.0.1.3)        ├── agent-04 (10.0.3.3)
  └── PEER: Host B               └── PEER: Host A
       AllowedIPs: 10.0.3.0/24        AllowedIPs: 10.0.1.0/24
                   10.0.4.0/24                       10.0.2.0/24
       endpoint: B-IP:51820            endpoint: A-IP:51820
```

Agents on Host A send traffic to `10.0.3.x` → host A wg0 → encrypts → Host B → Host B's agents.

### Setup

```bash
# Host A: create invitation and send to Host B
Host A$ roundtable wg invite > host-a-invite.yml
# (scp/email host-a-invite.yml to Host B)

# Host B: create invitation and send to Host A
Host B$ roundtable wg invite > host-b-invite.yml
# (scp/email host-b-invite.yml to Host A)

# Host A: connect to Host B's mesh
Host A$ roundtable wg join host-b host-b-invite.yml

# Host B: connect to Host A's mesh
Host B$ roundtable wg join host-a host-a-invite.yml

# Verify
Host A$ ping 10.0.3.1   # should reach Host B's mesh IP
Host B$ ping 10.0.1.1   # should reach Host A's mesh IP
```

**Joins are one-way until reciprocated.** A single `join` lets the remote host reach your agents, but you can't reach theirs until they also `join` with your invite.

### Teardown

```bash
Host A$ roundtable wg leave host-b    # Only affects this side
Host B$ roundtable wg leave host-a    # Other side still has you as peer
```

### Invite file format

```yaml
# Generated by `roundtable wg invite`
public_key: xTIB9q...J0Xk=
endpoint: 203.0.113.5:51820
agents: 10.0.1.0/24          # Subnet the remote must route
foreign: 10.0.2.0/24         # Admin/laptop range
cluster: 10.0.0.0/8          # Informational (not used for routing)
```

---

## Network design

| Network | Default | Purpose |
|---------|---------|---------|
| Host wg0 | `10.0.1.0/24` | Host mesh IP (.1), agent pool (.2-.254) |
| Foreign pool | `10.0.2.0/24` | Admin/laptop WireGuard peers |
| Cluster scope | `10.0.0.0/8` | Agent AllowedIPs (routes everything through host) |
| LXD bridge | `10.8.100.0/24` | Container outbound NAT |

### Ports

| Port | Service | Visibility |
|------|---------|------------|
| `51820/udp` | WireGuard tunnel | Public (configurable via `network.wg.port`) |
| `8642` | Hermes API (per agent) | Agent loopback only |
| `9119` | Hermes dashboard (per agent) | Agent loopback only |

### Firewall

- Host must allow `51820/udp` (or your `network.wg.port`) inbound.
- Docker's `DOCKER-USER` chain must accept LXD bridge traffic:
  ```
  iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT
  iptables -I DOCKER-USER -o lxdbr0 -j ACCEPT
  ```
- `net.ipv4.ip_forward=1` enabled automatically by `wg init`.

### Agent connectivity

Each agent gets a WireGuard config injected at creation. The agent's wg0 targets only the host (its single peer), with `AllowedIPs = 10.0.0.0/8`. This means:

- Agents can reach each other across hosts (routed through host wg0)
- Agents can reach admin machines on the foreign subnet
- Hermes dashboard (`:9119`) and API (`:8642`) are accessible over the mesh
- Internet traffic goes through eth0 (LXD bridge) — unaffected by wg0

---

## Golden image

The `roundtable-agent` golden image is built from Ubuntu 24.04 and published to the local LXD image store.

| Component | Size |
|-----------|------|
| Ubuntu 24.04 base | ~270 MB |
| Hermes Agent + Node.js 22 + Python 3.11 + uv | ~200 MB |
| Playwright Chromium | ~177 MB |
| Playwright headless shell | ~114 MB |
| yq (mikefarah/yq) v4.44.6 | ~10 MB |
| ffmpeg + system deps | ~200 MB |
| wireguard-tools + ca-certificates | ~10 MB |
| 90+ Hermes skills | ~50 MB |
| Squashfs overhead | ~280 MB |
| **Total** | **~1,415 MB (1.4 GB)** |

**Build time:** ~3-4 minutes. **Clone time:** ~30 seconds (~1.4 GB on disk each with dir storage).

---

## Resource planning

| Task profile | RAM per agent | CPU | Notes |
|-------------|--------------|-----|-------|
| Idle / light | ~250 MB | Minimal | Gateway running, no tasks |
| Browser tasks | ~500-700 MB | ~1 vCPU | Headless Chromium adds 250-500 MB |
| Script/image tasks | ~400 MB | ~1 vCPU burst | Python/PIL, short-lived |

| VPS plan | RAM | vCPU | Agents | Concurrent browser tasks |
|----------|-----|------|--------|-------------------------|
| **CX22** (€3.79) | 4 GB | 2 | 3 | 1-2 |
| **CX32** (€6.99) | 8 GB | 4 | 5 | 3-4 ← sweet spot |
| **CX42** (€12.99) | 16 GB | 8 | 5+ | Unlimited |

---

## Version pinning

| What's pinned | Where | How to upgrade |
|--------------|-------|----------------|
| yq | `check --fix` | Change URL in `check` function + golden image |
| WireGuard port | `config.yml` | `network.wg.port` |
| Ubuntu base | `config.yml` | `golden-image.base` |
| Hermes Agent | CLI argument | `golden-image build v2026.6.1` |

**Not pinned (managed by Hermes installer):** Node.js, Python, Playwright, ffmpeg.

---

## Known issues

| Issue | Cause | Fix |
|-------|-------|-----|
| LXD containers have no network | Docker's DOCKER-USER chain drops forwarded packets | `check --fix` adds iptables rules |
| Golden image OOM on 4 GB | `unsquashfs` spikes memory during publish | Create swap: `fallocate -l 1G /swapfile && mkswap && swapon` |
| Golden image DNS timeout | systemd-resolved prefers IPv6 | `check --fix` diagnoses and applies IPv4 DNS |
| AppArmor blocks wg-quick (Ubuntu 26.04+) | Restrictive default profile | `echo "network inet dgram," >> /etc/apparmor.d/local/wg-quick && apparmor_parser -r /etc/apparmor.d/wg-quick` |

---

## File structure

```
cli-roundtable/
  roundtable            # Main CLI (bash, ~1100 lines)
  config.yml            # Your config (gitignored)
  config.example.yml    # Configuration template
  .roundtable/          # Runtime state (gitignored)
    ip-pool             # Agent IP allocation tracker (from network.wg.subnets.agents)
    foreign-ip-pool     # Foreign IP allocation tracker (from network.wg.subnets.foreign)
    peers/              # Peer records (name.agent.yml, name.foreign.yml, name.host.yml)
                        # + saved configs (name.agent.conf, name.foreign.conf)
    volumes/            # Per-agent LXD persistent storage
      {name}/           # Mounted at /opt/data inside container
    cluster-subnets     # Connected remote subnets
```
