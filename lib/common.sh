# lib/common.sh — Pure functions for Hermes Agent path resolution.
#
# Each function takes inputs as arguments and prints the result to stdout.
# No global variable mutations. Safe to call from any script.
#
# Usage:
#   source "$(dirname "$0")/lib/common.sh"
#   DATA_DIR="$(agent_data_dir "reviewer")"
#   LAUNCHER="$(agent_launcher "$DATA_DIR")"

# ── agent_data_dir ────────────────────────────────────────────────────────
# Usage: agent_data_dir <agent_name> [data_dir_override]
# Prints the agent's data directory.
agent_data_dir() {
	local name="${1:?agent_data_dir: agent name required}"
	local override="${2:-}"
	if [[ -n "$override" ]]; then
		echo "$override"
	else
		echo "/opt/hermes-agents/${name}"
	fi
}

# ── agent_launcher ────────────────────────────────────────────────────────
# Usage: agent_launcher <data_dir>
# Prints the path to the agent's launcher script.
agent_launcher() {
	local data_dir="${1:?agent_launcher: data dir required}"
	echo "${data_dir}/home/.local/bin/hermes"
}

# ── agent_hermes_bin ──────────────────────────────────────────────────────
# Usage: agent_hermes_bin <data_dir>
# Prints the path to the agent's venv hermes binary.
agent_hermes_bin() {
	local data_dir="${1:?agent_hermes_bin: data dir required}"
	echo "${data_dir}/.venv/bin/hermes"
}

# ── agent_uv_bin ──────────────────────────────────────────────────────────
# Usage: agent_uv_bin <data_dir>
# Prints the path to the agent's venv uv binary.
agent_uv_bin() {
	local data_dir="${1:?agent_uv_bin: data dir required}"
	echo "${data_dir}/.venv/bin/uv"
}

# ── agent_systemd_unit ────────────────────────────────────────────────────
# Usage: agent_systemd_unit <agent_name>
# Prints the systemd unit name for the agent.
agent_systemd_unit() {
	local name="${1:?agent_systemd_unit: agent name required}"
	echo "hermes-gateway-${name}.service"
}

# ── agent_home_dir ────────────────────────────────────────────────────────
# Usage: agent_home_dir <data_dir>
# Prints the HOME directory for the agent's subprocesses.
agent_home_dir() {
	local data_dir="${1:?agent_home_dir: data dir required}"
	echo "${data_dir}/home"
}
