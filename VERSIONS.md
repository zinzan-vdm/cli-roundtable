# Software Versions

Record of software versions used by the cli-roundtable cluster. Pin to these for reproducible builds.

## Host
| Software | Version | Source |
|----------|---------|--------|
| OS | Ubuntu 26.04 | Hetzner VPS image |
| LXD | **6.8** | snap |
| LXD storage | **dir** | `lxd init` |
| Docker | **29.1.3** | apt (`docker.io`) |
| Docker Compose | **2.40.3** | apt (`docker-compose-v2`) |
| Kernel | 7.0.0-15-generic | — |

## Golden Image (roundtable-agent)
| Software | Version | Notes |
|----------|---------|-------|
| Base image | **Ubuntu 24.04 LTS** (20260518) | `ubuntu:24.04` LXD image |
| Hermes Agent | **v2026.5.29.2** | Branch/tag from install script |
| Node.js | **22.23.0** | Installed by Hermes installer |
| Python | **3.11.15** | Installed via uv by Hermes installer |
| uv | **0.11.23** | Managed by Hermes installer |
| Playwright Chromium | **149.0.7827.55** (v1228) | Headless browser for Hermes |
| Playwright Headless Shell | **149.0.7827.55** (v1228) | — |
| Playwright FFmpeg | **v1011** | — |
| wireguard-tools | **1.0.20210914-1ubuntu4** | apt |
| ripgrep | latest (from apt) | — |
| ffmpeg | **7:6.1.1-3ubuntu5** | — |
| Image size | **1,415 MiB** | ~1.4 GB |

## VPN
| Software | Version | Notes |
|----------|---------|-------|
| wg-easy image | **v14+** (latest `ghcr.io/wg-easy/wg-easy`) | Requires PASSWORD_HASH (bcrypt), not PASSWORD |
| WireGuard port | **51820/udp** | Public |
| Dashboard port | **51821** | Internal only (10.10.0.2:51821) |
| Internal subnet | **10.10.0.0/24** | Docker bridge |
| WireGuard pool | **10.10.1.x** | Per wg-easy WG_DEFAULT_ADDRESS config |

## Agent Resource Limits (default)
| Limit | Value | Rationale |
|-------|-------|-----------|
| Memory | **768M** | Allows 2-3 browser tasks on 4GB host |
| CPU | **1** vCPU | Prevents one agent starving others |
