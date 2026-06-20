# cli-roundtable

**LXD-based Hermes Agent cluster manager.** Spin up isolated Hermes agents as LXD system containers behind a WireGuard VPN, orchestrated from a single CLI.

---

## How it works

Each agent is a **full Ubuntu 24.04 LXD system container** cloned from a `roundtable-agent` golden image. The golden image is built once with Hermes Agent pre-installed — every agent is an identical clone with its own persistent volume.

**Architecture at a glance:**

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
                                     |    wg-easy                 |               eth → lxbr0 (internet)     |
                                     |    Docker container        |               wg0 → 10.10.1.3 (VPN)      |
                                     |    Mesh (10.10.1.0/24)     |                                          |
                                     |    Mesh IP 10.10.1.0       |                                          |
                                     |                            |               +---------------------+    |
                                     |                            +---------------|  agent-XX           |    |
                                     |                               VPN Peer     +---------------------+    |
                                     |                               10.10.1.x    eth → lxbr0 (internet)     |
                                     |                                            wg0 → 10.10.1.4 (VPN)      |
                                     |                                                                       |
                                     +-----------------------------------------------------------------------+
```

Each agent has **two network paths**: the LXD bridge for outbound internet access (apt, API calls) and the WireGuard tunnel for VPN connectivity (agent-to-agent, admin access from your machine).

**Key design decisions:**

- **Agents are orchestrators, not runners.** LLM inference happens on OpenRouter's GPUs — agents orchestrate tool calls (browsers, Python scripts) and relay API calls.
- **VPN-only access.** The wg-easy dashboard is bound to an internal Docker IP (`${WG_HOST_IP:-10.10.0.254}:51821`), not exposed publicly. Agents connect via WireGuard.
- **Golden image pattern.** Build once (~1.4 GB), clone many (~30s each). The image bakes in Hermes Agent, Node.js 22, Python 3.11, Playwright Chromium, ffmpeg, and wireguard-tools.
- **Dir storage.** LXD uses `dir` backend (no CoW), so each clone takes ~1.4 GB on disk. Simple, reliable, no kernel module dependencies.

---

## Prerequisites

| Requirement | Min. version | Install command |
|-------------|-------------|-----------------|
| **Docker** (apt, not snap) | 28.x | `apt install -y docker.io docker-compose-v2` |
| **Docker Compose v2** | 2.27+ | (included with `docker-compose-v2` above) |
| **LXD** | 5.x+ | `snap install lxd && lxd init --auto --storage-backend dir` |
| **Python 3** | 3.x | `apt install -y python3` (python3-bcrypt for password hashing) |
| **Swap** (≥1 GB) | — | `fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` |
| **iptables rule** | — | `iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT && iptables -I DOCKER-USER -o lxdbr0 -j ACCEPT` |
| **wireguard-tools** | — | `apt install -y wireguard-tools` |
| **Free disk** | ≥5 GB | — |

> Tested on Ubuntu 26.04 / Linux 7.0.0-15 / Hetzner CX22 (4 GB RAM, 2 vCPU, ~21 GB free). LXD 6.8, Docker 29.1.3, Compose 2.40.3.

**Why apt Docker, not snap?** Snap-confined Docker can't see `/opt` outside its mount namespace, which breaks golden image build mounts. Install via `apt install docker.io`.

**Why the iptables rule?** Docker's `DOCKER-USER` chain defaults to `FORWARD DROP`, which blocks LXD container outbound traffic. Adding `lxdbr0` ACCEPT rules restores it.

**Quick check:** `sudo ./roundtable check` runs all of these checks and shows what's missing. Add `--fix` to install everything automatically.

---

## Quick start

```bash
# 1. Configure
cp .env.example .env
# Edit WG_HOST (your VPS IP/domain) and WG_PASSWORD
# Generate WG_PASSWORD_HASH with:
#   python3 -c "import bcrypt; print(bcrypt.hashpw(b'your-password', bcrypt.gensalt(rounds=12)).decode())"

# 2. Check host readiness (optional — auto-fixes with --fix)
sudo ./roundtable check --fix

# 3. Start the VPN
sudo ./roundtable wg up

# 4. Join the host to the WireGuard mesh
sudo ./roundtable wg host up      # host gets 10.10.1.2 (first peer)

# 5. Build the golden image (one-time)
sudo ./roundtable golden-image build v2026.5.29.2

# 6. Create and start agents
sudo ./roundtable agent create arthur
sudo ./roundtable agent start arthur

# 7. Setup Hermes inside the agent
sudo ./roundtable agent setup arthur

# 8. Start the Hermes messaging gateway
sudo ./roundtable agent gateway up arthur  # Messaging platform integration (Discord, Telegram, etc.)

# 9. Create a WireGuard config for your local machine
roundtable wg peer new admin  # creates and prints a config you can import in your WireGuard client
```

### What happens during setup

| Step | What runs | Time |
|------|-----------|------|
| `wg up` | Docker Compose starts wg-easy container | ~10s |
| `wg host up` | Creates host WireGuard peer, enables tunnel, host joins mesh | ~5s |
| `golden-image build vX` | Launches LXD temp container, installs Hermes, publishes image | ~3–4 min |
| `agent create arthur` | Clones golden image → LXC container, creates WG peer, writes config | ~1 min |
| `agent setup arthur` | Runs `hermes setup --run-as-user root` inside container | ~30s |
| `agent gateway up arthur` | Installs & starts messaging gateway (user systemd service) | ~10s |

---

## CLI reference

### `check` — Host readiness

```bash
roundtable check                # Check all prerequisites
roundtable check --fix          # Auto-install missing prerequisites
```

### `wg` — WireGuard VPN

```bash
roundtable wg up                # Start wg-easy (Docker Compose)
roundtable wg down              # Stop wg-easy
roundtable wg logs              # Follow wg-easy logs
roundtable wg peer new <name>   # Create a WireGuard peer + print config
roundtable wg peer list         # List all peers with IPs
roundtable wg peer config <name> # Print peer config (for client machines)
roundtable wg host up           # Join host to the WireGuard mesh (install tunnel + enable service)
roundtable wg host down         # Disconnect host from the WireGuard mesh
roundtable wg host ip           # Print the host's mesh IP
```

### `golden-image` — Agent base image

```bash
roundtable golden-image build <version>   # Build golden image from Ubuntu 24.04
roundtable golden-image rebuild <version> # Delete existing image and rebuild from scratch
```

`<version>` is a Hermes Agent release tag (e.g. `v2026.5.29.2`). The image is published under the `roundtable-agent` LXD alias.

### `agent` — Agent lifecycle

```bash
roundtable agent list                  # List containers
roundtable agent create <name>         # Clone golden image + create WG peer
roundtable agent start <name>          # Start container
roundtable agent stop <name>           # Stop container
roundtable agent restart <name>        # Restart container
roundtable agent shell <name>          # Open root shell
roundtable agent logs <name>           # Follow container journal
roundtable agent setup <name>          # Run hermes setup inside container
roundtable agent gateway up <name>     # Start Hermes messaging gateway (Discord, Telegram, etc.)
roundtable agent gateway down <name>   # Stop Hermes gateway
roundtable agent delete <name>         # Destroy container + revoke WG peer
```

Agent containers are **namespaced** — `agent create arthur` creates an LXC container named `roundtable-arthur`, so the LXD pool stays organised.

Agent containers are configured with `boot.autostart=true` — they automatically resume after a host reboot. The Hermes messaging gateway (if started with `gateway up`) is installed as a user systemd service with linger enabled, so it restarts with the container.

---

## Configuration

| Variable | Default | Required | Purpose |
|----------|---------|----------|---------|
| `WG_HOST` | — | ✅ | VPS IP or domain (wg-easy endpoint) |
| `WG_PASSWORD` | — | ✅ | Plaintext password for wg-easy API calls |
| `WG_PASSWORD_HASH` | — | ✅ | bcrypt hash of password (wg-easy v14+) |
| `WG_SUBNET` | `10.10.0.0/24` | — | Docker bridge subnet for wg-easy container |
| `WG_HOST_IP` | `10.10.0.254` | — | Static IP for wg-easy on the Docker bridge |
| `WG_POOL_ADDRESS` | `10.10.1.x` | — | WireGuard peer address pool template |
| `WG_ALLOWED_IPS` | `10.10.0.0/16` | — | Allowed IPs for the WireGuard tunnel |
| `AGENT_MEMORY` | `768MB` | — | Per-agent RAM limit (LXD cgroup) |
| `AGENT_CPU` | `1` | — | Per-agent vCPU limit |
| `WG_EASY_VERSION` | `14` | — | wg-easy Docker image tag |
| `UBUNTU_IMAGE` | `ubuntu:24.04` | — | LXD image alias for golden image base |
| `LXD_STORAGE` | `roundtable` | — | LXD storage pool name |

**Password hash generation:**
```bash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'your-password', bcrypt.gensalt(rounds=12)).decode())"
```

wg-easy v14 dropped plaintext `PASSWORD` in favour of `PASSWORD_HASH`. The compose.yml uses `PASSWORD_HASH` with a bcrypt hash. Single-quote the value in `.env` to prevent `$` shell expansion.

---

## Network design

The IP layout is fully configurable via `.env` variables. Defaults shown below:

| Network | Default Subnet | Purpose |
|---------|---------------|---------|
| Docker bridge | `WG_SUBNET` → `10.10.0.0/24` | wg-easy container and host communication |
| wg-easy static IP | `WG_HOST_IP` → `10.10.0.254` | wg-easy container (not `.1` — Docker gateway) |
| WireGuard pool | `WG_POOL_ADDRESS` → `10.10.1.x` | Per-agent VPN addresses, assigned by wg-easy |
| LXD bridge | `10.8.100.0/24` | LXD containers (NAT to host, outbound only) |
| Docker gateway | `WG_SUBNET .1` → `10.10.0.1` | Docker bridge gateway (unused by wg-easy) |

### Ports

| Port | Service | Visibility |
|------|---------|------------|
| `51820/udp` | WireGuard tunnel | Public (incoming) |
| `51821` | wg-easy dashboard | Internal only (`WG_HOST_IP:51821`) |
| `8642` | Hermes API server (per agent) | Agent loopback only |
| `9119` | Hermes dashboard (per agent) | Agent loopback only |

### Firewall

- **Docker's `DOCKER-USER` chain** must accept LXD bridge traffic.
  ```
  iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT
  iptables -I DOCKER-USER -o lxdbr0 -j ACCEPT
  ```
  Without this, LXD containers can't reach the internet (packages, Hermes install, API calls).
- The host firewall should expose `51820/udp`. Everything else stays internal.
- wg-easy dashboard (`51821`) is **not** port-mapped to the host — access it via WireGuard tunnel.

### Agent connectivity

Each agent gets a WireGuard peer on the pool (`WG_POOL_ADDRESS` → default `10.10.1.x`) via wg-easy. The config is written into the container at `/etc/wireguard/wg0.conf` and activated with `wg-quick up wg0`. This means:

- Agents can reach each other over WireGuard
- The host VPS is also on the mesh at `.2` (configured via `wg host up`)
- Your local machine can reach all agents and the host by connecting to the same wg-easy server
- Hermes dashboard (`:9119`) and API (`:8642`) are accessible over the tunnel
- SSH into the host from anywhere on the mesh: `ssh user@10.10.1.2`

---

## Golden image

The `roundtable-agent` golden image is built from Ubuntu 24.04 and published to the local LXD image store. Everything Hermes needs is baked in:

| Component | Size |
|-----------|------|
| Ubuntu 24.04 base | ~270 MB |
| Hermes Agent + Node.js 22 + Python 3.11 + uv | ~200 MB |
| Playwright Chromium | ~177 MB |
| Playwright headless shell | ~114 MB |
| ffmpeg + system deps | ~200 MB |
| wireguard-tools + ca-certificates | ~10 MB |
| 90 Hermes skills | ~50 MB |
| Squashfs overhead | ~280 MB |
| **Total** | **~1,415 MB (1.4 GB)** |

**Build time:** ~3–4 minutes (depends on download speed and disk I/O).

**Clone time:** ~30 seconds per agent. With dir storage (no CoW), each clone uses a full ~1.4 GB on disk.

**Version pinning:** The golden image locks specific versions of Hermes (`<version>` argument), Ubuntu (`UBUNTU_IMAGE`), wireguard-tools, curl, and ca-certificates. What isn't pinned: Node.js, Python, Playwright, ffmpeg — those come from Hermes' own installer. To update them, build with a newer Hermes release.

---

## Resource planning

Each agent is an orchestrator — LLM inference is remote (OpenRouter), so agents only need enough RAM for their tool runtime.

| Task profile | RAM per agent | CPU | Notes |
|-------------|--------------|-----|-------|
| Idle / light | ~250 MB | Minimal | Gateway running (140 MB observed), no tasks |
| Browser tasks | ~500–700 MB | ~1 vCPU | Headless Chromium adds 250–500 MB |
| Script/image tasks | ~400 MB | ~1 vCPU burst | Python/PIL, short-lived |

### Capacity by VPS plan

| Plan | RAM | vCPU | Agents | Concurrent browser tasks |
|------|-----|------|--------|-------------------------|
| **CX22** (€3.79) | 4 GB | 2 | 3 | 1–2 |
| **CX32** (€6.99) | 8 GB | 4 | **5** | **3–4** ← sweet spot |
| **CX42** (€12.99) | 16 GB | 8 | 5+ | Unlimited |

**CX22 works** with per-agent limits (768 MB / 1 vCPU default) if you accept that heavy tasks compete. The host reserves ~700 MB for Docker + LXD overhead, leaving ~3.3 GB for agents.

**CX32 is the sweet spot.** 8 GB splits ~7.3 GB across 5 agents (~1.4 GB each) — enough headroom for 3–4 to run Chromium simultaneously. 4 vCPUs let browser tasks time-slice without starving wg-easy or the host.

---

## Version pinning

Everything under our control is pinned to specific versions for reproducible builds. See each file for the exact values:

| What's pinned | Where | How to upgrade |
|--------------|-------|----------------|
| wg-easy Docker image | `WG_EASY_VERSION` in `.env` | Set `WG_EASY_VERSION=15` (or whichever) |
| Ubuntu base image | `UBUNTU_IMAGE` in `.env` | Set `UBUNTU_IMAGE=ubuntu:22.04` |
| wireguard-tools, curl, ca-certificates | Apt version pins in `roundtable` script | Set `WG_TOOLS_VER`, `CURL_VER`, `CA_CERT_VER` in `.env` |
| Hermes Agent | CLI argument | `golden-image build v2026.6.1` |

**Not pinned (managed by Hermes installer):** Node.js, Python, Playwright, ffmpeg. To change their versions, pin a different Hermes release when building the golden image.

---

## Known issues & workarounds

| Issue | Cause | Fix |
|-------|-------|-----|
| LXD containers have no network | Docker's `DOCKER-USER` chain drops forwarded packets | Add `iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT` (or run `check --fix`) |
| Golden image build OOM on 4 GB hosts | `unsquashfs` during image publish spikes memory | Create swap: `fallocate -l 1G /swapfile && mkswap && swapon` |
| Docker snap can't see `/opt` | Snap confinement | Install via `apt install docker.io` instead |
| `$` in .env password gets eaten by shell | Shell variable expansion | Single-quote the value, or escape `$` |
| `check` swap threshold | `swapon --show --bytes` returns usable space minus swap header (4096 bytes less) | Threshold lowered to ≥1,000,000,000 bytes (≈953 MiB) |
| `check` iptables false negative | `iptables -L` without `-v` doesn't show interface columns | Added `-v` flag so `-i lxdbr0` rules match |

---

## File structure

```
cli-roundtable/
  roundtable        # Main CLI (bash, ~500 lines)
  compose.yml       # wg-easy Docker Compose config
  .env.example      # Configuration template
  .env              # Your config (gitignored)
  .agents/
    {name}/
      volume/       # Persistent storage mounted at /opt/data inside agent
```
