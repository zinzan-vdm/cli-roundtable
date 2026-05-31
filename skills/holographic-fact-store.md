---
name: holographic-fact-store
description: "Install and configure the Holographic Memory plugin (fact_store) — local SQLite fact store with FTS5, entity resolution, trust scoring, and HRR vector-symbolic algebra"
version: 1.0.0
---

# Holographic Memory (fact_store) — Installation

Enable the Holographic Memory plugin for a Hermes Agent session. Provides the `fact_store` tool (9 actions) and `fact_feedback` tool.

## Prerequisites

- Hermes Agent installed at `/opt/hermes/`
- Plugin files exist at `/opt/hermes/plugins/memory/holographic/`

## Setup Steps

### 1. Install numpy (optional but recommended)

```bash
python3 -m pip install numpy --break-system-packages
```

Without numpy the plugin works via FTS5 + Jaccard fallback (no HRR algebra).

### 2. Enable the memory provider

```bash
hermes config set memory.provider holographic
```

### 3. Configure plugin settings in config.yaml

Add at top level (same indent as `model:`, `agent:`):

```yaml
plugins:
  hermes-memory-store:
    db_path: "$HERMES_HOME/memory_store.db"
    auto_extract: true
    default_trust: 0.5
    min_trust_threshold: 0.3
    hrr_dim: 1024
    hrr_weight: 0.3
    temporal_decay_half_life: 30
```

### 4. Verify

```bash
python3 -c "
import sys
sys.path.insert(0, '/opt/hermes')
from plugins.memory.holographic.__init__ import HolographicMemoryProvider
p = HolographicMemoryProvider()
print('Provider:', p.name)
print('Available:', p.is_available())
"
```

### 5. Restart

`/reset` in chat or start a new session.

## Tools

**fact_store** — add, search, probe, related, reason, contradict, update, remove, list
**fact_feedback** — helpful (+0.05 trust), unhelpful (-0.10 trust)

## Key Paths

- DB: `$HERMES_HOME/memory_store.db`
- Plugin: `/opt/hermes/plugins/memory/holographic/`
