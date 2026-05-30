#!/usr/bin/env bash
# agent.sh — Control plane for Hermes Agent instances.
#
# Manages the lifecycle of one or more Hermes agents running natively.
# Each agent has an independent data directory and systemd unit
# identified by --name.
#
# Usage:
#   agent.sh [--name NAME] [--data-dir DIR] <command> [args...]
#
# Commands:
#   setup              Run hermes setup wizard for the agent
#   gateway up|down    Start/stop the systemd gateway unit
#   gateway restart    Restart the gateway unit
#   gateway status     Check gateway status (exit 0 = running)
#   gateway enable|disable  Toggle boot-time auto-start
#   gateway logs       Tail the gateway's journal
#   cli|exec [args...] Run hermes (interactive or one-shot)
#   path               Print the agent's data directory path
#
# Examples:
#   agent.sh --name reviewer setup
#   agent.sh --name reviewer gateway up
#   agent.sh --name prod cli
#   agent.sh --name prod exec doctor
#   cd "$(agent.sh --name reviewer path)"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
	source "${SCRIPT_DIR}/lib/common.sh"
else
	source /opt/hermes/lib/common.sh 2>/dev/null || {
		echo "Error: lib/common.sh not found alongside agent.sh or in /opt/hermes/" >&2
		exit 1
	}
fi

parse_agent_args "$@"
resolve_agent_paths
set -- "${REMAINING_ARGS[@]}"

# ── Help ──────────────────────────────────────────────────────────────────
usage() {
	cat <<-EOF
	Usage: $(basename "$0") [--name NAME] [--data-dir DIR] <command> [args...]

	Commands:
	  setup              Run hermes setup wizard
	  gateway up|down    Start/stop the systemd gateway unit
	  gateway restart    Restart the gateway unit
	  gateway status     Check gateway status (exit 0 = running)
	  gateway enable|disable  Toggle boot-time auto-start
	  gateway logs       Tail the gateway's journal
	  cli|exec [args...] Run hermes (interactive or one-shot)
	  path               Print the agent's data directory

	Examples:
	  $(basename "$0") --name reviewer setup
	  $(basename "$0") --name prod gateway up
	  $(basename "$0") --name prod exec doctor
	  cd "$$(basename "$0") --name reviewer path)"
	  $(basename "$0") cli
	EOF
	exit 0
}

die() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_agent() {
	if [[ ! -f "$LAUNCHER" ]]; then
		die "Agent '${AGENT_NAME}' not found at ${HERMES_DATA}
  Has it been bootstrapped? Run:
    sudo ${SCRIPT_DIR}/bootstrap.sh --name ${AGENT_NAME}"
	fi
}

# ── Commands ──────────────────────────────────────────────────────────────
cmd_setup() {
	require_agent
	info "Running setup wizard for '${AGENT_NAME}'..."
	"$LAUNCHER" setup
}

cmd_gateway() {
	local action="${1:-}"; shift 2>/dev/null || true
	case "$action" in
		up)
			info "Starting ${SYSTEMD_UNIT}..."
			systemctl start "$SYSTEMD_UNIT"
			systemctl --no-pager -l status "$SYSTEMD_UNIT" 2>&1 | head -5
			;;
		down)
			info "Stopping ${SYSTEMD_UNIT}..."
			systemctl stop "$SYSTEMD_UNIT"
			echo "Stopped."
			;;
		restart)
			info "Restarting ${SYSTEMD_UNIT}..."
			systemctl restart "$SYSTEMD_UNIT"
			systemctl --no-pager -l status "$SYSTEMD_UNIT" 2>&1 | head -5
			;;
		status)
			if systemctl is-active --quiet "$SYSTEMD_UNIT"; then
				systemctl --no-pager -l status "$SYSTEMD_UNIT" 2>&1 | head -10
			else
				echo "Gateway '${AGENT_NAME}' is NOT running."
				systemctl --no-pager -l status "$SYSTEMD_UNIT" 2>&1 | head -5
				exit 1
			fi
			;;
		enable)
			systemctl enable "$SYSTEMD_UNIT"
			echo "Enabled ${SYSTEMD_UNIT} on boot."
			;;
		disable)
			systemctl disable "$SYSTEMD_UNIT"
			echo "Disabled ${SYSTEMD_UNIT} on boot."
			;;
		logs)
			shift 2>/dev/null || true
			exec journalctl -u "$SYSTEMD_UNIT" -f "$@"
			;;
		*)
			echo "Unknown gateway subcommand: ${action:-<missing>}"
			echo "Usage: $(basename "$0") gateway up|down|restart|status|enable|disable|logs"
			exit 1
			;;
	esac
}

cmd_cli() {
	require_agent
	exec "$LAUNCHER" "$@"
}

cmd_exec() {
	require_agent
	exec "$LAUNCHER" "$@"
}

cmd_path() {
	echo "$HERMES_DATA"
}

# ── Dispatch ──────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
	usage
fi

case "${1}" in
	help|--help|-h)  usage ;;
	setup)            cmd_setup ;;
	gateway)          cmd_gateway "${2:-}" ;;
	cli|exec)         shift; cmd_cli "$@" ;;
	path)             cmd_path ;;
	*)
		echo "Unknown command: $1" >&2
		usage
		;;
esac
