# Directory Transfer Tool

`sync-dirs.sh` copies directories from one server to another with **rsync over
SSH** — built for migrating upload folders (e.g. **Hostinger → CONTABO**).

Why rsync (not `scp`/`tar`):

- **Resumable & incremental** — only transfers what's missing or changed, so a
  re-run after a dropped connection is cheap.
- **Timestamp-preserving** — retries don't re-copy files that already made it.
- **Additive by default** — never deletes anything on the destination unless you
  pass `--delete`.

## Modes

| Mode | Data path | Needs |
|------|-----------|-------|
| `direct` (default) | source → destination (never touches your laptop) | SSH **agent forwarding** so the destination can reach the source with your key |
| `relay` | source → laptop temp dir → destination | only laptop→each-server access (no server-to-server trust) |

`direct` is faster and uses no laptop bandwidth/disk; `relay` is the fallback
when you can't set up agent forwarding.

## Usage

```bash
# Load your key into the SSH agent (required for direct mode)
ssh-add ~/.ssh/meshcaster_contabo

# Preview first — shows what would transfer, changes nothing
tools/transfer/sync-dirs.sh --from root@srv1064045 --to root@contabo-host --dry-run

# Real run (default dirs: uploads + staging-uploads)
tools/transfer/sync-dirs.sh --from root@srv1064045 --to root@contabo-host

# Relay mode with an explicit key, one specific directory
tools/transfer/sync-dirs.sh --from root@srv1064045 --to root@contabo-host \
  --mode relay -i ~/.ssh/meshcaster_contabo /var/www/20kvadrati/uploads
```

| Flag | Description |
|------|-------------|
| `--from <user@host>` | Source server (required). |
| `--to <user@host>` | Destination server (required). |
| `--mode direct\|relay` | Transfer strategy (default: `direct`). |
| `--src-port <n>` / `--dst-port <n>` | SSH ports (default: `22`). |
| `-i <identity>` | SSH key for the laptop→server connection(s). |
| `--delete` | Mirror: delete dest files not present on the source. |
| `--dry-run` | Show what would transfer, change nothing. |
| `PATH...` | Absolute dirs to copy (same path on both). Default: `uploads` + `staging-uploads` under `/var/www/20kvadrati`. |

## Requirements

- `rsync` installed on **both** servers (`apt install rsync` / `dnf install rsync`).
- SSH access from your laptop to both servers (use your keys from
  [`tools/ssh-keys`](../ssh-keys/README.md)).
- For `direct` mode: `ssh-add` your key first, so it's forwarded to the
  destination to authenticate onward to the source. The source's host key is
  auto-accepted on first connect (`StrictHostKeyChecking=accept-new`).

## Fits the migration

These are the same folders the deploy workflow bind-mounts into the app
containers (`/var/www/20kvadrati/uploads`, `.../staging-uploads`). Sync them to
CONTABO **before** cutting the app over, then re-run right before DNS switch to
catch any last-minute uploads — the incremental copy makes the second pass fast.
