#!/usr/bin/env bash
#
# sync-dirs.sh — copy directories from one server to another with rsync over SSH.
#
# Built for migrating upload folders (e.g. Hostinger -> CONTABO): it's resumable,
# transfers only what's missing/changed, and preserves timestamps so a re-run is
# cheap. Additive by default — it never deletes anything on the destination
# unless you pass --delete.
#
# Two modes:
#   --mode direct  (default)  rsync runs ON the destination and pulls straight
#                             from the source. Efficient (data goes server->
#                             server, never through your laptop) but needs SSH
#                             agent forwarding so the destination can reach the
#                             source with YOUR key:  ssh-add <key>  first.
#   --mode relay              rsync source -> a temp dir on your laptop -> dest.
#                             Slower / uses laptop disk+bandwidth, but only needs
#                             laptop->each-server access (no server-to-server
#                             trust). Good fallback when agent forwarding isn't
#                             set up.
#
# Usage:
#   ./sync-dirs.sh --from <user@src> --to <user@dst> [options] [PATH...]
#
#   --from <user@host>   Source server (required).
#   --to <user@host>     Destination server (required).
#   --mode direct|relay  Transfer strategy (default: direct).
#   --src-port <n>       SSH port on the source (default: 22).
#   --dst-port <n>       SSH port on the destination (default: 22).
#   -i <identity>        SSH key for the laptop->server connection(s).
#   --delete             Mirror: delete dest files not present on the source.
#   --dry-run            Show what rsync would transfer, change nothing.
#   -h, --help           Show this help.
#
#   PATH...  Absolute directories to copy (same path on both servers).
#            Default: /var/www/20kvadrati/uploads /var/www/20kvadrati/staging-uploads
#
# Examples:
#   ssh-add ~/.ssh/meshcaster_contabo               # load key into the agent
#   ./sync-dirs.sh --from root@srv1064045 --to root@contabo-host --dry-run
#   ./sync-dirs.sh --from root@srv1064045 --to root@contabo-host
#   ./sync-dirs.sh --from root@srv1064045 --to root@contabo-host --mode relay \
#       -i ~/.ssh/meshcaster_contabo /var/www/20kvadrati/uploads
#
set -euo pipefail

FROM=""
TO=""
MODE="direct"
SRC_PORT=22
DST_PORT=22
IDENTITY=""
DELETE=0
DRY_RUN=0

DEFAULT_PATHS=(/var/www/20kvadrati/uploads /var/www/20kvadrati/staging-uploads)
PATHS=()

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:?--from needs a value}"; shift 2 ;;
    --to)   TO="${2:?--to needs a value}"; shift 2 ;;
    --mode) MODE="${2:?--mode needs a value}"; shift 2 ;;
    --src-port) SRC_PORT="${2:?--src-port needs a value}"; shift 2 ;;
    --dst-port) DST_PORT="${2:?--dst-port needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --delete) DELETE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  PATHS+=("$1"); shift ;;
  esac
done

[[ -n "$FROM" ]] || die "missing --from <user@host>"
[[ -n "$TO" ]]   || die "missing --to <user@host>"
[[ "$MODE" == direct || "$MODE" == relay ]] || die "--mode must be 'direct' or 'relay'"
[[ ${#PATHS[@]} -gt 0 ]] || PATHS=("${DEFAULT_PATHS[@]}")

# Shared rsync flags: archive, hardlinks, human progress, resume partials.
RSYNC_FLAGS=(-aH --partial --info=progress2)
[[ $DELETE -eq 1 ]]  && RSYNC_FLAGS+=(--delete)
[[ $DRY_RUN -eq 1 ]] && RSYNC_FLAGS+=(-n)

log "Mode: $MODE   From: $FROM   To: $TO"
log "Directories:"; for p in "${PATHS[@]}"; do printf '    %s\n' "$p" >&2; done
[[ $DRY_RUN -eq 1 ]] && warn "dry run — no files will be written"
[[ $DELETE -eq 1 ]]  && warn "--delete enabled — dest files missing from source WILL be removed"

run_direct() {
  # rsync runs on the destination, pulling from the source over agent-forwarded SSH.
  local paths_quoted="" p
  for p in "${PATHS[@]}"; do paths_quoted+=" '${p}'"; done

  local remote_script
  remote_script="$(cat <<EOF
set -euo pipefail
command -v rsync >/dev/null 2>&1 || { echo 'error: rsync not installed on destination' >&2; exit 1; }
for p in ${paths_quoted}; do
  mkdir -p "\$(dirname "\$p")"
  echo "==> \$p"
  rsync ${RSYNC_FLAGS[*]} \
    -e "ssh -p ${SRC_PORT} -o StrictHostKeyChecking=accept-new" \
    "${FROM}:\$p/" "\$p/"
done
EOF
)"

  local ssh_opts=(-A -p "$DST_PORT")
  [[ -n "$IDENTITY" ]] && ssh_opts+=(-i "$IDENTITY")
  ssh "${ssh_opts[@]}" "$TO" 'bash -s' <<<"$remote_script"
}

run_relay() {
  # source -> temp dir on this laptop -> destination.
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  local src_e=(-e "ssh -p ${SRC_PORT}")
  local dst_e=(-e "ssh -p ${DST_PORT}")
  if [[ -n "$IDENTITY" ]]; then
    src_e=(-e "ssh -p ${SRC_PORT} -i ${IDENTITY}")
    dst_e=(-e "ssh -p ${DST_PORT} -i ${IDENTITY}")
  fi

  local i=0 p stage
  for p in "${PATHS[@]}"; do
    stage="${tmp}/dir_${i}"; i=$((i + 1))
    mkdir -p "$stage"
    log "Pulling ${FROM}:${p}"
    rsync "${RSYNC_FLAGS[@]}" "${src_e[@]}" "${FROM}:${p}/" "${stage}/"
    log "Pushing to ${TO}:${p}"
    ssh ${IDENTITY:+-i "$IDENTITY"} -p "$DST_PORT" "$TO" "mkdir -p '$(dirname "$p")'"
    rsync "${RSYNC_FLAGS[@]}" "${dst_e[@]}" "${stage}/" "${TO}:${p}/"
  done
}

if [[ "$MODE" == direct ]]; then run_direct; else run_relay; fi

log "Done."
