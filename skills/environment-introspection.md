---
name: environment-introspection
description: "Systematic self-discovery: learn compute, OS, tools, networking, and services of the host environment."
version: 1.0.0
author: Arthur (Hermes Agent)
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [system, environment, discovery, onboarding, devops]
    related_skills: [writing-plans, requesting-code-review]
---

# Environment Introspection

## Overview

When deployed to a new machine, an agent should systematically discover what it has to work with. This skill provides a repeatable procedure for learning about the host environment — CPU, memory, storage, OS, installed tools, GPU, networking, and running services — and persisting that knowledge for future sessions.

**Goal:** Know your compute boundaries so you never promise something you can't deliver (e.g., suggesting GPU workloads on a CPU-only box, or running 16 parallel workers on 2 cores).

## When to Use

Use this skill whenever you are deployed to a new machine, or when the environment may have changed (e.g., package updates, new hardware, reinstallation).

Also use it when:
- The user says "learn about your environment" or "discover what you have"
- You need to decide if a task is feasible (e.g., "can I run a 7B model here?")
- Before creating configuration that depends on system resources
- After environment changes (new packages, new drives, GPU installation)

## Quick Reference

Run these inspection commands in parallel (they are independent). The three groups are:

### Group 1: Compute & Hardware
```
uname -a                                 # Full kernel version string
lscpu | head -30                         # CPU architecture, cores, cache, flags
free -h                                  # RAM total / used / available
df -h /                                  # Disk space on root
nproc                                    # Thread/core count
cat /proc/cpuinfo | grep "model name" | head -1   # CPU model name
lsblk -d -o NAME,SIZE,ROTA,TRAN          # Block devices (SSD/HDD)
nvidia-smi 2>/dev/null || echo "No NVIDIA GPU"    # NVIDIA GPU detection
lspci 2>/dev/null | grep -iE 'gpu|vga|3d|nvidia|amd' || echo "No GPU found via lspci"
lsmod | grep -iE 'nvidia|amd|gpu' || echo "No GPU modules loaded"
cat /proc/meminfo | head -10             # Detailed memory (MemTotal, SwapTotal)
uptime                                   # System uptime + load average
```

### Group 2: OS & Installed Tools
```
cat /etc/os-release | head -5            # Distro name + version
cat /etc/timezone                         # System timezone
python3 --version 2>/dev/null
node --version 2>/dev/null
go version 2>/dev/null
rustc --version 2>/dev/null
cargo --version 2>/dev/null
which python3 node go rustc cargo gh git curl wget jq htop iotop tmux screen ncdu make cmake gcc clang 2>/dev/null | head -20   # Bulk tool check
```

### Group 3: Networking & Running Services
```
ip -br addr                              # IP addresses + interfaces
docker info 2>/dev/null | grep -E "Server Version|CPUs|Total Memory|Storage Driver|OSType"   # Docker capability
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null || echo "No running containers"
systemctl list-units --type=service --state=running 2>/dev/null | head -40   # Active services
crontab -l 2>/dev/null | head -20        # Scheduled tasks
```

### All-in-One Quick Command

A single command that captures most of the essentials:

```bash
echo "=== KERNEL ===" && uname -a && \
echo "=== CPU ===" && lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|Socket|NUMA|L1|L2|L3|Hypervisor|Virtualization|Flags' && \
echo "=== MEMORY ===" && free -h && \
echo "=== DISK ===" && df -h / && \
echo "=== OS ===" && cat /etc/os-release | head -3 && \
echo "=== GPU ===" && (nvidia-smi 2>/dev/null | head -5 || echo "No NVIDIA GPU") && \
echo "=== NET ===" && ip -br addr && \
echo "=== TOOLS ===" && python3 --version 2>/dev/null && node --version 2>/dev/null && \
echo "=== UPTIME ===" && uptime
```

## Procedure

### Phase 1: Gather System Information

Run the commands in the Quick Reference. They are independent — use parallel terminal() calls where possible to minimize latency.

**Key things to extract from each category:**

| Category | Key Facts |
|----------|-----------|
| **CPU** | Core count, model, architecture (x86_64/arm64), virtualization type, AVX/AVX-512 support |
| **RAM** | Total, available, whether swap exists |
| **Disk** | Total size, free space, filesystem type |
| **GPU** | NVIDIA or AMD presence, driver version, VRAM |
| **OS** | Distro name, version, kernel version, timezone |
| **Tools** | Python version, Node version, Go, Rust, compilers, package managers |
| **Docker** | Engine present, running containers |
| **Network** | Public IP, interface names, Docker bridge presence |
| **Services** | Running systemd services (especially agent-related ones) |
| **Cron** | Any scheduled jobs already configured |

### Phase 2: Persist Knowledge

Save the discovered facts for future sessions. Use both the `memory` and `fact_store` tools.

**Memory** (always-on context injection — keep concise):

```python
memory(action="add", target="memory", content="System: Hetzner Cloud VPS at 46.224.154.224. Ubuntu 26.04 LTS, Linux 7.0.0-15-generic x86_64, KVM. UTC. 2 vCPUs Intel Xeon Skylake, 3.7GB RAM (2.5GB avail), ~38GB disk (21GB free). No GPU.")
memory(action="add", target="memory", content="Installed tools: Python 3.14.4, Node v22.22.1, Git, curl, wget, htop, tmux, screen, make, GCC. No Go/Rust. Docker 29.3.1 (snap). Chromium (snap).")
```

**Fact Store** (deep structured recall):

```python
fact_store(action="add", entity="arthur-system", category="tool",
    content="Arthur (Hermes Agent) lives on a Hetzner Cloud VPS at 46.224.154.224. Hetzner Cloud VPC. Ubuntu 26.04 LTS, Linux 7.0.0-15-generic x86_64. 2 vCPUs (Intel Xeon Skylake), 3.7GB RAM (2.5GB available), ~38GB disk.",
    tags="system,infrastructure,networking")
```

**Memory Management:** If memory is nearly full (>85%), consolidate related entries before adding new ones. For example, merge `System: VPS at ...` with `Installed tools: ...` into a single compact entry.

### Phase 3: Offer to Save as Skill

After completing the introspection, offer to save this procedure as a skill for future agents, noting:
1. The exact commands used and which ones needed special handling
2. Pitfalls discovered (see below)
3. Platform-specific variations (different commands for macOS, different GPU vendors)

## Pitfalls

### Permission Issues
- `/proc/*` files are world-readable, so CPU/memory info always works
- `docker ps` may fail if the user isn't in the `docker` group — handle with `2>/dev/null || echo "Docker not accessible"`
- `systemctl list-units` may show truncated output on some systems
- `nvidia-smi` fails silently on machines without NVIDIA GPUs — always wrap in `|| echo "No NVIDIA GPU"`
- `lspci` may not be installed — check with `which lspci` first or use the `2>/dev/null` pattern

### Overload Protection
- Keep terminal timeouts reasonable (15-30s per command)
- Run independent commands in parallel (separate terminal() calls)
- Some commands produce huge output (e.g., `lspci` with many devices, `systemctl list-units`) — pipe through `head -N` or `grep`

### CPU Detection Gotchas
- In virtualized/KVM environments, CPU model may show as generic ("Intel Xeon Processor (Skylake, IBRS, no TSX)") rather than the actual physical chip
- Core count may be vCPUs, not physical cores — this is the effective limit
- CPU flags matter more than model name for capability decisions (AVX, AVX-512, etc.)

### Memory & Disk Gotchas
- "Available" memory (from `free -h`) is more useful than "Free" — it accounts for buffers/cache that can be reclaimed
- Docker uses overlayfs which may show different available disk in containers vs host
- Check for swap: if `free -h` shows `Swap: 0B`, there's no swap space

### GPU Gotchas
- `nvidia-smi` returns exit code 0 even on no-GPU machines? No — it returns non-zero. Always check exit code or use `||` fallback.
- Virtio GPU (common in KVM) shows up in `lspci` as VGA controller but has zero compute capability
- AMD GPUs need different detection (`rocm-smi`, `/opt/rocm/bin/rocm_agent_enumerator`)

## Platform Variations

| Platform | CPU | Memory | GPU | Tools |
|----------|-----|--------|-----|-------|
| **Linux** | `lscpu`, `/proc/cpuinfo` | `free -h`, `/proc/meminfo` | `nvidia-smi`, `lspci` | `which`, `--version` |
| **macOS** | `sysctl -n hw.ncpu hw.machdep.cpu.brand_string` | `vm_stat`, `sysctl hw.memsize` | `system_profiler SPDisplaysDataType` | `which`, `--version` (some different paths) |
| **Container** | Same as host, but limited by cgroups | `free` shows host values (may be misleading) | Usually none | Depends on base image |
| **WSL2** | Uses `/proc/cpuinfo` (virtualized) | `free -h` works | `nvidia-smi` works if Windows has NVIDIA drivers | Native Linux binaries |

## Hermes Agent Integration

### With delegate_task

For deep dives (e.g., exploring a complex new environment), delegate specialized probes:

```python
delegate_task(
    goal="Discover GPU capability on this machine",
    context="Run nvidia-smi and lspci to detect any GPU hardware and drivers",
    toolsets=['terminal']
)
```

### With cronjob

Schedule periodic environment checking to detect changes (e.g., new disk mounts, Docker installed later):

```python
cronjob(
    action="create",
    name="weekly-env-check",
    schedule="0 9 * * 1",  # Every Monday 9am
    prompt="Run environment introspection and report any changes since last check. Compare with saved memory.",
    skills=["environment-introspection"],
    deliver="local"
)
```

## Summary

After following this skill, you should know:
- ✅ CPU cores, model, architecture, virtualization, flags
- ✅ RAM total, available, swap status
- ✅ Disk size and free space
- ✅ GPU present or absent (and type)
- ✅ OS distribution, version, kernel, timezone
- ✅ Installed dev tools with versions
- ✅ Docker capability and running containers
- ✅ Network interfaces and public IP
- ✅ Active system services (especially agent infrastructure)
- ✅ Scheduled cron jobs
- ✅ All the above persisted to memory and fact_store
