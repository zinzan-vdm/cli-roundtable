---
name: gh-pr-review
description: "Two-phase PR review workflow: assess all findings, present as a list, then post approved comments inline on GitHub."
version: 1.0.0
author: Arthur
platforms: [linux, macos]
metadata:
  hermes:
    tags: [GitHub, Pull-Requests, Code-Review, Workflow]
    related_skills: [github-code-review, gh-pr-report, github-auth, github-pr-workflow]
---

# GitHub PR Review Process

Two-phase process: you fully assess the PR first, present all findings to the user, then post only what they approve.

## Prerequisites

- `gh` CLI installed and authenticated (see `github-auth` skill)
- Repo cloned locally and checked out on the PR branch
- Project conventions / guidelines file available (e.g. GUIDELINES.md)

## Workflow

### Phase 1 - Assess

1. **Study the code**
   - Clone the repo if not already present
   - Check out the PR branch (`gh pr checkout <number>`)
   - Read the PR metadata: body, changed files, additions/deletions, existing comments
   - Read route handlers, schemas, tests, and config files
   - Check existing comments including outdated/resolved ones - if any issues are still relevant, suggest leaving them again

2. **Analyse against conventions**
   - Load any project GUIDELINES.md or coding standards
   - Check for: naming conventions, error handling patterns, test quality, schema consistency, dead code, unused dependencies, status code correctness

3. **Fully assess the PR**
   - Compile ALL findings into a list
   - Each finding should include surrounding code context (inline diffs work well)

### Phase 2 - Propose

Present findings to the user as a lettered list:

```
A. `path/to/file.ts` line N - [short title]
\`\`\`typescript
// surrounding code for context
const problem = here;  // what's wrong
\`\`\`
Brief explanation.
```

The user will approve, reject, or suggest modifications for each.

### Phase 3 - Post

For each approved or modified comment, post it as an inline PR review comment:

```bash
gh api "repos/{org}/{repo}/pulls/{number}/comments" --method POST \
  --field body='Concise comment text.' \
  --field commit_id='<latest-commit-sha>' \
  --field path='path/to/file.ts' \
  --field line=<line-number> \
  --field side='RIGHT'
```

Get the latest commit SHA with:
```bash
gh pr view <number> --json commits --jq '.commits[-1].oid'
```

## Comment Style

- Keep comments concise, simple, and to the point
- Assume the reader understands technical concepts - no over-explaining
- Avoid '--' (use '-' instead)
- Say what's wrong and how to fix it (when you have a recommendation)
- For test/handler inconsistencies, ask "how are these passing?" as a question
- For typos/naming issues, ask "what should this be?" as a question

## Pitfalls

1. **Wrong commit SHA** - Each PR has its own head commit. Always fetch it fresh with `gh pr view`.
2. **Line numbers** - For new files, line numbers in the file may differ from the diff position. Verify with `grep -n` on the actual file if the API rejects the line.
3. **Path resolution** - GitHub API requires the exact path from the repo root. Use `git diff main...HEAD --name-only` to verify.
4. **Draft PRs** - Focus on high-level structure and design guidance, not nitpicky line-level issues. Code may still change significantly.
5. **Existing comments** - Always check for existing comments on the PR (including outdated/resolved). Don't duplicate feedback that's already been addressed.
