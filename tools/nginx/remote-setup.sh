#!/usr/bin/env bash
#
# remote-setup.sh — set up the containerized nginx stack on a REMOTE host over
# SSH, and (optionally) deploy a hand-written vhost + issue its certificates —
# all from your laptop, nothing to run on the server by hand.
#
# It streams init-nginx.sh into the remote shell (like tools/docker/remote-setup.sh),
# so the target needs only SSH access + Docker. Then, if you pass --conf/--cert,
# it obtains the certs via the certbot container, copies the vhost into conf.d,
# validates, and reloads nginx.
#
# Order matters and is handled for you: bootstrap → certs (served by the default
# ACME vhost) → drop the real vhost (which references those certs) → reload.
#
# Usage:
#   ./remote-setup.sh [options] <user@host>
#
#   -p <port>          SSH port (default: 22).
#   -i <identity>      SSH private key (e.g. ~/.ssh/meshcaster_contabo).
#   --base <dir>       Stack base dir on the remote (default: /opt/nginx).
#   --network <name>   External Docker network (default: meshcaster).
#   --mount <H:C[:ro]> Extra bind mount for nginx (repeatable), e.g. uploads:
#                      --mount /var/www/20kvadrati/uploads:/var/www/20kvadrati/uploads:ro
#   --conf <file>      Local vhost file to install into <base>/nginx/conf.d/.
#   --email <addr>     ACME email (required if --cert is used).
#   --cert "<d1 d2>"   Domains for ONE certificate (repeatable for multiple certs).
#   --staging          Use Let's Encrypt staging (testing; avoids rate limits).
#   --skip-init        Don't re-bootstrap; only certs/conf/reload.
#   --dry-run          Print what would run remotely; change nothing.
#   -h, --help         Show help.
#
# Examples:
#   # Full 20kvadrati setup: bootstrap + uploads mount + 3 certs + vhost
#   ./remote-setup.sh -i ~/.ssh/meshcaster_contabo root@169.58.24.221 \
#     --mount /var/www/20kvadrati/uploads:/var/www/20kvadrati/uploads:ro \
#     --email you@20kvadrati.com \
#     --cert "20kvadrati.com www.20kvadrati.com prodapi.20kvadrati.com prodadmin.20kvadrati.com" \
#     --cert "admin.20kvadrati.com stagingadmin.20kvadrati.com" \
#     --cert "stagingapi.20kvadrati.com" \
#     --conf ./20kvadrati.conf
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
BASE="/opt/nginx"
NETWORK="meshcaster"
MOUNTS=()
CONF=""
EMAIL=""
CERTS=()
STAGING=""
SKIP_INIT=0
DRY_RUN=0
TARGET=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="${SCRIPT_DIR}/init-nginx.sh"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --base)      BASE="${2:?--base needs a value}"; shift 2 ;;
    --network)   NETWORK="${2:?--network needs a value}"; shift 2 ;;
    --mount)     MOUNTS+=("${2:?--mount needs a value}"); shift 2 ;;
    --conf)      CONF="${2:?--conf needs a value}"; shift 2 ;;
    --email)     EMAIL="${2:?--email needs a value}"; shift 2 ;;
    --cert)      CERTS+=("${2:?--cert needs a value}"); shift 2 ;;
    --staging)   STAGING="--staging"; shift ;;
    --skip-init) SKIP_INIT=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  [[ -z "$TARGET" ]] || die "unexpected extra argument '$1' (already have host '$TARGET') — a flag likely swallowed its value; check for a stray --cert/--conf"
        TARGET="$1"; shift ;;
  esac
done

# Catch a flag that ate the next flag as its value (e.g. "--cert --conf ...").
for _v in "$EMAIL" "$CONF" ${CERTS[@]+"${CERTS[@]}"} ${MOUNTS[@]+"${MOUNTS[@]}"}; do
  [[ "$_v" == --* ]] && die "option value '$_v' looks like a flag — a preceding option is missing its value"
done

[[ -n "$TARGET" ]] || die "no target host given (e.g. user@host); try --help"
[[ $SKIP_INIT -eq 1 || -r "$INIT" ]] || die "cannot read $INIT"
[[ -z "$CONF" || -r "$CONF" ]] || die "cannot read --conf file: $CONF"
[[ ${#CERTS[@]} -eq 0 || -n "$EMAIL" ]] || die "--cert requires --email"

SSH_OPTS=(-p "$SSH_PORT")
[[ -n "$IDENTITY" ]] && SSH_OPTS+=(-i "$IDENTITY")
remote() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

DC="docker compose --project-directory '$BASE' -f '$BASE/docker-compose.yml'"

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry run — planned remote actions on $TARGET:"
  [[ $SKIP_INIT -eq 0 ]] && printf '  1. stream init-nginx.sh (base=%s network=%s mounts=%s)\n' "$BASE" "$NETWORK" "${MOUNTS[*]:-none}" >&2
  i=2
  for g in ${CERTS[@]+"${CERTS[@]}"}; do printf '  %s. certbot certonly for: %s\n' "$i" "$g" >&2; i=$((i+1)); done
  [[ -n "$CONF" ]] && { printf '  %s. install %s -> %s/nginx/conf.d/\n' "$i" "$(basename "$CONF")" "$BASE" >&2; i=$((i+1)); }
  printf '  %s. nginx -t && reload\n' "$i" >&2
  exit 0
fi

# 1. Bootstrap / update the stack (idempotent).
if [[ $SKIP_INIT -eq 0 ]]; then
  log "Bootstrapping nginx stack on $TARGET (base=$BASE, network=$NETWORK)"
  init_args=(--base "$BASE" --network "$NETWORK")
  for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do init_args+=(--mount "$m"); done
  ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s --' "${init_args[@]}" < "$INIT"
fi

# 2. Obtain certificates (ACME http-01 is served by the default vhost from init).
for group in ${CERTS[@]+"${CERTS[@]}"}; do
  dargs=""; for d in $group; do dargs+=" -d $d"; done
  log "Requesting certificate for: $group ${STAGING:+(staging)}"
  remote "$DC run --rm certbot certonly --webroot -w /var/www/certbot \
    --email '$EMAIL' --agree-tos --no-eff-email --keep-until-expiring $STAGING$dargs" \
    || die "certbot failed for [$group] — check DNS points at this host and ports 80/443 are open"
done

# 3. Install the vhost (now that its certs exist).
if [[ -n "$CONF" ]]; then
  name="$(basename "$CONF")"
  log "Installing vhost $name into $BASE/nginx/conf.d/"
  remote "tee '$BASE/nginx/conf.d/$name' >/dev/null" < "$CONF"
fi

# 4. Validate and reload.
log "Validating and reloading nginx"
remote "docker exec nginx-proxy nginx -t && docker exec nginx-proxy nginx -s reload"

log "Done. nginx on $TARGET is serving the new config."
