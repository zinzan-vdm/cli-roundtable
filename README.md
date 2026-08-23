# cli-roundtable

---

## What is cli-roundtable

`roundtable` is a command-line tool. It builds, starts, and deletes LXD containers. Each container runs one Hermes agent. The tool creates the WireGuard mesh on the host. It also manages the VPN peers and the network.

## How it works

The tool keeps all state on the host. It stores the state in a `.roundtable` directory. The directory holds the IP pools, the peer records, and the proxy records.

Each agent runs in one LXD container. The container is a copy of a golden image. The golden image has Hermes Agent pre-installed. The container gets a WireGuard config at creation. The config points to the host.

WireGuard runs natively on the host. It does not use Docker or wg-easy. The host routes all cluster traffic.

## Key design decisions

- Use LXD containers, not Docker.
- Use native WireGuard, not wg-easy.
- Keep all state on the host.
- Store peer routes in the WireGuard config file.
- Store IP allocations in text pools.
- Build one golden image, then clone it.
- Use the `dir` storage backend.
- Make agents routing-agnostic.

## Prerequisites

- LXD 5.x or later
- wireguard-tools
- yq (mikefarah/yq) v4.44.6 or later
- Python 3
- 1 GB swap
- 5 GB free disk
- iptables rule to allow LXD bridge traffic through Docker

Run `sudo ./roundtable check --fix` to install all the prerequisites. The tool checks every requirement and installs anything that is missing.

## Quick Start

### Basic setup

Follow these steps to get one agent running.

1. Copy the config template.
   ```bash
   cp config.example.yml config.yml
   ```
2. Edit `config.yml`. Set `network.host` to your VPS IP or domain.
3. Check the host. This installs anything that is missing.
   ```bash
   sudo ./roundtable check --fix
   ```
4. Initialize the WireGuard mesh.
   ```bash
   sudo ./roundtable wg init
   ```
5. Build the golden image. This takes 3 to 4 minutes.
   ```bash
   sudo ./roundtable golden-image build v2026.5.29.2
   ```
6. Create an agent.
   ```bash
   sudo ./roundtable agent create arthur
   ```
7. Set up the agent.
   ```bash
   sudo ./roundtable agent setup arthur
   ```
8. Start the messaging gateway.
   ```bash
   sudo ./roundtable agent gateway up arthur
   ```

### Advanced setup

Use these commands to work with the network and the agents.

**Create a laptop peer.** This creates a WireGuard config for your laptop. It also offers SSH access if you answer `y`.

```bash
./roundtable wg peer new laptop
```

**Check the agent list.**

```bash
./roundtable agent list
```

**Open a shell in an agent.**

```bash
./roundtable agent shell arthur
```

**Follow an agent log.**

```bash
./roundtable agent logs arthur
```

**Forward a host port into an agent.**

```bash
./roundtable proxy enable 8080 arthur
```

**Remove an agent.** This deletes the container, the volume, the peer, and the proxy records.

```bash
sudo ./roundtable agent delete arthur
```

## Usage

Run `roundtable` with a command and its arguments.

```bash
roundtable <command> [args]
```

### WireGuard commands

| Command | Purpose |
|---------|---------|
| `wg init [--force]` | Initialize the host WireGuard mesh |
| `wg up` | Bring the `wg0` interface up |
| `wg down` | Bring the `wg0` interface down |
| `wg peer new [--type agent\|foreign] <name>` | Create a WireGuard peer and print its config |
| `wg peer list` | List all peers |
| `wg peer config [--type agent\|foreign\|host] <name>` | Print a peer config |
| `wg peer rm [--type agent\|foreign\|host] <name>` | Remove a peer |
| `wg peer ssh new [--type foreign] <name>` | Generate an SSH key for a foreign peer |
| `wg peer ssh rm [--type foreign] <name>` | Remove an SSH key |
| `wg peer ssh config [--type foreign] <name>` | Print SSH connection info |
| `wg invite` | Generate a cluster invitation |
| `wg join <name> <invite-file>` | Connect to a remote mesh |
| `wg leave <name>` | Disconnect from a remote mesh |
| `wg restore` | Restore peers and routes from saved records |

**Note on peer types.** A peer has one of three types.

- `agent` is a LXD container. Its config points to the host.
- `foreign` is a laptop or admin machine. It can get SSH access.
- `host` is another cluster host. The tool creates it with `wg join`.

The default peer type is `foreign`.

### Golden image commands

| Command | Purpose |
|---------|---------|
| `golden-image build <version>` | Build the golden image |
| `golden-image rebuild <version>` | Delete the old image and build a new one |

`<version>` is a Hermes Agent release tag, for example `v2026.5.29.2`. The tool publishes the image as the `roundtable-agent` LXD alias.

### Agent commands

| Command | Purpose |
|---------|---------|
| `agent list` | List all agent containers (version, CPU, MEM) |
| `agent create <name> [--cpu N] [--memory SIZE]` | Create an agent container |
| `agent start <name>` | Start an agent container |
| `agent stop <name>` | Stop an agent container |
| `agent restart <name>` | Restart an agent container |
| `agent shell <name>` | Open a root shell in the container |
| `agent logs <name>` | Follow the container journal |
| `agent setup <name>` | Run the Hermes setup in the container |
| `agent gateway up <name>` | Start the messaging gateway |
| `agent gateway down <name>` | Stop the messaging gateway |
| `agent upgrade <name>` | Upgrade Hermes in one container |
| `agent upgrade --all` | Upgrade Hermes in all containers |
| `agent upgrade --version TAG\|BRANCH <name>` | Upgrade to a specific version |
| `agent snapshot create <name>` | Create a container snapshot |
| `agent snapshot list <name>` | Show all snapshots for an agent |
| `agent snapshot restore <name> <snap>` | Restore the container to a snapshot |
| `agent snapshot delete <name> <snap>` | Delete a snapshot |
| `agent export <name>` | Export agent to a portable archive |
| `agent export <name> --output DIR` | Export to a custom directory |
| `agent import <name> <archive>` | Import agent from an archive |
| `agent delete <name>` | Delete the agent and all its resources |
| `agent resize <name> [--cpu N] [--memory SIZE]` | Change CPU or memory limits on a running agent |

The container name is `roundtable-<name>`. For example, `agent create arthur` creates the container `roundtable-arthur`.

The `agent upgrade` command updates Hermes in an agent container.
Without `--version`, it switches to the latest release and updates.
With `--version`, it switches to a specific tag, branch, or `main`.
The command uses direct git operations inside the container.
This avoids problems with `hermes update` on different installs.
Use `--all` to update every agent container.

The `agent list` command shows the state, the Hermes version, and the
latest available version.
It also shows the CPU and memory limits for each agent.
The `LATEST` column shows `✓` when the agent is up to date.
It shows the newer tag when an upgrade is available.

The `snapshot` commands work with LXD container snapshots.
A snapshot captures the full filesystem and container state.
The peer records, proxy records, and IP allocation on the host stay unchanged.
Use snapshots to create a restore point before you change the configuration or upgrade.

The `export` command creates a portable archive.
The archive contains the container rootfs, the volume directory, and a proxy record manifest.
The WireGuard keys and IP addresses stay on the source host.
Use the export archive to migrate an agent to a different host.

The `import` command recreates an agent from an export archive.
The new host creates new WireGuard keys and assigns new IPs.
It imports the container and restores the volume and proxy records.
Use this command to move an agent between cluster hosts.

The `resize` command changes CPU or memory limits on a running agent.
Use `--cpu N` to set the number of vCPUs.
Use `--memory SIZE` to set the memory limit.
For example, set `--memory 2GB` or `--memory 1536MB`.
The limits apply instantly.
LXD uses cgroups to enforce them.
Set one or both limits in a single command.

Set `agents.limits.cpu` and `agents.limits.memory` in the config file.
These are the default limits for new agents.
Use `--cpu` and `--memory` on `agent create` to set different limits for a specific agent.

### Proxy commands

A proxy forwards a host port to a port inside an agent container.

| Command | Purpose |
|---------|---------|
| `proxy enable [--public] <port>[:<cport>] <agent>` | Forward a host port to a container port |
| `proxy disable <port>[:<cport>] <agent>` | Remove a forwarding rule |
| `proxy list` | List all forwardings and their status |

The port syntax works in two ways.

- `proxy enable 8080 arthur` forwards `127.0.0.1:8080` to `arthur:8080`.
- `proxy enable 9090:3000 arthur` forwards `127.0.0.1:9090` to `arthur:3000`.

The default bind address is `127.0.0.1`. This makes the port reachable only on the host. Add `--public` to bind on all interfaces. With `--public`, the port is reachable from the internet. Use `--public` only when you need it.

### MCP server commands

The MCP server lets an agent run roundtable commands. It uses the Model
Context Protocol over HTTP. An agent connects with a bearer token. The token
limits what the agent can do.

| Command | Purpose |
|---------|---------|
| `mcp start [--bind IP] [--port PORT]` | Start the MCP server daemon |
| `mcp stop` | Stop the MCP server daemon |
| `mcp restart` | Restart the MCP server daemon |
| `mcp status` | Show daemon status and config |
| `mcp install <name> [--allow "p1,p2"]` | Create an API key and grant permissions |
| `mcp uninstall <name>` | Remove the API key and all permissions |
| `mcp grant <name> "perm1,perm2"` | Add permission patterns to an agent |
| `mcp revoke <name> "p1,p2" \| --all` | Remove permission patterns |
| `mcp permissions <name>` | Show API key and current permissions |
| `mcp list` | Show all authorized agents and server status |

`mcp start` creates a systemd service. It starts the Python MCP server.
The server listens on the host WireGuard IP by default. Use `--bind` and
`--port` to change the address.

`mcp install` generates a bearer token and stores it on the host.
It also writes a permission file with the patterns from `--allow`.
The token uses the `rtk_` prefix. It has 32 random bytes in hex format.
Use `chmod 600` on the client side to set the same permissions.

`mcp install` does not change the agent configuration.
To connect the agent, add the printed config to the agent `config.yaml`.
Then restart the agent gateway.

`mcp uninstall` removes the API key and the permission file.
It does not change the agent configuration.
Remove or disable the `mcp_servers` block on the agent side separately.

Permission patterns use token-level glob matching. A pattern like
`agent create *` matches `agent create foo --cpu 4` if the token count
is the same. Use `*` to match any single token. Each tool maps to a
roundtable command. For example, `roundtable_agent_create` calls
`agent create <args>`.

`mcp list` shows all agents that have an API key. It also shows
the status and the connection URL of the MCP server.

### Roundtable status and upgrade commands

`status` shows the version of roundtable.
It also shows the branch name and the remote URL.

| Command | Purpose |
|---------|---------|
| `status` | Show the current version and repository info |
| `upgrade [--version TAG|unstable|main]` | Upgrade to the latest version or to a specific tag or branch |
| `upgrade list` | List all available version tags |

`status` reads the version from git.
It runs `git describe` to get the tag and commit count.

**Version comparison**

If you are on a release branch, `status` compares the current version
to the latest tag.
If the tag is newer, it shows "upgrade available".

If you are on `main`, `status` shows "Latest: unstable".
The `main` branch has builds that are not in a release yet.

**Upgrade on a release branch**

`upgrade` without flags fetches the latest tags from origin.
It finds the newest version tag.
If the tag is newer than the current version, it checks out the tag.
This changes the current branch to a detached HEAD.

The `check --fix` command prompts to upgrade after all issues are
resolved.
Answer `y` to upgrade or `N` to skip.

**Upgrade on the unstable branch**

`upgrade` without flags on `main` pulls the latest commits from
`origin/main`.
It uses a fast-forward merge to stay on the `main` branch.
If your local `main` is already up to date, it shows
"Already up to date."

The `check --fix` command does not prompt to upgrade on `main`.
It shows a note that you can run `roundtable upgrade` if you are
behind.

**Upgrade list**

`upgrade list` fetches the tags from origin.
It shows each tag and marks the current version.

If you are on `main`, the list also shows instructions for the
unstable branch.

**Specific versions**

Use `--version TAG` to set a target version.
The target can be a git tag or one of the special values:

  - `unstable` or `main`. Switch to the unstable development branch
  - A release tag, for example `v2026-08-07.R0`

If the target exists, `upgrade` checks it out as a detached HEAD.

**Local changes**

If the working tree has local changes, `upgrade` stashes them before
the checkout or the merge.
It shows a warning about the stash.

### Host check command

| Command | Purpose |
|---------|---------|
| `check [--fix]` | Check the host readiness |

`check` verifies the tools and the host state. It checks yq, LXD, iptables, swap, disk, Python, WireGuard, IP forwarding, DNS, and the SSH workspace. Add `--fix` to install anything that is missing.

## Configuration

The tool reads `config.yml`. Copy `config.example.yml` to `config.yml` and edit it.

| Key | Default | Purpose |
|-----|---------|---------|
| `network.host` | Not set | Your VPS IP or domain |
| `network.wg.interface` | `wg0` | WireGuard interface name |
| `network.wg.port` | `51820` | WireGuard listen port |
| `network.wg.subnets.cluster` | `10.0.0.0/8` | Agent routing scope |
| `network.wg.subnets.agents` | `10.0.1.0/24` | Local agent IP pool |
| `network.wg.subnets.foreign` | `10.0.2.0/24` | Laptop and admin IP pool |
| `network.wg.opts.persistent_keepalive` | `25` | Keepalive interval in seconds |
| `agents.limits.cpu` | `1` | CPU limit per agent. Can change per container. |
| `agents.limits.memory` | `768MB` | Memory limit per agent. Can change per container. |
| `golden-image.base` | `ubuntu:24.04` | Base image for the golden image |

Each host must have a unique `agents` subnet and a unique `foreign` subnet.

| Host | agents | foreign |
|------|--------|---------|
| Host A | `10.0.1.0/24` | `10.0.2.0/24` |
| Host B | `10.0.3.0/24` | `10.0.4.0/24` |

## Clustering

Clustering connects the meshes of multiple hosts. Agents on any host can then reach agents on any other host.

Each host runs its own `wg0` interface on a unique subnet. Agents route all `10.x.x.x` traffic through their host. The hosts connect as WireGuard peers. The agents never learn about the remote hosts.

### Connect two hosts

1. Generate an invitation on Host A.
   ```bash
   Host A$ ./roundtable wg invite > host-a-invite.yml
   ```
2. Send `host-a-invite.yml` to Host B.
3. Generate an invitation on Host B.
   ```bash
   Host B$ ./roundtable wg invite > host-b-invite.yml
   ```
4. Send `host-b-invite.yml` to Host A.
5. Connect Host A to Host B.
   ```bash
   Host A$ ./roundtable wg join host-b host-b-invite.yml
   ```
6. Connect Host B to Host A.
   ```bash
   Host B$ ./roundtable wg join host-a host-a-invite.yml
   ```
7. Verify the connection.
   ```bash
   Host A$ ping 10.0.3.1
   ```
   ```bash
   Host B$ ping 10.0.1.1
   ```

A join is one-way until the other host joins too. A single join lets the remote host reach your agents. The connection is bidirectional only after both hosts join.

### Disconnect two hosts

```bash
Host A$ ./roundtable wg leave host-b
Host B$ ./roundtable wg leave host-a
```

A `leave` affects only the host that runs it.

### Invitation format

An invitation is a YAML file. It holds four values.

| Field | Purpose |
|-------|---------|
| `public_key` | The host public key |
| `endpoint` | The host address and port |
| `agents` | The agents subnet |
| `foreign` | The foreign subnet |
| `cluster` | The cluster scope, shown for information |

## Resilience

The tool restores the network state after a host reboot.

The tool stores each peer as a `[Peer]` section in the WireGuard config. The config file is `/etc/wireguard/wg0.conf`. The `wg-quick@wg0` systemd service reads this file at boot. It restores the peers and the routes.

The tool also keeps the state on disk in the `.roundtable` directory. The directory holds the IP pools, the peer records, and the proxy records.

To restore state after a software upgrade, run `wg restore`.

```bash
sudo ./roundtable wg restore
```

This command reads the saved records and adds any missing peers and routes. It does not touch the running `wg0` interface.