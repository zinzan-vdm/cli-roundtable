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
              │ Docker bridge (net / 10.10.0.0/24)
       ┌──────┴───────┐
       │  wg-easy     │   WireGuard VPN + web UI
       │  10.10.0.1   │   Ports: 51820 (VPN), 51821 (dashboard)
       └──────────────┘
              │ WireGuard tunnel
       ┌──────┴───────┐
       │ Your laptop  │   Access agents at 10.10.0.10:9119 etc.
       │ 10.10.1.x    │
       └──────────────┘
```

- Each agent runs in an isolated container using the official `nousresearch/hermes-agent` image
- Agents communicate via the Docker bridge network by hostname
- wg-easy provides the VPN endpoint and a web dashboard for managing peers
- Agent state persists in Docker volumes

## Quick Start

### 1. Configure

```bash
cp .env.example .env
# Edit .env — set WG_HOST to your VPS IP and choose a WG_PASSWORD
```

### 2. Start

```bash
docker compose up -d
```

This pulls the official Hermes images and starts all agents + the VPN.

### 3. Configure an agent

```bash
docker compose run agent-arthur setup
```

This runs the Hermes setup wizard interactively in the running agent's
context. Configure your model provider, API keys, and preferences.
The setup persists in the agent's volume — you only need to do it once.

### 4. Connect your laptop

```bash
./peers new admin          # or ./peers new laptop
```

This creates a WireGuard client and prints its configuration. Save the
output on your laptop as `/etc/wireguard/wg0.conf` (or import into the
WireGuard client app). Then connect:

```bash
wg-quick up wg0                    # Linux
# Or connect via the WireGuard app on macOS/Windows
```

### 5. Access agents

From your laptop over the VPN:

```bash
curl http://10.10.0.10:9119   # agent-arthur's dashboard
```

Add entries to your laptop's `/etc/hosts` for convenience:

```
10.10.0.10 agent-arthur
10.10.0.11 agent-bob
```

## Peer Management

```bash
./peers new admin       Create a new peer and print its config
./peers list            List all peers
./peers config admin    Print an existing peer's config
```

Requires `WG_PASSWORD` set in `.env` and wg-easy running (`docker compose up -d`).

## WireGuard Dashboard

Manage peers, view connection status, and download configs at:

```
http://<vps-ip>:51821/
```

Login with the password from `WG_PASSWORD` in your `.env`.

## Volumes

Each agent uses a Docker volume for persistent state (config, credentials,
sessions, skills, memory). The volume mounts at `/opt/data` inside the
container — this is the agent's `HERMES_HOME`.

### Named volumes (default)

```yaml
volumes:
  arthur-data:           # managed by Docker, stored in /var/lib/docker/volumes/
```

These survive container restarts and upgrades. To inspect or back up:

```bash
docker run --rm -v arthur-data:/data alpine ls /data
docker run --rm -v arthur-data:/data alpine tar czf - /data > arthur-backup.tar.gz
```

### Bind mounts (host-accessible)

To edit files on the host directly, replace the named volume with a bind
mount:

```yaml
volumes:
  - /opt/hermes-agents/arthur:/opt/data   # host path
```

Now you can read and write agent files directly from the host:

```bash
ls /opt/hermes-agents/arthur/config.yaml
ls /opt/hermes-agents/arthur/skills/
```

## Adding Agents

Add a new agent by copying the `agent-arthur` service block in `compose.yml`:

```yaml
agent-bob:
  image: nousresearch/hermes-agent:v2026.5.29.2
  volumes:
    - bob-data:/opt/data
  networks:
    net:
      ipv4_address: 10.10.0.11
  restart: unless-stopped
  stop_grace_period: 30s
  command: ["gateway", "run"]
```

Declare the volume at the top:

```yaml
volumes:
  bob-data:
```

Then run its setup:

```bash
docker compose run agent-bob setup
```

## Upgrading

```bash
docker compose pull       # pull latest official images
docker compose up -d      # restart containers
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
├── compose.yml          Multi-agent cluster definition
├── peers                WireGuard peer management (runs on host)
├── .env.example         Configuration template
└── README.md
```
