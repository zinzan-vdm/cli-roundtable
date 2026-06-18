# cli-roundtable

Containerised Hermes Agent cluster with built-in WireGuard VPN.

## Architecture

```
┌──────────────┬──────────────┐
│  agent-arthur│  agent-bob   │   Hermes agents (separate containers)
│  10.10.0.10  │  10.10.0.11  │
└──────┬───────┴──────┬───────┘
       │              │
       └──────┬───────┘
              │ Docker bridge (cluster-net / 10.10.0.0/24)
       ┌──────┴───────┐
       │  wg-easy      │   WireGuard VPN + web UI
       │  10.10.0.1    │   Ports: 51820 (VPN), 51821 (dashboard)
       └───────────────┘
              │ WireGuard tunnel
       ┌──────┴───────┐
       │ Your laptop   │   Access agents at 10.10.0.10:9119 etc.
       │ 10.10.1.x     │
       └───────────────┘
```

- Each agent runs in an isolated container with its own filesystem and venv
- Agents communicate via the Docker bridge network by hostname
- wg-easy provides the VPN endpoint and a web dashboard for managing peers
- Agent state persists in Docker volumes across container restarts/upgrades

## Usage

### 1. Prerequisites

- Docker + Compose plugin
- `modprobe wireguard` (WireGuard kernel module — load once)

### 2. Configure

```bash
cp .env.example .env
# Edit .env — set WG_HOST to your VPS IP and choose a WG_PASSWORD
```

### 3. Start the cluster

```bash
docker compose up -d
```

This starts all agents and the WireGuard VPN.

### 4. Configure an agent

```bash
docker compose --profile setup run --rm setup-arthur
```

This runs the Hermes setup wizard interactively. Configure your model provider, API keys, and preferences.

### 5. Connect your laptop

```bash
docker compose --profile setup run --rm create-peer
```

This creates a WireGuard client and prints its configuration. Save the output on your laptop:

```
# Linux/macOS: save to /etc/wireguard/wg0.conf
# Windows/macOS: import into the WireGuard client app
```

Then connect:

```bash
# Linux
wg-quick up wg0

# Or via the WireGuard app on macOS/Windows
```

### 6. Access agents

```bash
curl http://10.10.0.10:9119   # agent-arthur's dashboard
```

Add entries to your laptop's `/etc/hosts` for convenience:

```
10.10.0.10 agent-arthur
10.10.0.11 agent-bob
```

## WireGuard Dashboard

Manage peers, view connection status, and download configs at:

```
http://<vps-ip>:51821/
```

Login with the password from `WG_PASSWORD` in your `.env`.

## Adding Agents

Add a new agent by copying the `agent-arthur` service block in `compose.yml`:

```yaml
agent-bob:
  build:
    context: .
    dockerfile: Containerfile
  volumes:
    - bob-data:/hermes-data
  networks:
    cluster-net:
      ipv4_address: 10.10.0.11
  restart: unless-stopped
  stop_grace_period: 30s
```

Declare the volume at the top:

```yaml
volumes:
  bob-data:
```

Then run its setup:

```bash
docker compose run --rm agent-bob hermes setup
```

## Upgrading

```bash
docker compose build    # rebuild images with latest Hermes source
docker compose up -d    # restart containers
```

State in volumes is preserved — config, credentials, and sessions survive.

## Network Reference

| Hostname       | IP           | Port     | Service            |
|----------------|-------------|----------|--------------------|
| wg-easy        | 10.10.0.1   | 51821    | Web dashboard      |
| wg-easy        | 10.10.0.1   | 51820/udp| WireGuard VPN      |
| agent-arthur   | 10.10.0.10  | 9119     | Hermes gateway     |
| agent-bob      | 10.10.0.11  | 9119     | Hermes gateway     |

## Files

```
├── Containerfile        Hermes Agent image build
├── compose.yml          Multi-agent cluster definition
├── .env.example         Configuration template
├── setup/
│   └── create-peer.sh   Script to generate WireGuard client config
└── README.md
```