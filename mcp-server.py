#!/usr/bin/env python3
"""roundtable MCP server — Streamable HTTP transport (JSON-RPC 2.0).

Exposes roundtable commands as MCP tools to Hermes agents.
Auth via bearer tokens stored in .roundtable/mcp/api-keys/.
Permissions via .roundtable/mcp/permissions/<name>.yml.

Usage:
  python3 mcp-server.py [--bind IP] [--port PORT]
"""

import http.server
import json
import os
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROUNDTABLE_DIR = HERE / ".roundtable"

# ── Config ──────────────────────────────────────────────────────────

MCP_CONFIG = ROUNDTABLE_DIR / "mcp.yml"
DEFAULT_BIND = "10.0.1.1"
DEFAULT_PORT = 8342
ROUNDTABLE = HERE / "roundtable"


def load_mcp_config():
    bind = DEFAULT_BIND
    port = DEFAULT_PORT
    roundtable_path = ROUNDTABLE

    if MCP_CONFIG.exists():
        for line in MCP_CONFIG.read_text().splitlines():
            line = line.strip()
            if line.startswith("bind:"):
                bind = line.split(":", 1)[1].strip().strip('"\'')
            elif line.startswith("port:"):
                try:
                    port = int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
            elif line.startswith("roundtable:"):
                rt = line.split(":", 1)[1].strip().strip('"\'')
                if rt:
                    roundtable_path = Path(rt)

    return bind, port, roundtable_path


# ── Tool definitions ───────────────────────────────────────────────
# Each tool maps to a roundtable CLI command. Use explicit command
# prefixes (not underscore parsing) so multi-word subcommands like
# "agent snapshot create" work correctly.

TOOLS = [
    # ── Agent lifecycle ──
    {
        "name": "roundtable_agent_list",
        "description": "List all agent containers with status, IP, and resource limits",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_agent_create",
        "description": "Create a new agent container. Arguments: <name> [--cpu N] [--memory SIZE]",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Agent name and optional flags: <name> [--cpu N] [--memory SIZE]",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_delete",
        "description": "Delete an agent container, its volume, and its WireGuard peer. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_start",
        "description": "Start an agent container. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_stop",
        "description": "Stop an agent container. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_restart",
        "description": "Restart an agent container. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_logs",
        "description": "Show recent journal logs from an agent container. Arguments: <name>. Returns last 200 lines (does not follow).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_setup",
        "description": "Run Hermes setup inside an agent container. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_gateway_up",
        "description": "Start the Hermes messaging gateway for an agent. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_gateway_down",
        "description": "Stop the Hermes messaging gateway for an agent. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_upgrade",
        "description": "Upgrade Hermes in an agent container. Arguments: [--version TAG] [--all|<name>]",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Version and agent: [--version TAG] [--all|<name>]",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_snapshot_create",
        "description": "Create a container snapshot. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_snapshot_list",
        "description": "List snapshots for an agent container. Arguments: <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {"type": "string", "description": "Agent name: <name>"}
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_snapshot_restore",
        "description": "Restore a container from a snapshot. Arguments: <name> <snapshot>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Agent name and snapshot name: <name> <snapshot>",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_snapshot_delete",
        "description": "Delete a container snapshot. Arguments: <name> <snapshot>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Agent name and snapshot name: <name> <snapshot>",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_export",
        "description": "Export an agent to a portable archive. Arguments: <name> [--output DIR]",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Agent name and optional output dir: <name> [--output DIR]",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_import",
        "description": "Import an agent from an archive. Arguments: <name> <archive>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Agent name and archive path: <name> <archive>",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_agent_resize",
        "description": "Change CPU or memory limits on a running agent. Arguments: <name> [--cpu N] [--memory SIZE]",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Agent name and new limits: <name> [--cpu N] [--memory SIZE]",
                }
            },
            "required": ["args"],
        },
    },
    # ── Proxy (port forwarding) ──
    {
        "name": "roundtable_proxy_enable",
        "description": "Forward a host port to an agent container. Arguments: [--public] <port>[:<cport>] <agent>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Port mapping and agent: [--public] <port>[:<cport>] <agent>",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_proxy_disable",
        "description": "Remove a proxy forwarding rule. Arguments: <port>[:<cport>] <agent>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Port and agent: <port>[:<cport>] <agent>",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_proxy_list",
        "description": "List all proxy forwardings and their status",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    # ── WireGuard networking ──
    {
        "name": "roundtable_wg_peer_list",
        "description": "List all WireGuard peers (agents + foreign + host) with IP, type, and connection status",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_wg_peer_config",
        "description": "Print a WireGuard peer config. Arguments: [--type agent|foreign|host] <name>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Peer name with optional type: [--type agent|foreign|host] <name>",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_wg_invite",
        "description": "Generate an anonymous cluster invitation YAML for another host to join this mesh",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_wg_up",
        "description": "Bring the host WireGuard interface (wg0) up",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_wg_down",
        "description": "Bring the host WireGuard interface (wg0) down. Disconnects all peers.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_wg_restore",
        "description": "Sync wg-quick config and kernel routes from saved peer records (post-upgrade recovery)",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    # ── Golden image ──
    {
        "name": "roundtable_golden_image_build",
        "description": "Build the golden image with a specific Hermes version. Arguments: <version>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Hermes version tag: <version>",
                }
            },
            "required": ["args"],
        },
    },
    {
        "name": "roundtable_golden_image_rebuild",
        "description": "Delete the old golden image and build a new one. Arguments: <version>",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Hermes version tag: <version>",
                }
            },
            "required": ["args"],
        },
    },
    # ── MCP server management ──
    {
        "name": "roundtable_mcp_status",
        "description": "Show MCP server status, systemd info, and configured bind/port",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_mcp_list",
        "description": "List all authorized MCP agents and their permission counts",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    # ── Host / diagnostics ──
    {
        "name": "roundtable_check",
        "description": "Check host readiness (read-only — no auto-fix). Reports tool/network/swap status.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_status",
        "description": "Show roundtable version, branch, remote, and latest available tag",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_upgrade_list",
        "description": "List all available roundtable versions (tags) with current version marked",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "roundtable_upgrade",
        "description": "Upgrade roundtable to latest or a specific version. Arguments: [--version TAG]",
        "inputSchema": {
            "type": "object",
            "properties": {
                "args": {
                    "type": "string",
                    "description": "Optional version: [--version TAG]",
                }
            },
            "required": [],
        },
    },
]

# ── Tool name to roundtable command prefix mapping ─────────────────
# Explicit mapping avoids bugs from underscore-splitting multi-word
# subcommands like "agent snapshot create" or "golden-image build".

TOOL_MAP = {
    # Agent lifecycle
    "roundtable_agent_list": "agent list",
    "roundtable_agent_create": "agent create",
    "roundtable_agent_delete": "agent delete",
    "roundtable_agent_start": "agent start",
    "roundtable_agent_stop": "agent stop",
    "roundtable_agent_restart": "agent restart",
    "roundtable_agent_logs": "agent logs",
    "roundtable_agent_setup": "agent setup",
    "roundtable_agent_gateway_up": "agent gateway up",
    "roundtable_agent_gateway_down": "agent gateway down",
    "roundtable_agent_upgrade": "agent upgrade",
    "roundtable_agent_snapshot_create": "agent snapshot create",
    "roundtable_agent_snapshot_list": "agent snapshot list",
    "roundtable_agent_snapshot_restore": "agent snapshot restore",
    "roundtable_agent_snapshot_delete": "agent snapshot delete",
    "roundtable_agent_export": "agent export",
    "roundtable_agent_import": "agent import",
    "roundtable_agent_resize": "agent resize",
    # Proxy
    "roundtable_proxy_enable": "proxy enable",
    "roundtable_proxy_disable": "proxy disable",
    "roundtable_proxy_list": "proxy list",
    # WireGuard
    "roundtable_wg_peer_list": "wg peer list",
    "roundtable_wg_peer_config": "wg peer config",
    "roundtable_wg_invite": "wg invite",
    "roundtable_wg_up": "wg up",
    "roundtable_wg_down": "wg down",
    "roundtable_wg_restore": "wg restore",
    # Golden image
    "roundtable_golden_image_build": "golden-image build",
    "roundtable_golden_image_rebuild": "golden-image rebuild",
    # MCP
    "roundtable_mcp_status": "mcp status",
    "roundtable_mcp_list": "mcp list",
    # Host / diagnostics
    "roundtable_check": "check",
    "roundtable_status": "status",
    "roundtable_upgrade_list": "upgrade list",
    "roundtable_upgrade": "upgrade",
}


# ── Auth ────────────────────────────────────────────────────────────

API_KEYS_DIR = ROUNDTABLE_DIR / "mcp" / "api-keys"
PERMS_DIR = ROUNDTABLE_DIR / "mcp" / "permissions"


def ensure_dirs():
    API_KEYS_DIR.mkdir(parents=True, exist_ok=True)
    PERMS_DIR.mkdir(parents=True, exist_ok=True)


def resolve_agent(token: str) -> str | None:
    """Return agent name for a bearer token, or None if not found."""
    ensure_dirs()
    if not API_KEYS_DIR.exists():
        return None
    for fpath in API_KEYS_DIR.iterdir():
        if fpath.is_file() and fpath.name != ".gitignore":
            stored = fpath.read_text().strip()
            if stored == token:
                return fpath.name
    return None


def load_permissions(agent: str) -> list[str] | None:
    """Return allow patterns list, or None if file missing."""
    pfile = PERMS_DIR / f"{agent}.yml"
    if not pfile.exists():
        return None
    allow = []
    in_allow = False
    for line in pfile.read_text().splitlines():
        stripped = line.strip()
        if stripped == "allow:":
            in_allow = True
            continue
        if in_allow:
            if stripped.startswith("- "):
                pat = stripped[2:].strip().strip("\"'")
                if pat:
                    allow.append(pat)
            else:
                in_allow = False
    return allow


def token_match(cmd_tokens: list[str], pattern_tokens: list[str]) -> bool:
    """Match command tokens against a pattern. * matches exactly one token
    at any position. Extra tokens on either side means no match."""
    if len(cmd_tokens) != len(pattern_tokens):
        return False
    for ct, pt in zip(cmd_tokens, pattern_tokens):
        if pt == "*":
            continue
        if ct != pt:
            return False
    return True


def check_permission(agent: str, command: str) -> str | None:
    """Return None if allowed, or error message string."""
    allow = load_permissions(agent)
    if allow is None:
        return "no permission file"
    cmd_tokens = shlex.split(command)
    for pat in allow:
        pat_tokens = shlex.split(pat)
        if token_match(cmd_tokens, pat_tokens):
            return None
    return "command not in allow list"


# ── Command execution ──────────────────────────────────────────────

# Limit for agent logs: use --lines 200 instead of -f to avoid hanging
ROUNDTABLE_ARGS_OVERRIDES = {
    "agent logs": "agent logs",  # We'll handle -f stripping in execute_roundtable
}


LXC = shutil.which("lxc") or "/usr/bin/lxc"


def execute_roundtable(roundtable_path, cmd: str) -> tuple[int, str]:
    """Run a roundtable command and return (exit_code, output)."""
    # Special handling: agent logs uses journalctl -f which hangs forever.
    # Run a bounded read via direct lxc exec instead.
    if cmd.startswith("agent logs "):
        name = cmd[len("agent logs "):].strip()
        if name:
            lxc_name = f"roundtable-{name}"
            lines_cmd = [LXC, "exec", lxc_name, "--",
                         "journalctl", "-u", "hermes-gateway",
                         "--no-pager", "--lines", "200"]
            try:
                r = subprocess.run(lines_cmd, capture_output=True, text=True, timeout=30)
                out = r.stdout or r.stderr or "(no output)"
            except (subprocess.TimeoutExpired, FileNotFoundError):
                out = "(logs unavailable)"
            return 0, out.strip()[:10000]

    full_cmd = [str(roundtable_path)]
    full_cmd.extend(shlex.split(cmd))
    try:
        result = subprocess.run(
            full_cmd, capture_output=True, text=True, timeout=120,
        )
        output = result.stdout
        if result.stderr:
            output += result.stderr
        return result.returncode, output.strip()
    except FileNotFoundError:
        return 1, f"Error: roundtable not found at {roundtable_path}"
    except subprocess.TimeoutExpired:
        return 1, "Error: command timed out after 120s"


# ── MCP Protocol ────────────────────────────────────────────────────

class MCPHandler(http.server.BaseHTTPRequestHandler):
    server_version = "roundtable-mcp/1.1"
    server: "MCPServer"

    def do_GET(self):
        if self.path == "/health":
            uptime = time.time() - getattr(self.server, "start_time", time.time())
            self.send_json(200, {
                "status": "ok",
                "uptime_seconds": round(uptime, 1),
                "tools_count": len(TOOLS),
            })
        else:
            self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/mcp":
            self.send_json(404, {"error": "not_found"})
            return

        content_len = int(self.headers.get("Content-Length", 0))
        if content_len == 0:
            self.send_json(400, {"jsonrpc": "2.0", "error": {"code": -32700, "message": "empty body"}})
            return

        body = self.rfile.read(content_len)
        try:
            request = json.loads(body)
        except json.JSONDecodeError:
            self.send_json(400, {"jsonrpc": "2.0", "error": {"code": -32700, "message": "parse error"}})
            return

        method = request.get("method", "")
        req_id = request.get("id")

        # Bearer auth for protected methods
        auth_header = self.headers.get("Authorization", "")
        token = ""
        if auth_header.startswith("Bearer "):
            token = auth_header[7:]
        agent = resolve_agent(token) if token and method not in ("initialize", "ping", "notifications/initialized") else None

        # ── Unauthenticated methods ──
        if method == "initialize":
            self.send_json(200, {
                "jsonrpc": "2.0", "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "serverInfo": {"name": "roundtable-mcp", "version": "1.1"},
                    "capabilities": {"tools": {}},
                },
            })
            return

        if method == "notifications/initialized":
            self.send_json(202, "")
            return

        if method == "ping":
            self.send_json(200, {"jsonrpc": "2.0", "id": req_id, "result": {}})
            return

        # ── Authenticated methods ──
        if not agent:
            self.send_json(200, {
                "jsonrpc": "2.0", "id": req_id,
                "error": {"code": -32001, "message": "unauthorized"},
            })
            return

        if method == "tools/list":
            self.send_json(200, {
                "jsonrpc": "2.0", "id": req_id,
                "result": {"tools": TOOLS},
            })

        elif method == "tools/call":
            params = request.get("params", {})
            if isinstance(params, dict):
                name = params.get("name", "")
                arguments = params.get("arguments", {})
            else:
                name = ""
                arguments = {}

            if name not in TOOL_MAP:
                self.send_json(200, {
                    "jsonrpc": "2.0", "id": req_id,
                    "error": {"code": -32602, "message": f"unknown tool: {name}"},
                })
                return

            cmd_prefix = TOOL_MAP[name]
            args_str = arguments.get("args", "").strip()
            full_cmd = f"{cmd_prefix} {args_str}".strip()

            # Check permission
            err = check_permission(agent, full_cmd)
            if err:
                self.send_json(200, {
                    "jsonrpc": "2.0", "id": req_id,
                    "error": {"code": -32002, "message": f"permission denied: {err}"},
                })
                return

            # Execute
            roundtable_path = getattr(self.server, "roundtable_path", ROUNDTABLE)
            exit_code, output = execute_roundtable(roundtable_path, full_cmd)

            if len(output) > 50000:
                output = output[:50000] + "\n... (truncated)"

            if exit_code == 0:
                self.send_json(200, {
                    "jsonrpc": "2.0", "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": output or "(empty output)"}],
                        "isError": False,
                    },
                })
            else:
                self.send_json(200, {
                    "jsonrpc": "2.0", "id": req_id,
                    "error": {"code": -32003, "message": f"command failed (exit {exit_code}): {output[:2000]}"},
                })

        else:
            self.send_json(200, {
                "jsonrpc": "2.0", "id": req_id,
                "error": {"code": -32601, "message": f"method not found: {method}"},
            })

    def send_json(self, status: int, data):
        self.send_response(status)
        if isinstance(data, str) and not data:
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = json.dumps(data).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stderr.write(f"[MCP] {self.address_string()} - {args[0]} {args[1]} {args[2]}\n")


class MCPServer(http.server.HTTPServer):
    start_time: float
    roundtable_path: Path


def run_server(bind: str, port: int, roundtable_path: Path = ROUNDTABLE):
    server = MCPServer((bind, port), MCPHandler)
    server.start_time = time.time()
    server.roundtable_path = roundtable_path

    def shutdown_handler(sig, frame):
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    sys.stderr.write(f"[MCP] Listening on {bind}:{port} ({len(TOOLS)} tools loaded)\n")
    sys.stderr.flush()
    server.serve_forever()


def main():
    bind, port, roundtable_path = load_mcp_config()
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--bind" and i + 1 < len(args):
            bind = args[i + 1]
            i += 2
        elif args[i] == "--port" and i + 1 < len(args):
            try:
                port = int(args[i + 1])
            except ValueError:
                pass
            i += 2
        elif args[i] == "--help":
            print("Usage: python3 mcp-server.py [--bind IP] [--port PORT]")
            return
        else:
            i += 1
    run_server(bind, port, roundtable_path)


if __name__ == "__main__":
    main()