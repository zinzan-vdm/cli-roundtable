# cli-roundtable

Hermes Agent cluster manager — LXD system containers + WireGuard VPN. Each agent is a full Ubuntu container with root, apt, and persistent storage. Manage everything from a single CLI.

## Quick start

```bash
cp .env.example .env   # edit WG_HOST (VPS IP) and WG_PASSWORD
sudo ./roundtable setup # or do it step by step:
sudo ./roundtable wg up
sudo ./roundtable image-base build v2026.5.29.2
sudo ./roundtable agent create arthur
sudo ./roundtable agent start arthur
```

## Architecture

```
┌───────────────────────────────────────┐
│  Host (Hetzner VPS)                   │
│  ┌─────────────────────────────────┐  │
│  │  wg-easy (Docker)              │  │
│  │  └─ 51821 (dashboard, VPN only)│  │
│  │  └─ 51820/udp (WireGuard)     │  │
│  └─────────────────────────────────┘  │
│  ┌────────────┐ ┌────────────┐ ┌───┐  │
│  │ Agent A    │ │ Agent B    │ │...│  │
│  │ (LXD:      │ │ (LXD:      │ │   │  │
│  │  roundtable-a)│  roundtable-b)│   │  │
│  └────────────┘ └────────────┘ └───┘  │
│  ┌─────────────────────────────────┐  │
│  │  lxdbr0 (NAT) │ .agents/{n}/   │  │
│  └─────────────────────────────────┘  │
└───────────────────────────────────────┘
```

- **Agents** are LXD system containers cloned from a `roundtable-agent` golden image. LXC containers are namespaced `roundtable-{name}` to avoid polluting the LXD pool — you still use short names in the CLI (`roundtable agent shell arthur`).
- **Golden image** (`roundtable agent image-base build <version>`) installs Hermes Agent with `--non-interactive --skip-setup` so no TTY is needed.
- **VPN** uses wg-easy in Docker. The dashboard (port 51821) is only accessible over the WireGuard tunnel, not public.
- **Persistent data** per agent lives in `.agents/{name}/volume/`, mounted at `/opt/data` inside the container.

## Commands

### WireGuard
| Command | What it does |
|---------|-------------|
| `roundtable wg up` | Start wg-easy VPN |
| `roundtable wg down` | Stop wg-easy |
| `roundtable wg logs` | Follow wg-easy logs |
| `roundtable wg peer new <name>` | Create client config |
| `roundtable wg peer list` | List all peers |
| `roundtable wg peer config <name>` | Print peer config (for your local machine) |

### Golden image
| Command | What it does |
|---------|-------------|
| `roundtable image-base build <version>` | Build golden image with Hermes Agent |
| `roundtable image-base rebuild <version>` | Rebuild from scratch (deletes old image) |

Version is a Hermes Agent release tag (e.g. `v2026.5.29.2`). The image is published under the `roundtable-agent` alias.

### Agents
| Command | What it does |
|---------|-------------|
| `roundtable agent list` | List agents and their status |
| `roundtable agent create <name>` | Clone golden image + create peer |
| `roundtable agent start <name>` | Start agent container |
| `roundtable agent stop <name>` | Stop agent container |
| `roundtable agent restart <name>` | Restart agent container |
| `roundtable agent shell <name>` | Open root shell inside container |
| `roundtable agent logs <name>` | Follow container journal |
| `roundtable agent setup <name>` | Run `hermes setup` inside container |
| `roundtable agent delete <name>` | Destroy agent + revoke peer |

## Resource planning

Each agent runs a Node.js gateway (~120MB idle) and may spawn tools (Chromium, Python). Deductions happen on OpenRouter's GPU, so the agents are orchestrators, not runners.

| Task profile | RAM per agent | CPU per agent | Notes |
|-------------|--------------|--------------|-------|
| Idle / light | ~250MB | minimal | Gateway running, no active tasks |
| Browser tasks | ~500–700MB | ~1 vCPU | Headless Chromium adds 250–500MB |
| Image/script tasks | ~400MB | ~1 vCPU burst | Python/PIL, short-lived |

### Capacity by plan

| Hetzner plan | RAM | vCPU | Agents | Browser tasks at once |
|---|---|---|---|---|
| **CX22** (€3.79) | 4GB | 2 | 3 | 1–2 |
| **CX32** (€6.99) | 8GB | **4** | **5** | **3–4** ← sweet spot |
| **CX42** (€12.99) | 16GB | 8 | 5+ | unlimited |

**Why CX32 is the sweet spot:** Host + Docker + LXD overhead sits at ~700MB. With 8GB you split the remaining ~7.3GB across 5 agents (~1.4GB each) — enough that 3–4 can run Chromium simultaneously without swap. The 4 vCPUs let concurrent browser tasks time-slice without starving the host or wg-easy.

**CX22 works** if you set per-agent limits (default: 768MB/1vCPU in `.env`) and accept that heavy tasks compete. Inference is remote — these resources are just for orchestration.

## Configuration

All in `.env`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `WG_HOST` | — | VPS IP or domain (required) |
| `WG_PASSWORD` | — | wg-easy dashboard password (required) |
| `AGENT_MEMORY` | `768M` | Per-agent memory limit (LXD cgroup) |
| `AGENT_CPU` | `1` | Per-agent CPU limit (LXD cgroup) |
| `LXD_STORAGE` | `roundtable` | LXD storage pool name |
