---
name: discord-file-delivery
description: "Use when sending files, images, or audio to a Discord channel via the Hermes gateway — covers MEDIA: syntax, path quoting, extension allowlist, permissions, and troubleshooting."
version: 1.0.0
author: Hermes Agent (Arthur)
license: MIT
metadata:
  hermes:
    tags: [discord, files, media, delivery, gateway]
    related_skills: []
---

# Discord File Delivery via MEDIA: Tags

## Overview

The Hermes Discord gateway can send native file attachments by recognizing `MEDIA:` tags in the agent's response text. When the gateway sees `MEDIA:/path/to/file`, it:
1. Strips the tag from the visible message text
2. Validates the file path for safety
3. Sends the file as a native Discord attachment (image, document, etc.)

This works for images (`.png`, `.jpg`, `.webp`, `.gif`), documents (`.pdf`, `.txt`, `.csv`, `.zip`, etc.), audio files, and any other type — **including arbitrary extensions** if you quote the path.

## Syntax

There are two forms:

### Quoted (preferred — works with ANY file extension)

Wrap the path in double quotes, single quotes, or backticks:

```
MEDIA:"/absolute/path/to/file.ext"
MEDIA:'/absolute/path/to/file.anything'
MEDIA:`/absolute/path/to/file.xyz`
```

Quoted paths bypass the internal extension allowlist — **any extension works**.

### Bare / unquoted (limited to specific extensions)

```
MEDIA:/absolute/path/to/file.png
```

Bare paths are only accepted for these extensions: `png`, `jpg`, `jpeg`, `gif`, `webp`, `mp4`, `mov`, `avi`, `mkv`, `webm`, `ogg`, `opus`, `mp3`, `wav`, `m4a`, `flac`, `epub`, `pdf`, `zip`, `rar`, `7z`, `doc`, `docx`, `xls`, `xlsx`, `ppt`, `pptx`, `txt`, `csv`, `apk`, `ipa`.

### Placement

Put the `MEDIA:` tag in **plain response text** (not inside a `send_message` tool call). The platform automatically handles it:

```
Here's the file you asked for:

MEDIA:"/opt/hermes-agents/arthur/report.md"
```

## Path Requirements

For the file to be delivered:

1. **File must exist** and be a regular file
2. **Must be readable** by the gateway process — needs at least `644` permissions (`chmod 644 /path/to/file`)
3. **Parent directories** must be traversable — at least `755`
4. **Must be an absolute path** (starting with `/` or `~/`)
5. **Must not be under a denied prefix** — these are always blocked:
   - `/etc`, `/proc`, `/sys`, `/dev`, `/root`, `/boot`, `/var/log`
   - `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, `~/.netrc`
   - `~/.config/gcloud`, `~/.config/gh`
   - `$HERMES_HOME/.env`, `$HERMES_HOME/auth.json`, `$HERMES_HOME/credentials`

## Common Pitfalls

1. **File doesn't appear** — most common cause is permissions. The file or its parent directory may be `700`/`600` (owner-only). Fix: `chmod 644 /path/to/file && chmod 755 /path/to/parent`

2. **Extension not recognized** — bare `MEDIA:/path/file.md` won't match because `.md` isn't in the extension allowlist. Fix: wrap the path in quotes → `MEDIA:"/path/file.md"`

3. **Using `send_message` tool** — `MEDIA:` tags only work when placed directly in the agent's plain response text. Don't put them inside a `send_message()` tool call parameter.

4. **Relative paths** — `MEDIA:./file.png` or `MEDIA:file.png` won't work. Always use absolute paths starting with `/`.

5. **File inside skills/ directory** — Skill files are created with `600` permissions by default. Always `chmod 644` before trying to send via MEDIA.

6. **Path has spaces** — The regex may cut off at whitespace. Use quoted paths when the path contains spaces: `MEDIA:"/path/with spaces/file.pdf"`

## Quick Reference

| What you want | Syntax |
|--------------|--------|
| Any file, any ext | `MEDIA:"/path/to/file.ext"` |
| Image (png/jpg/gif/webp) | `MEDIA:/path/to/image.png` |
| PDF document | `MEDIA:/path/to/doc.pdf` |
| Text file | `MEDIA:/path/to/notes.txt` |
| ZIP archive | `MEDIA:/path/to/archive.zip` |
| Markdown file | `MEDIA:"/path/to/doc.md"` |
| Audio file | `MEDIA:/path/to/audio.mp3` |
| Fix permissions first | `chmod 644 /path && chmod 755 /path/to` |

## Verification

Check the gateway log if a file doesn't appear:
```bash
grep -i "media\|path\|unsafe\|skipping" $HERMES_HOME/logs/gateway.log | tail -10
```

Common log messages:
- `"Skipping unsafe MEDIA directive path outside allowed roots"` — file is under a denied prefix
- `"Failed to send document"` — file not found or permission denied
- No log entry at all — the MEDIA tag wasn't parsed (check syntax and extension allowlist)
