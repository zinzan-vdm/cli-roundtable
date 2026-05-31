---
name: gh-pr-report
description: "Compile a formatted PR status report across multiple GitHub repos — query open/draft PRs, compute age & comment stats, output grouped by repo with summary."
version: 1.1.0
author: Arthur
platforms: [linux, macos]
metadata:
  hermes:
    tags: [GitHub, Pull-Requests, Reporting, Automation]
    related_skills: [github-pr-workflow, github-auth, github-code-review]
---

# GitHub Pull Request Reporting

Compile a formatted list of open (and draft) pull requests across a given set of GitHub repositories, grouped by repo with age and comment stats.

## Prerequisites

- `gh` CLI installed and authenticated (see `github-auth` skill)
- Access to the target repos (public or authenticated access)

## Workflow

### Step 1 — Source the Repo List

You need a list of `<org>/<repo>` pairs. The user will provide this in one of three ways:

**Option A — explicit list:** The user names specific repos (e.g. `"acmecorp/api, libs/core"`).

**Option B — an org name:** The user says "all repos under `<org>`". Discover them with:
```bash
gh repo list <org> --limit 200 --json nameWithOwner --jq '.[].nameWithOwner'
```

**Option C — a local workspace directory:** The user points to a directory of cloned repos. List subdirectories:
```bash
ls <workspace_dir>/
```

### Step 2 — Query PRs Per Repo

For each repository, run:
```bash
gh pr list --repo <org>/<repo> --state open --json number,title,author,createdAt,isDraft,comments,url
```

Returns a JSON array. If empty or `[]`, that repo has no open PRs — skip it entirely.

### Step 3 — Compute Derived Fields

For each PR, compute:

- **age_in_days**: `floor((now_utc - createdAt) / 86400000)` — use current UTC time.
- **num_unresolved**: The `comments` array from `gh pr list --json` only carries `{id, author, body, createdAt}` — there is no `isResolved` or `isMinimized` flag. Always prefix with `~` to indicate approximation.
- **num_total**: `len(comments)`.
- **is_draft**: boolean from `isDraft`.

### Step 4 — Format Output

Group by repository name. Order repos **alphabetically**. Within each repo, order PRs by **age descending** (oldest first).

Format each group as:

```
**<repo>**
- [#<number>](<url>) (<author>) [DRAFT] - <age>d / <unres> unres / <total> total — <title>
```

Rules:
- PR number **must** be hyperlinked to the PR URL using Markdown `[#N](url)` syntax.
- `[DRAFT]` suffix only if `isDraft` is true.
- Age is an integer (whole days), no decimals.
- Comment columns: `<count>` unres / `<count>` total.
- Use `~` prefix on unres (always approximate — see pitfalls).

### Step 5 — Summary Line

After all groups, add a blank line then:

```
Total: <N> open PRs across <M> repos
```

Omit any repo with zero open PRs entirely — no empty heading.

### Example Output

```
**api-config**
- [#1](https://github.com/example-org/api-config/pull/1) (alice) - 31d / ~0 unres / 0 total — Config management base setup

**js-core-clients**
- [#10](https://github.com/example-org/js-core-clients/pull/10) (bob) - 39d / ~0 unres / 0 total — add authentication client
- [#15](https://github.com/example-org/js-core-clients/pull/15) (carol) - 11d / ~2 unres / 3 total — feat: Add ProductsClient

**js-lib-commons**
- [#8](https://github.com/example-org/js-lib-commons/pull/8) (alice) **[DRAFT]** - 1d / ~0 unres / 0 total — feature: added Where lib

Total: 3 open PRs across 3 repos
```

## Script — Automated Report Generation

A reusable Python script. Supports three modes of sourcing repos:

### Usage

```bash
# Mode A: explicit list
python3 pr-report.py --repos "acmecorp/api,acmecorp/libs/core"

# Mode B: all repos from an org
python3 pr-report.py --org acmecorp

# Mode C: reading from stdin (piped list)
echo -e "acmecorp/api\nacmecorp/libs/core" | python3 pr-report.py --stdin
```

### Script

Save as `pr-report.py`:

```python
#!/usr/bin/env python3
"""Generate a formatted PR status report across GitHub repos."""
import argparse, json, subprocess, sys
from datetime import datetime, timezone
from math import floor

def fetch_repos(org=None, repos=None, stdin=False):
    """Return a list of 'org/repo' strings."""
    if repos:
        return [r.strip() for r in repos.split(",") if r.strip()]
    if org:
        r = subprocess.run(
            ["gh", "repo", "list", org, "--limit", "200",
             "--json", "nameWithOwner", "--jq", ".[].nameWithOwner"],
            capture_output=True, text=True, check=True, timeout=60
        )
        return r.stdout.strip().splitlines()
    if stdin:
        return [line.strip() for line in sys.stdin if line.strip()]
    raise ValueError("No repo source provided (--repos, --org, or --stdin)")

def main():
    parser = argparse.ArgumentParser(description="PR status report")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--repos", help="Comma-separated list of org/repo")
    group.add_argument("--org", help="Org name to discover all repos")
    group.add_argument("--stdin", action="store_true", help="Read repos from stdin")
    args = parser.parse_args()

    repos = fetch_repos(org=args.org, repos=args.repos, stdin=args.stdin)
    if not repos:
        print("No repos to scan.", file=sys.stderr)
        sys.exit(1)

    now = datetime.now(timezone.utc)
    results = {}

    for repo in repos:
        try:
            r = subprocess.run(
                ["gh", "pr", "list", "--repo", repo, "--state", "open",
                 "--json", "number,title,author,createdAt,isDraft,comments,url"],
                capture_output=True, text=True, check=True, timeout=30
            )
            prs = json.loads(r.stdout)
        except (subprocess.CalledProcessError, json.JSONDecodeError, subprocess.TimeoutExpired) as e:
            print(f"Error fetching {repo}: {e}", file=sys.stderr)
            continue

        if not prs:
            continue

        repo_name = repo.split("/")[1]
        entries = []
        for pr in prs:
            created = datetime.fromisoformat(pr["createdAt"].replace("Z", "+00:00"))
            age = floor((now - created).total_seconds() / 86400)
            total_comments = len(pr["comments"])
            unres = f"~{total_comments}"  # no resolved flag in gh pr list JSON
            draft = " **[DRAFT]**" if pr["isDraft"] else ""
            entries.append((age, (
                f"- [#{pr['number']}]({pr['url']}) "
                f"({pr['author']['login']}){draft} - {age}d / {unres} unres / "
                f"{total_comments} total — {pr['title']}"
            )))

        entries.sort(key=lambda x: -x[0])  # oldest first
        results[repo_name] = [e[1] for e in entries]

    for repo_name in sorted(results.keys()):
        print(f"**{repo_name}**")
        for line in results[repo_name]:
            print(line)
        print()

    total_prs = sum(len(v) for v in results.values())
    print(f"Total: {total_prs} open PRs across {len(results)} repos")

if __name__ == "__main__":
    main()
```

## Pitfalls

1. **`gh pr list --json comments` lacks resolved flags.** The `comments` array has no `isResolved`, `isMinimized`, or `isOutdated` field. Always prefix unres counts with `~` to indicate approximation.
2. **Rate limiting:** Authenticated `gh` gets 5,000 req/hr. For 200+ repos, insert a small delay (`sleep 0.5`) between queries.
3. **Draft PRs:** Included automatically by `--state open`. No extra flag needed.
4. **Empty repos:** Return `[]` from `gh pr list`. Check and skip — don't print the heading.
5. **`gh` not installed:** Fall back to `curl` + GitHub REST API (see `github-pr-workflow` skill). Endpoint: `GET /repos/{owner}/{repo}/pulls?state=open`.
6. **Timeouts on large repos:** If a `gh pr list` call hangs (many PRs), add `--limit 100` to cap results.