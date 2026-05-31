---
name: discord-workspaces
description: Scope agent operations to workspace channels on Discord. Routes context based on channel ID — admin (home channel) vs isolated workspace. Enforces filesystem, memory, skills, and secrets discipline per workspace.
version: 2.1.0
author: Horo
license: MIT
metadata:
  hermes:
    tags: [workspace, isolation, discord, context, scoping]
    related_skills: [systematic-debugging, writing-plans]
---

# Discord Workspace Isolation Protocol

> 🏗️ **Architecture**: The critical enforcement rules (path isolation,
> WORKSPACE_ROOT derivation, exceptions) live in **always-present memory**,
> injected every turn without any `skill_view()` call. This skill is the
> **deep reference** — load it when you need the full protocol: owner
> override mechanics, secrets handling, container naming, workspace setup,
> session_search conventions, or cross-workspace operations.

---

## 0. Installation & Setup

### 0a. Install the Skill

Place `SKILL.md` at `~/.hermes/skills/discord-workspaces/SKILL.md` (or
the skills path configured for your agent). Once placed, it appears in the
available skills list and can be loaded with `skill_view(name='discord-workspaces')`.

### 0b. First-Time Setup

The agent MUST run the setup script on first use:

```
bash scripts/setup.sh
```

This creates:
- `~/discord-workspaces/` — the root directory for all workspaces
- `~/discord-workspaces/workspaces.yaml` — the mapping file (empty)

If the agent cannot find or run the setup script, it MUST create these manually:

```
mkdir -p ~/discord-workspaces
touch ~/discord-workspaces/workspaces.yaml
```

Then write the initial mapping content:

```yaml
# Channel snowflake → workspace name
# Workspace channels are scoped to ~/discord-workspaces/{name}/
workspaces: {}
```

### 0c. Seed the Always-Present Memory Entry

The agent MUST save the critical enforcement rules to persistent memory.
This memory entry covers ALL Discord channel contexts — admin, workspace,
and unknown. It is injected every turn without any `skill_view()` call.

```text
DISCORD CHANNEL CONTEXT PROTOCOL — ALWAYS APPLIES:
- HOME_CHANNEL_ID is resolved from runtime config
- Every Discord message: read ~/discord-workspaces/workspaces.yaml
- Determine context:
  a) channel_id == HOME_CHANNEL_ID → ADMIN CONTEXT (unrestricted)
  b) channel_id in workspaces map → WORKSPACE CONTEXT (scoped below)
  c) not found → UNKNOWN CHANNEL (see below)

WORKSPACE CONTEXT (when channel maps to a workspace X):
- WORKSPACE_ROOT = ~/discord-workspaces/{X}/
- Every file tool (read_file/write_file/patch/search_files) path MUST
  start with WORKSPACE_ROOT
- If it does not → REFUSE, do not proceed
- Exceptions: /tmp/, ~/hermes-agent-cache/, global memory (read-only)
- terminal() workdir MUST be set to WORKSPACE_ROOT or subdirectory
- Owner override with explicit phrase: "As the owner, ..."
- Load discord-workspaces skill for full protocol reference

UNKNOWN CHANNEL (not home, not in workspaces):
- Do NOT operate in the channel as if it's unrestricted
- Reply in-channel stating the channel is unmapped
- Offer to add a mapping if the sender has owner privileges
- Only proceed with default non-scoped behavior AFTER noting the
  unmapped state and getting instruction from the user
```

Use `memory(action='replace', target='memory', old_text='...')` to update
the existing entry. These rules are always-on — no skill_view() gate needed.

### 0d. Verify Installation

After setup, confirm readiness:

1. `ls ~/discord-workspaces/` → exists and is a directory
2. `ls ~/discord-workspaces/workspaces.yaml` → exists and is readable
3. `skill_view(name='discord-workspaces')` → loads without errors
4. The always-present memory entry is present and correct

---

## 1. Startup: Resolve Home Channel & Owner

On every session start, determine two values from the runtime configuration
and hold them for the duration of the session:

| Value | Source | Example |
|-------|--------|---------|
| `HOME_CHANNEL_ID` | Discord platform config in gateway / `.env` | `1509646720231801112` |
| `OWNER_ID` | First user in `config.yaml` (users[0].id) | Discord user snowflake |

These values define **Admin Context**: messages from `HOME_CHANNEL_ID` (or
threads within it) are admin. Messages from any other channel are workspace
context (if mapped) or unknown-channel fallback.

> **Why runtime config?** This skill is generic — agents have different home
> channels and owners. Hardcoding would break portability.

---

## 2. Channel-to-Workspace Mapping

Mapping is stored at `~/discord-workspaces/workspaces.yaml`:

```yaml
# Channel snowflake → workspace name
workspaces:
  "123456789012345678": "my-project"
  "987654321098765432": "client-site"
```

- Adding an entry = workspace exists. No setup ceremony.
- Removing an entry = workspace is decommissioned (files remain on disk).
- Threads **inherit** the parent channel's context.
- If a channel is renamed, `workspaces.yaml` must be updated manually.
- The mapping file is the **single source of truth** for listing workspaces.

At startup, read `workspaces.yaml` and build the in-memory lookup map.
If it doesn't exist yet, create it with an empty `workspaces:` stanza.

---

## 3. Execution Context Determination

On every message:

```
1. Identify source channel_id and thread parent_id (if applicable)
2. If channel_id == HOME_CHANNEL_ID →
     ADMIN CONTEXT (go to §4)
3. Else, look up channel_id in workspaces map →
     WORKSPACE CONTEXT (go to §5)
4. Else →
     UNKNOWN CHANNEL (go to §6)
```

### 3a. Channel Identity

Your **home channel** identity comes from the runtime config, not
`workspaces.yaml`. The mapping file only stores remote/channel-to-workspace
entries — it does not list the home channel.

---

## 4. Admin Context (Home Channel)

You have **unrestricted access** to all workspaces and system resources.

**Permitted actions:**
- Create, configure, or delete workspaces (add/remove `workspaces.yaml` entries)
- Read/write files in any workspace directory
- Manage the channel-to-workspace mapping
- View or modify global config (read-only unless directed)
- Perform cross-workspace operations (copy files, compare repos)
- System maintenance (Docker, disk, processes, cron jobs)
- List all workspaces from `workspaces.yaml`

**Restrictions:**
- When a non-owner sends a message in the home channel, flag
  cross-workspace or destructive operations for owner confirmation.
  ("This operation affects workspace X. I need owner confirmation to proceed.")
- Do not auto-inject workspace memories — only read/write workspace data when
  explicitly directed.

The home channel is your **root shell** — administration, not day-to-day work.

---

## 5. Workspace Context (Workspace Channel)

You are **constrained to the mapped workspace's boundaries**.

### 5a. Path Resolution

```
WORKSPACE_NAME = workspaces[channel_id]
WORKSPACE_ROOT  = ~/discord-workspaces/{WORKSPACE_NAME}/
```

All paths below are shown as **absolute** to eliminate ambiguity.
The tilde `~` always refers to your configured home directory.

| Resource | Path |
|----------|------|
| Workspace root | `~/discord-workspaces/{WORKSPACE_NAME}/` |
| Workspace memory | `~/discord-workspaces/{WORKSPACE_NAME}/.hermes/memory/` |
| Workspace skills | `~/discord-workspaces/{WORKSPACE_NAME}/.hermes/skills/` |
| Workspace secrets | `~/discord-workspaces/{WORKSPACE_NAME}/.secrets/` |
| Project files | Anywhere under `WORKSPACE_ROOT` |

### 5b. Filesystem Rules (Mandatory)

> ⚠️ **Enforcement**: These rules are stored in always-present memory.
> Every file tool call **MUST** resolve within `WORKSPACE_ROOT`.

**Before every file operation:**
1. Expand the target path to an absolute path.
2. Verify it starts with `WORKSPACE_ROOT` (the expanded absolute form).
3. If it does not — **refuse the operation** unless an explicit owner override
   is in effect (see §8).

**Allowed exceptions:**
- Temporary files: `/tmp/` and `~/hermes-agent-cache/` are acceptable for
  staging data. Final artifacts go inside `WORKSPACE_ROOT`.
- Global memory: read-only, unless writing a global fact (host environment,
  user profile).
- System config: read-only, never expose contents in-channel.
- `workspaces.yaml`: read-only in workspace context.

**Terminal command discipline:**
- Always set `workdir=` to `WORKSPACE_ROOT` (or a subdirectory within it).
- Never `cd` outside `WORKSPACE_ROOT` via shell commands in a workspace
  context.

### 5c. Workspace Skeleton (Lazy Initialization)

A workspace is "ready" when its entry exists in `workspaces.yaml`. The agent
creates the directory skeleton **on first operation** inside the workspace:

```
mkdir -p ~/discord-workspaces/{name}/.hermes/memory/
mkdir -p ~/discord-workspaces/{name}/.hermes/skills/
mkdir -p ~/discord-workspaces/{name}/.secrets/
```

If a workspace directory already exists but lacks some subdirectories,
create the missing ones. Never fail because a subdirectory is absent.

### 5d. Memory Loading

Load order on every workspace-context message:

1. **Global memory** — always loaded (host facts, user profile, this protocol,
   tool conventions). The workspace isolation enforcement rules are here.
2. **Workspace memory** (`{WORKSPACE_ROOT}/.hermes/memory/`) — loaded
   additionally in workspace context. May contain project decisions, notes,
   per-workspace preferences.

In admin context, you may read/write any workspace's memory only when
explicitly directed. Do not auto-load workspace memories into admin context.

### 5e. Skills Loading

Load order on every workspace-context message:

1. **Global skills** — always loaded (tool usage, system admin, dev
   conventions).
2. **Workspace skills** (`{WORKSPACE_ROOT}/.hermes/skills/`) — loaded
   additionally in workspace context. May contain project-specific build
   processes, test commands, deployment workflows.
3. **This skill** — load via `skill_view(name='discord-workspaces')` when
   you need the full protocol (owner override, secrets, container naming,
   workspace setup, cross-workspace ops, session_search conventions).

Workspace skills **may override** global skills for project-specific behavior.

### 5f. Secrets Handling

- Per-workspace secrets live at `{WORKSPACE_ROOT}/.secrets/`.
- Do **NOT** read, list, or expose secrets from another workspace.
- Never echo secrets back in-channel unless explicitly asked (and even then,
  warn about exposure).
- Ensure `.secrets/` is in `.gitignore` — never commit secrets.
- Git repos within the workspace manage their own credentials via
  `.git/config` — use those; do not duplicate them in `.secrets/`.

### 5g. `session_search` Best Practice

The session database does not natively tag sessions by workspace. To make
cross-session recall reliable within a workspace:

**Recommended convention:** Prefix session names and task descriptions with
the workspace name:

> "`my-project`: fix the auth endpoint 401 error"
> "`client-site`: deploy v2.3 to staging"

This lets you query with `session_search(query="my-project:")` which FTS5
treats as a prefix match, recalling all sessions from that workspace.

When searching in workspace context: prefer queries scoped to the current
workspace name. When in admin context: search across all workspaces.

### 5h. Non-Owner Users

Non-owner users operating in a workspace channel have **full operational
access within that workspace** — they can read/write files, run commands,
manage project files, etc. They do NOT have:

- Access to other workspaces.
- Ability to override scoping boundaries.
- Owner-level privileges (cross-workspace ops, system admin in the
  workspace channel).

The owner is the exclusive "override" authority (see §8).

---

## 6. Unknown Channel (Hard Block)

If a message arrives in a channel not found in `workspaces.yaml` and not the
home channel:

1. Reply **in-channel** stating the channel is unmapped and **read-only**.
2. Offer to add a mapping if the sender has owner privileges.
3. **READ-ONLY MODE** — You may answer questions, provide information, read
   files, and chat. You MAY NOT:
   - Write, create, modify, or delete any files
   - Run commands with side effects (installs, builds, network writes)
   - Start background processes, cron jobs, or scheduled tasks
   - Access the fact_store or memory for writing
4. **Override** — The owner may unlock write access by using the explicit
   phrase "As the owner, ..." (see §8). A bare instruction like "create
   file X" does NOT count as an override.
5. Until overridden, any request requiring write access gets the reply:
   > "This channel is unmapped and in read-only mode. If you're the owner,
   > use 'As the owner, ...' to proceed, or map this channel to a workspace."

### Rationale

Unknown channels have no defined boundary. Without a workspace root to scope
into, a write operation could affect any path on the system — a security hole.
By blocking writes by default, we make the owner intentionally opt in to
operating from an unscoped location.

---

## 7. Container Usage

When workspace-internal services need isolation (dev servers, databases, build
environments):

```
docker run --name {agent-name}-{WORKSPACE_NAME}-{service-name} ...
```

- Name containers with the workspace prefix so ownership is clear from a
  `docker ps` listing.
- Mount volumes from `WORKSPACE_ROOT` when the container needs project files.
- Use workspace-specific Docker networks if service isolation is needed
  between workspaces.
- Containers are tools — they are not the isolation mechanism. Workspace
  boundaries are enforced by your prompt discipline and filesystem rules.

---

## 8. Owner Override

The owner (identified at startup) has full authority in all contexts:

| Context | Override scope |
|---------|---------------|
| Home channel | Unrestricted system administration |
| Any workspace channel | Can override scoping with explicit instruction |

**Override trigger phrase:** The owner must say something like:
> "As the owner, copy file X from workspace-foo to workspace-bar."

Without this explicit override declaration, workspace scoping stays in
effect even for the owner within a workspace channel. This prevents
accidental cross-workspace operations.

---

## 9. Cross-Workspace Invariants

| Rule | Enforcement |
|------|------------|
| Never share files between workspaces | Filesystem resolution check (§5b) |
| Never share credentials between workspaces | `.secrets/` isolation (§5f) |
| Never expose workspace A's data in workspace B's channel | Channel mapping (§3) |
| Never leak config contents in-channel | `workspaces.yaml` and system config are read-only in workspace context |
| Owner can override any rule with explicit instruction | Owner privilege (§8) |

---

## 10. Operation Flow (Complete)

On every message:

```
1. Identify source channel and thread parent (if applicable)
2. Resolve HOME_CHANNEL_ID and OWNER_ID from runtime config (if not already
   resolved this session)
3. Read workspaces.yaml → build lookup map
4. Determine context:
   a. channel_id == HOME_CHANNEL_ID → ADMIN CONTEXT (§4)
   b. channel_id in workspaces map → WORKSPACE CONTEXT (§5)
   c. not found → UNKNOWN CHANNEL (§6)
5. If workspace context:
   a. Set WORKSPACE_NAME and WORKSPACE_ROOT
   b. Lazy-init skeleton directories if absent
   c. Set terminal workdir to WORKSPACE_ROOT
   d. Global memory (with enforcement rules) is already loaded
   e. Load global skills + overlay workspace skills
6. Process the request within the determined context
   - File operations checked against the always-present memory rule
   - If full protocol details needed → load discord-workspaces skill
7. On completion: do NOT carry context between turns. Re-determine
   context fresh on the next message.
```

---

## 11. Reliability Checklist

Enforcement rules are in memory. When you need the full protocol, load this skill.

Before a workspace-context file operation, verify:

- [ ] Target path expanded to absolute form
- [ ] Target path starts with `WORKSPACE_ROOT`
- [ ] Not accessing another workspace's `.secrets/` or `.hermes/`
- [ ] Not echoing secrets in-channel
- [ ] `terminal()` has `workdir=` set to `WORKSPACE_ROOT` or subdirectory
- [ ] Container names are prefixed with `{agent-name}-{WORKSPACE_NAME}-`

Before responding to a non-owner request in admin context:

- [ ] Flag cross-workspace or destructive operations
- [ ] Wait for owner confirmation before proceeding

---

## 12. Test Battery

After installation or modification, validate the skill by running these tests
from the actual Discord channels. The test battery covers all contexts and
enforcement paths.

**Reference:** `references/test-battery.md` — full test scenarios, expected
outcomes, and pass/fail criteria.
