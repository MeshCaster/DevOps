#!/usr/bin/env bash
#
# deploy-common-infra.sh — bring up the shared Postgres/RabbitMQ/Redis stack on a
# remote host over SSH, with freshly generated credentials that are printed to
# YOU exactly once. Nothing is written to the remote: no .env, no compose file.
#
# How it works: secrets are generated locally, then a single script is streamed
# to `ssh <host> bash -s`. That script exports the secrets and pipes the compose
# file into `docker compose -f -` (stdin), so no files touch the server's disk
# and the secrets never appear in the remote process list or shell history.
#
# The compose file is read from applications/infrastructure/common by default.
#
# Usage:
#   ./deploy-common-infra.sh [options] <user@host>
#
#   -p <port>         SSH port (default: 22).
#   -i <identity>     SSH private key file (e.g. ~/.ssh/meshcaster_contabo).
#   --network <name>  Docker network to create/attach (default: meshcaster).
#   --pg-user <u>     Postgres username (default: postgres).
#   --mq-user <u>     RabbitMQ username (default: rabbit).
#   --length <n>      Generated password length (default: 32).
#   --compose <path>  Path to the compose file (default: repo common stack).
#   --dry-run         Print the remote script instead of running it (secrets are
#                     still generated so you can see the full plan).
#   -h, --help        Show this help.
#
# Examples:
#   ./deploy-common-infra.sh -i ~/.ssh/meshcaster_contabo root@contabo-host
#   ./deploy-common-infra.sh -p 2222 deploy@vps1 --network meshcaster
#   ./deploy-common-infra.sh --dry-run root@contabo-host
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
NETWORK="meshcaster"
PG_USER="postgres"
MQ_USER="rabbit"
PW_LEN=32
DRY_RUN=0
PROJECT="meshcaster-common-infra"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../../applications/infrastructure/common/docker-compose.yml"

TARGET=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --network) NETWORK="${2:?--network needs a value}"; shift 2 ;;
    --pg-user) PG_USER="${2:?--pg-user needs a value}"; shift 2 ;;
    --mq-user) MQ_USER="${2:?--mq-user needs a value}"; shift 2 ;;
    --length)  PW_LEN="${2:?--length needs a value}"; shift 2 ;;
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

command -v openssl >/dev/null 2>&1 || die "openssl is required to generate secrets"

# Alphanumeric-only secrets: safe to single-quote and to embed in a URL / conn
# string. Finite openssl source avoids SIGPIPE from a truncated /dev/urandom pipe.
gen_secret() {
  local s
  s="$(openssl rand -base64 $((PW_LEN * 2)) | LC_ALL=C tr -dc 'A-Za-z0-9')"
  printf '%s' "${s:0:$PW_LEN}"
}

log "Generating credentials locally"
PG_PASS="$(gen_secret)"
MQ_PASS="$(gen_secret)"
REDIS_PASS="$(gen_secret)"

COMPOSE_CONTENT="$(cat "$COMPOSE_FILE")"

# The remote script: export secrets, ensure the network, and feed the compose
# file to `docker compose -f -` via a quoted heredoc (so the remote shell does
# NOT expand compose's own ${...}/$$ — those are resolved by compose itself).
REMOTE_SCRIPT="$(cat <<EOF
set -euo pipefail
command -v docker >/dev/null 2>&1 || { echo 'error: docker not found on remote' >&2; exit 1; }
export POSTGRES_USER='${PG_USER}'
export POSTGRES_PASSWORD='${PG_PASS}'
export RABBITMQ_DEFAULT_USER='${MQ_USER}'
export RABBITMQ_DEFAULT_PASS='${MQ_PASS}'
export REDIS_PASSWORD='${REDIS_PASS}'
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
else
  log "Deploying common infra to $TARGET (network: $NETWORK)"
  ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' <<<"$REMOTE_SCRIPT"
fi

# ---- Print credentials ONCE. Save these now; they are not stored anywhere. ----
cat >&2 <<BANNER

======================================================================
  meshcaster common infrastructure — SAVE THESE CREDENTIALS NOW
  (shown once, not written to disk locally or on the server)
======================================================================
  Host          : ${TARGET#*@}

  Postgres
    host/port   : meshcaster-postgres:5432   (5432 published on the host)
    username    : ${PG_USER}
    password    : ${PG_PASS}

  RabbitMQ
    amqp        : meshcaster-rabbitmq:5672    (mgmt UI on 15672)
    username    : ${MQ_USER}
    password    : ${MQ_PASS}

  Redis
    host/port   : meshcaster-redis:6379
    password    : ${REDIS_PASS}
======================================================================
  Wire these into each app (e.g. Cafe's connection string / GitHub
  secrets). Postgres/RabbitMQ set the password on FIRST init only — if
  a volume already exists, re-running won't change the password.
======================================================================

BANNER
