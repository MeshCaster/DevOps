#!/usr/bin/env bash
#
# deploy-vault.sh — bring up HashiCorp Vault on a remote host over SSH.
#
# Like deploy-common-infra.sh, the compose file is streamed to `ssh <host> bash -s`
# and piped into `docker compose -f -` (stdin), so no compose file lands on the
# server. Vault's whole configuration rides along inside the compose file itself
# (VAULT_LOCAL_CONFIG), so there is nothing else to copy.
#
# This script is idempotent and holds no secrets — it only starts the server.
# Vault comes up SEALED and uninitialized; run init-vault.sh next, exactly once.
#
# Usage:
#   ./deploy-vault.sh [options] <user@host>
#
#   -p <port>         SSH port (default: 22).
#   -i <identity>     SSH private key file (e.g. ~/.ssh/meshcaster_contabo).
#   --network <name>  Docker network to create/attach (default: meshcaster).
#   --compose <path>  Path to the compose file (default: repo vault stack).
#   --dry-run         Print the remote script instead of running it.
#   -h, --help        Show this help.
#
# Examples:
#   ./deploy-vault.sh -i ~/.ssh/meshcaster_contabo root@contabo-host
#   ./deploy-vault.sh --dry-run root@contabo-host
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
NETWORK="meshcaster"
DRY_RUN=0
PROJECT="meshcaster-vault"

# Must match the unsealer's bind mount in the compose file.
KEY_DIR="/etc/meshcaster/vault"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../../applications/infrastructure/vault/docker-compose.yml"

TARGET=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --network) NETWORK="${2:?--network needs a value}"; shift 2 ;;
    --compose) COMPOSE_FILE="${2:?--compose needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[[ -n "$TARGET" ]]       || die "no target host given (e.g. user@host); try --help"
[[ -r "$COMPOSE_FILE" ]] || die "cannot read compose file: $COMPOSE_FILE"
[[ "$TARGET" == *@* ]]   || warn "target has no user@ prefix; using SSH default user"

COMPOSE_CONTENT="$(cat "$COMPOSE_FILE")"

# The key directory must exist BEFORE compose runs: the unsealer bind-mounts it,
# and Docker would otherwise create it root-owned with the wrong mode (or, if we
# mounted the file directly, invent a directory named `keys`).
REMOTE_SCRIPT="$(cat <<EOF
set -euo pipefail
command -v docker >/dev/null 2>&1 || { echo 'error: docker not found on remote' >&2; exit 1; }

SUDO=""
[ "\$(id -u)" -ne 0 ] && SUDO="sudo"
\$SUDO install -d -m 700 '${KEY_DIR}'

docker network inspect '${NETWORK}' >/dev/null 2>&1 || docker network create '${NETWORK}'
docker compose -p '${PROJECT}' -f - up -d <<'COMPOSE_EOF'
${COMPOSE_CONTENT}
COMPOSE_EOF
docker compose -p '${PROJECT}' ps
EOF
)"

SSH_OPTS=(-p "$SSH_PORT")
[[ -n "$IDENTITY" ]] && SSH_OPTS+=(-i "$IDENTITY")

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry run — remote script that WOULD be executed on $TARGET:"
  printf '%s\n' "$REMOTE_SCRIPT"
  exit 0
fi

log "Deploying Vault to $TARGET (network: $NETWORK)"
ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' <<<"$REMOTE_SCRIPT"

cat >&2 <<BANNER

======================================================================
  Vault is running on ${TARGET#*@} — and it is SEALED.
======================================================================
  A sealed Vault answers no requests. That is expected: it holds no
  data yet and has no keys.

  Next, exactly once per server:

      tools/vault/init-vault.sh ${IDENTITY:+-i $IDENTITY }${TARGET}

  That prints the unseal keys and root token ONE time, and installs the
  keys the unsealer sidecar needs to bring Vault back after a reboot.
======================================================================

BANNER
