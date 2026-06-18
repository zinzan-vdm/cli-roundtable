# Containerfile — Hermes Agent runtime image.
#
# Builds the Hermes Agent source, Python venv, and web/TUI UI into
# a single deployable image. Each container instance gets its own
# volume-mounted data directory for isolated state.
#
# Upgrade: bump ARG HERMES_VERSION, rebuild, docker compose up -d.

FROM ubuntu:24.04 AS base

ARG HERMES_VERSION=v2026.5.29.2

# ── System packages ────────────────────────────────────────────
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential curl git nodejs npm python3 python3-dev \
        python3-venv libffi-dev ripgrep ffmpeg gcc procps \
        openssh-client tini && \
    rm -rf /var/lib/apt/lists/*

# ── uv (Python package manager) ────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | \
    env UV_INSTALL_DIR=/usr/local/bin sh

# ── Hermes Agent source @ pinned version ───────────────────────
WORKDIR /opt/hermes
RUN git clone --branch "$HERMES_VERSION" --single-branch \
        https://github.com/NousResearch/hermes-agent.git . && \
    git log --oneline -1

# ── Python venv ────────────────────────────────────────────────
RUN uv venv /opt/hermes/.venv
ENV PATH="/opt/hermes/.venv/bin:$PATH"
RUN uv pip install --no-cache-dir -e ".[all]"

# ── Web dashboard & TUI build ─────────────────────────────────
RUN npm install --prefer-offline --no-audit && \
    (cd web && npm install --prefer-offline --no-audit) && \
    (cd ui-tui && npm install --prefer-offline --no-audit) && \
    npm cache clean --force && \
    (cd web && npm run build) && \
    (cd ui-tui && npm run build)

# ── Runtime ────────────────────────────────────────────────────
ENV HERMES_HOME=/hermes-data
EXPOSE 9119

ENTRYPOINT ["tini", "--"]
CMD ["hermes", "gateway", "run"]
