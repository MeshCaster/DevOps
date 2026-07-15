#!/usr/bin/env bash
#
# tunnel.sh — open an SSH tunnel to the common-infra services on a remote host,
# so you can reach them from localhost with psql / redis-cli / a GUI client
# without exposing any port to the internet.
#
# It forwards the remote host's published ports (127.0.0.1 on the remote) to
# local ports on your laptop over SSH. Leave it running; Ctrl-C to close.
#
# Local ports (override a single service with --local-port):
#   postgres      -> localhost:15432   (remote 5432)
#   redis         -> localhost:16379   (remote 6379)
#   rabbitmq      -> localhost:15672   (remote 5672,  AMQP)
#   rabbitmq-ui   -> localhost:15673   (remote 15672, management UI)
#
# Usage:
#   ./tunnel.sh [options] <user@host>
#
#   -p <port>          SSH port (default: 22).
#   -i <identity>      SSH private key (e.g. ~/.ssh/meshcaster_contabo).
#   --service <svc>    postgres | redis | rabbitmq | rabbitmq-ui | all
#                      (repeatable; default: postgres).
#   --local-port <n>   Override the local port (only with a single --service).
#   -h, --help         Show this help.
#
# Examples:
#   ./tunnel.sh -i ~/.ssh/meshcaster_contabo root@contabo-host
#   ./tunnel.sh --service all root@contabo-host
#   ./tunnel.sh --service postgres --local-port 5433 deploy@vps1
#
#   # then, in another terminal:
#   psql "host=localhost port=15432 user=postgres dbname=streetfood"
#   redis-cli -h localhost -p 16379 -a <redis-password> ping
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
LOCAL_PORT_OVERRIDE=""
SERVICES=()
TARGET=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# service -> "remote_port:default_local_port"
svc_map() {
  case "$1" in
    postgres)    echo "5432:15432" ;;
    redis)       echo "6379:16379" ;;
    rabbitmq)    echo "5672:15672" ;;
    rabbitmq-ui) echo "15672:15673" ;;
    *) die "unknown service: $1 (postgres|redis|rabbitmq|rabbitmq-ui|all)" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --service) SERVICES+=("${2:?--service needs a value}"); shift 2 ;;
    --local-port) LOCAL_PORT_OVERRIDE="${2:?--local-port needs a value}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[[ -n "$TARGET" ]] || die "no target host given (e.g. user@host); try --help"
[[ ${#SERVICES[@]} -gt 0 ]] || SERVICES=(postgres)

# Expand "all"
if printf '%s\n' "${SERVICES[@]}" | grep -qx all; then
  SERVICES=(postgres redis rabbitmq rabbitmq-ui)
fi

if [[ -n "$LOCAL_PORT_OVERRIDE" && ${#SERVICES[@]} -ne 1 ]]; then
  die "--local-port can only be used with a single --service"
fi

FORWARDS=()
log "Tunnel plan (remote 127.0.0.1 -> your localhost):"
for svc in "${SERVICES[@]}"; do
  mapping="$(svc_map "$svc")"
  remote_port="${mapping%%:*}"
  local_port="${mapping##*:}"
  [[ -n "$LOCAL_PORT_OVERRIDE" ]] && local_port="$LOCAL_PORT_OVERRIDE"
  FORWARDS+=(-L "127.0.0.1:${local_port}:127.0.0.1:${remote_port}")
  printf '    %-12s localhost:%s -> remote:%s\n' "$svc" "$local_port" "$remote_port" >&2
done

SSH_OPTS=(-p "$SSH_PORT" -N)
[[ -n "$IDENTITY" ]] && SSH_OPTS+=(-i "$IDENTITY")

log "Opening tunnel to $TARGET — press Ctrl-C to close"
exec ssh "${SSH_OPTS[@]}" "${FORWARDS[@]}" "$TARGET"
