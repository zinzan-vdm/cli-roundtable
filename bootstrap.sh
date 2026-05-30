#!/usr/bin/env bash
# bootstrap.sh — Provision a root-owned host for native Hermes Agent execution.
#
# ── Why this exists instead of using scripts/install.sh ──────────────────
#
# The official install.sh creates the venv inside the source tree
# ($INSTALL_DIR/venv/, e.g. /opt/hermes/venv/).  That works for a single
# agent but falls apart when multiple agents share one source tree and need
# independent venvs in their own data directories.
#
# This bootstrap:
#   • Creates the venv inside the agent's data dir (.venv/)
#   • Installs uv to /usr/local/bin (shared, one-time, root-owned)
#   • Builds a launcher shim that exports HERMES_HOME+HOME before exec
#   • Delegates npm install + build to the source tree (shared, one-time)
#   • Sets up systemd per agent
#
# If the official install script ever adds a --venv-dir flag, or Hermes
# gains first-class multi-agent venv management, switch to using it.
#
# ── Usage ────────────────────────────────────────────────────────────────
#
#   sudo ./bootstrap.sh                              # name: hermes
#   sudo ./bootstrap.sh --name arthur                 # custom name
#   sudo ./bootstrap.sh --name dev --data-dir /custom # explicit path
#   sudo ./bootstrap.sh --name arthur --clone-from /opt/hermes-agents/hermes
#   sudo ./bootstrap.sh --name arthur --systemd       # + enable on boot
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Script-scoped defaults ────────────────────────────────────────────────
AGENT_NAME="${AGENT_NAME:-hermes}"
HERMES_SRC="${HERMES_SRC:-/opt/hermes}"
HERMES_DATA_ARG=""
CLONE_FROM=""
INSTALL_SYSTEMD=false

# ═══════════════════════════════════════════════════════════════════════════
# Help
# ═══════════════════════════════════════════════════════════════════════════
usage() {
	cat <<-EOF
	Usage: $0 [OPTIONS]

	Provision a root-owned host for native Hermes Agent execution.

	Options:
	  --name NAME       Agent instance name        (default: hermes)
	                     Drives: agent-home dir, systemd unit name,
	                     default data-dir path.
	  --data-dir PATH   Data directory              (default: /opt/hermes-agents/<name>)
	  --src-dir PATH    Source tree path            (default: /opt/hermes)
	  --clone-from DIR  Seed state from another agent data dir
	  --systemd         Install + enable systemd unit for this agent
	  --help            This message

	Idempotent. Safe to re-run on an existing data dir (updates launcher,
	systemd unit, syncs deps).
	EOF
	exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Parse args (script-scoped, no global state mutations)
# ═══════════════════════════════════════════════════════════════════════════
while [[ $# -gt 0 ]]; do
	case "$1" in
		--name)         AGENT_NAME="$2";     shift 2 ;;
		--data-dir)     HERMES_DATA_ARG="$2"; shift 2 ;;
		--src-dir)      HERMES_SRC="$2";     shift 2 ;;
		--clone-from)   CLONE_FROM="$2";     shift 2 ;;
		--systemd)      INSTALL_SYSTEMD=true; shift ;;
		--help|-h)      usage ;;
		*) echo "Unknown: $1"; usage ;;
	esac
done

# ── Resolve paths via pure functions ──────────────────────────────────────
HERMES_DATA="$(agent_data_dir "$AGENT_NAME" "$HERMES_DATA_ARG")"
LAUNCHER="$(agent_launcher "$HERMES_DATA")"
LAUNCHER_DIR="$(dirname "$LAUNCHER")"
SYSTEMD_UNIT="$(agent_systemd_unit "$AGENT_NAME")"
HERMES_BIN="$(agent_hermes_bin "$HERMES_DATA")"
UV_BIN="$(agent_uv_bin "$HERMES_DATA")"
HOME_DIR="$(agent_home_dir "$HERMES_DATA")"

if [[ $EUID -ne 0 ]]; then
	echo "bootstrap.sh must run as root (apt packages, systemd)." >&2
	exit 1
fi

echo "── Hermes Native Bootstrap ─────────────────────────────────────────"
echo "  Agent:   ${AGENT_NAME}"
echo "  Source:  ${HERMES_SRC}"
echo "  Data:    ${HERMES_DATA}"
echo "  Systemd: ${INSTALL_SYSTEMD}"
echo "────────────────────────────────────────────────────────────────────"

# ═══════════════════════════════════════════════════════════════════════════
# 0 — Source tree (clone or update)
# ═══════════════════════════════════════════════════════════════════════════
REPO_URL="https://github.com/NousResearch/hermes-agent.git"

if [[ ! -d "$HERMES_SRC" ]]; then
	echo "[0/5] Cloning Hermes Agent source to ${HERMES_SRC}..."
	git clone --depth 1 "$REPO_URL" "$HERMES_SRC"
elif [[ -d "${HERMES_SRC}/.git" ]]; then
	echo "[0/5] Updating Hermes Agent source at ${HERMES_SRC}..."
	cd "$HERMES_SRC" && git pull --ff-only
else
	echo "[0/5] Source tree ${HERMES_SRC} exists (not a git repo)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 1 — System packages
# ═══════════════════════════════════════════════════════════════════════════
REQUIRED_PKGS=(
	build-essential curl nodejs npm python3 python3-dev libffi-dev
	ripgrep ffmpeg gcc procps git openssh-client tini
)
MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
	dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
	echo "[1/5] Installing: ${MISSING[*]}"
	apt-get update -qq
	apt-get install -y --no-install-recommends "${MISSING[@]}"
	rm -rf /var/lib/apt/lists/*
else
	echo "[1/5] System packages        ── all present"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 2 — Directory skeleton
# ═══════════════════════════════════════════════════════════════════════════
echo "[2/5] Data directory: ${HERMES_DATA}"

mkdir -p "${HERMES_DATA}/cron"
mkdir -p "${HERMES_DATA}/sessions"
mkdir -p "${HERMES_DATA}/logs"
mkdir -p "${HERMES_DATA}/skills"
mkdir -p "${HERMES_DATA}/skins"
mkdir -p "${HERMES_DATA}/plans"
mkdir -p "${HERMES_DATA}/cache/images"
mkdir -p "${HERMES_DATA}/cache/audio"
mkdir -p "${HOME_DIR}/bin"
mkdir -p "${HOME_DIR}/.hermes/memory"
mkdir -p "${HOME_DIR}/workspaces"
mkdir -p "${HOME_DIR}/.config"

# ═══════════════════════════════════════════════════════════════════════════
# 3 — Clone from existing agent (optional)
# ═══════════════════════════════════════════════════════════════════════════
if [[ -n "$CLONE_FROM" ]]; then
	echo "[3/5] Cloning state from: ${CLONE_FROM}"
	CLONE_FROM=$(realpath "$CLONE_FROM")
	if [[ ! -d "$CLONE_FROM" ]]; then
		echo "Error: source ${CLONE_FROM} not found"
		exit 1
	fi

	rsync -a --info=progress2 \
		--exclude='home/.cache/' \
		--exclude='home/.npm/' \
		--exclude='.venv/' \
		--exclude='cache/' \
		--exclude='*.db-wal' \
		--exclude='*.db-shm' \
		--exclude='node_modules/' \
		"${CLONE_FROM}/" "${HERMES_DATA}/"

	# Copy home sub-dir (workspaces, .gitconfig, credentials)
	if [[ -d "${CLONE_FROM}/home" ]]; then
		rsync -a --info=progress2 \
			--exclude='.cache/' \
			--exclude='.npm/' \
			"${CLONE_FROM}/home/" "${HOME_DIR}/"
	fi

	# Seed .env from clone if not already present
	if [[ ! -f "${HERMES_DATA}/.env" && -f "${CLONE_FROM}/.env" ]]; then
		cp "${CLONE_FROM}/.env" "${HERMES_DATA}/.env"
	fi

	cat <<-CLEANUP
	       Clone complete.
	       To trim for a clean secondary agent:
	         rm -rf ${HERMES_DATA}/sessions \\
	                ${HERMES_DATA}/cron \\
	                ${HERMES_DATA}/state.db

	CLEANUP
else
	echo "[3/5] Fresh install           ── seeding default config"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 3.5 — Seed config files (if missing)
# ═══════════════════════════════════════════════════════════════════════════
for pair in \
	"config.yaml:cli-config.yaml.example" \
	".env:.env.example" \
	"SOUL.md:docker/SOUL.md"; do
	target="${pair%%:*}"
	example="${pair##*:}"
	if [[ ! -f "${HERMES_DATA}/${target}" && -f "${HERMES_SRC}/${example}" ]]; then
		cp "${HERMES_SRC}/${example}" "${HERMES_DATA}/${target}"
		echo "       Seeded ${target}"
	fi
done

# ═══════════════════════════════════════════════════════════════════════════
# 4 — Install uv (shared system-wide, not inside the venv)
# ═══════════════════════════════════════════════════════════════════════════
echo "[4/5] Installing uv (shared)"

if ! command -v uv &>/dev/null; then
	echo "       Installing uv to /usr/local/bin..."
	curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh 2>&1
else
	echo "       uv (system)          ── present at $(command -v uv)"
fi
UV_CMD="$(command -v uv)"

# ═══════════════════════════════════════════════════════════════════════════
# 4.1 — Python venv + deps (per-agent, inside data dir)
# ═══════════════════════════════════════════════════════════════════════════
echo "       Python environment"

if [[ ! -f "${HERMES_BIN}" ]]; then
	echo "       Creating venv..."
	"$UV_CMD" venv --clear "${HERMES_DATA}/.venv" 2>&1
else
	echo "       venv                 ── present"
fi

echo "       Syncing Python deps..."
cd "${HERMES_SRC}"
VIRTUAL_ENV="${HERMES_DATA}/.venv" "$UV_CMD" sync --frozen --extra all 2>&1

echo "       Installing hermes-agent (editable, no-deps)..."
VIRTUAL_ENV="${HERMES_DATA}/.venv" "$UV_CMD" pip install --no-cache-dir --no-deps -e "." 2>&1

# ═══════════════════════════════════════════════════════════════════════════
# 4.5 — Launcher shim (sets HERMES_HOME + HOME per agent)
# ═══════════════════════════════════════════════════════════════════════════
echo "       Installing launcher..."
mkdir -p "$LAUNCHER_DIR"
cat > "${LAUNCHER}" <<-LAUNCHER_SCRIPT
	#!/usr/bin/env bash
	# Hermes Agent launcher for instance '${AGENT_NAME}'
	unset PYTHONPATH
	unset PYTHONHOME
	export HERMES_HOME="${HERMES_DATA}"
	export HOME="${HOME_DIR}"
	exec "${HERMES_BIN}" "\$@"
LAUNCHER_SCRIPT
chmod 755 "${LAUNCHER}"
echo "       Launcher: ${LAUNCHER}"

# ═══════════════════════════════════════════════════════════════════════════
# 4.6 — npm install + build (shared source tree, one-time)
# ═══════════════════════════════════════════════════════════════════════════
echo "       Node.js dependencies"
cd "${HERMES_SRC}"

if [[ ! -d "node_modules" ]]; then
	echo "       Installing npm packages..."
	npm install --prefer-offline --no-audit 2>&1
	(cd web && npm install --prefer-offline --no-audit) 2>&1
	(cd ui-tui && npm install --prefer-offline --no-audit) 2>&1
	npm cache clean --force 2>&1
else
	echo "       npm packages         ── present"
fi

echo "       Building web dashboard..."
(cd web && npm run build) 2>&1
echo "       Building terminal UI..."
(cd ui-tui && npm run build) 2>&1

# ═══════════════════════════════════════════════════════════════════════════
# 4.7 — Sync bundled skills (manifest-based, preserves user edits)
# ═══════════════════════════════════════════════════════════════════════════
if [[ -f "${HERMES_SRC}/tools/skills_sync.py" ]]; then
	echo "       Syncing bundled skills..."
	VIRTUAL_ENV="${HERMES_DATA}/.venv" "${HERMES_BIN%/*}/python" \
		"${HERMES_SRC}/tools/skills_sync.py" 2>&1
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4.8 — Create /usr/local/bin/hermes symlink for the primary agent
# ═══════════════════════════════════════════════════════════════════════════
if [[ ! -L /usr/local/bin/hermes ]]; then
	ln -sf "${LAUNCHER}" /usr/local/bin/hermes
	echo "       Symlinked /usr/local/bin/hermes → ${LAUNCHER}"
elif [[ "$(readlink /usr/local/bin/hermes)" != "${LAUNCHER}" ]]; then
	echo "       NOTE: /usr/local/bin/hermes points elsewhere"
	echo "         $(readlink /usr/local/bin/hermes)"
	echo "         To change: ln -sf ${LAUNCHER} /usr/local/bin/hermes"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 5 — Systemd unit (optional)
# ═══════════════════════════════════════════════════════════════════════════
if $INSTALL_SYSTEMD; then
	echo "[5/5] Installing systemd unit: ${SYSTEMD_UNIT}"

	cat > "/etc/systemd/system/${SYSTEMD_UNIT}" <<-SERVICE
	[Unit]
	Description=Hermes Agent Gateway (${AGENT_NAME})
	Documentation=https://hermes-agent.nousresearch.com/docs
	After=network-online.target
	Wants=network-online.target
	[Service]
	Type=simple
	ExecStart=${LAUNCHER} gateway run
	Environment=HERMES_HOME=${HERMES_DATA}
	Environment=HOME=${HOME_DIR}
	Restart=always
	RestartSec=5
	StandardOutput=journal
	StandardError=journal
	OOMScoreAdjust=-500
	MemoryMax=4G
	CPUQuota=200%
	[Install]
	WantedBy=multi-user.target
	SERVICE

	systemctl daemon-reload
	systemctl enable "${SYSTEMD_UNIT}"
	echo "       Enabled. Start:  systemctl start ${SYSTEMD_UNIT}"
else
	echo "[5/5] Systemd               ── skipped"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
cat <<-SUMMARY

	── Bootstrap complete: agent '${AGENT_NAME}' ──────────────────────────

	  CLI:   /usr/local/bin/hermes chat
	  Launcher: export PATH="${LAUNCHER_DIR}:\$PATH"

SUMMARY
if $INSTALL_SYSTEMD; then
	echo "  Gateway: systemctl start ${SYSTEMD_UNIT}"
	echo "  Logs:    journalctl -u ${SYSTEMD_UNIT} -f"
fi
cat <<-SUMMARY

	  Config:  ${HERMES_DATA}/config.yaml
	  Env:     ${HERMES_DATA}/.env
	  Home:    ${HOME_DIR}

	  Setup wizard:
	    ${LAUNCHER} setup

	  Health check:
	    ${LAUNCHER} doctor

	  Add another agent:
	    sudo ./bootstrap.sh --name reviewer \\
	        --clone-from ${HERMES_DATA}

	SUMMARY

set +euo pipefail
