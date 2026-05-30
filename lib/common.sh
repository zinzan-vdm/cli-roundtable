# _hermes-common.sh — Shared arg parsing and path resolution for bootstrap.sh & agent.sh
#
# Source this from scripts in the same directory:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/_hermes-common.sh"
#
# After sourcing:
#   AGENT_NAME, HERMES_SRC are set
#   HERMES_DATA, LAUNCHER, SYSTEMD_UNIT are resolved

# ── Defaults ──────────────────────────────────────────────────────────────
: "${AGENT_NAME:=hermes}"
: "${HERMES_SRC:=/opt/hermes}"
HERMES_DATA=""      # resolved below, may be set explicitly
LAUNCHER=""         # resolved below
SYSTEMD_UNIT=""     # resolved below

# ── Parse agent arguments ─────────────────────────────────────────────────
# Call this early, before your own arg parsing. Recognises:
#   --name, --data-dir, --src-dir
# Stops at the first non-flag argument (your subcommand).
parse_agent_args() {
	local args=("$@")
	local positional=()
	while [[ ${#args[@]} -gt 0 ]]; do
		case "${args[0]}" in
			--name)
				AGENT_NAME="${args[1]}"
				shift 2 ;;
			--data-dir)
				HERMES_DATA="${args[1]}"
				shift 2 ;;
			--src-dir)
				HERMES_SRC="${args[1]}"
				shift 2 ;;
			--)
				shift
				positional+=("$@")
				break ;;
			-*)
				# Unknown flag — stop and let the caller handle it
				positional+=("${args[0]}")
				shift ;;
			*)
				positional+=("${args[0]}")
				shift ;;
		esac
	done
	# shellcheck disable=SC2034  # used by caller
	REMAINING_ARGS=("${positional[@]}")
}

# ── Resolve paths from name ───────────────────────────────────────────────
# Sets HERMES_DATA, LAUNCHER, SYSTEMD_UNIT based on AGENT_NAME and any
# explicit overrides.
resolve_agent_paths() {
	if [[ -z "$HERMES_DATA" ]]; then
		HERMES_DATA="/opt/hermes-agents/${AGENT_NAME}"
	fi
	LAUNCHER="${HERMES_DATA}/home/.local/bin/hermes"
	SYSTEMD_UNIT="hermes-gateway-${AGENT_NAME}.service"
}

# ── Guard: must be sourced, not executed ──────────────────────────────────
# (no-op guard — this file is designed to always be sourced)
true
