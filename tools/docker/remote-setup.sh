#!/usr/bin/env bash
#
# remote-setup.sh — run setup-docker.sh on a remote host over SSH, with no git,
# no download, and no leftover files on the remote.
#
# It streams the local setup-docker.sh into the remote shell (`ssh host bash -s`),
# so the target VPS needs nothing but SSH access and a sudo-capable user.
#
# Usage:
#   ./remote-setup.sh [-p <ssh-port>] [-i <identity>] <user@host> [-- <setup-docker args>]
#
#   -p <port>      SSH port (default: 22).
#   -i <identity>  SSH private key file (passed to ssh -i).
#   -h, --help     Show this help.
#
#   Everything after `--` is forwarded verbatim to setup-docker.sh on the remote,
#   e.g. --dry-run, --user <name>, --no-usermod.
#
# Examples:
#   ./remote-setup.sh root@vps1 -- --dry-run
#   ./remote-setup.sh -p 2222 -i ~/.ssh/vps1 deploy@vps1 -- --user deploy
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SCRIPT="${SCRIPT_DIR}/setup-docker.sh"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Parse our own flags up to the target; stop at the first non-flag (the host).
REMOTE_ARGS=()
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    -h|--help) usage 0 ;;
    --) shift; REMOTE_ARGS=("$@"); break ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[[ -n "$TARGET" ]]         || die "no target host given (e.g. user@host); try --help"
[[ -r "$LOCAL_SCRIPT" ]]   || die "cannot read $LOCAL_SCRIPT"
[[ "$TARGET" == *@* ]]     || printf '\033[1;33mwarn:\033[0m target has no user@ prefix; using SSH default user\n' >&2

SSH_OPTS=(-p "$SSH_PORT")
[[ -n "$IDENTITY" ]] && SSH_OPTS+=(-i "$IDENTITY")

printf '\033[1;34m==>\033[0m Streaming setup-docker.sh to %s (port %s)\n' "$TARGET" "$SSH_PORT"
if [[ ${#REMOTE_ARGS[@]} -gt 0 ]]; then
  printf '\033[1;34m==>\033[0m Remote args: %s\n' "${REMOTE_ARGS[*]}"
fi

# -s reads the script from stdin; args after `--` are $1.. inside setup-docker.sh.
# ${arr[@]+...} guards against macOS bash 3.2 treating an empty array as unbound.
exec ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s --' ${REMOTE_ARGS[@]+"${REMOTE_ARGS[@]}"} < "$LOCAL_SCRIPT"
