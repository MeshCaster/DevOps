#!/usr/bin/env bash
#
# provision-app.sh — give one application its own identity in Vault.
#
# For an app named <app>, this creates on the remote Vault:
#   * a KV v2 path            meshcaster/<app>          (where its secrets live)
#   * a read-only policy      <app>                     (read of that one path)
#   * an AppRole role         <app>                     (bound to that policy)
# and prints the app's RoleId + a fresh SecretId ONCE. Those two go into the
# app's deploy environment (VAULT__ROLEID / VAULT__SECRETID); the app then reads
# its config from Vault at startup via MeshCaster.Configuration.Vault.
#
# It needs the Vault root token (or any token that can write policies + auth).
# Pass it in the environment as VAULT_TOKEN so it never lands in argv:
#
#   VAULT_TOKEN=<root> tools/vault/provision-app.sh -i ~/.ssh/key root@host mediathek-api
#
# Re-running is safe: the policy/role are rewritten, and --rotate issues a new
# SecretId. Existing secret values at meshcaster/<app> are left untouched unless
# you pass key=value pairs to seed.
#
# Usage:
#   VAULT_TOKEN=<token> ./provision-app.sh [options] <user@host> <app> [key=value ...]
#
#   -p <port>       SSH port (default: 22).
#   -i <identity>   SSH private key file.
#   --rotate        Issue a new SecretId even if the role already exists.
#   --ttl <dur>     Token TTL for the app's login (default: 1h).
#   --max-ttl <dur> Token max TTL (default: 24h).
#   -h, --help      Show this help.
#
# Examples:
#   VAULT_TOKEN=$ROOT ./provision-app.sh root@host mediathek-api
#   VAULT_TOKEN=$ROOT ./provision-app.sh root@host mediathek-api \
#       ConnectionStrings__MediathekDb='Host=meshcaster-postgres;...' \
#       Auth__Authority='https://identity.in-vent.online'
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
ROTATE=0
TTL="1h"
MAX_TTL="24h"
CONTAINER="meshcaster-vault"
MOUNT="meshcaster"
TARGET=""
APP=""
KV_PAIRS=()

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --rotate) ROTATE=1; shift ;;
    --ttl) TTL="${2:?--ttl needs a value}"; shift 2 ;;
    --max-ttl) MAX_TTL="${2:?--max-ttl needs a value}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"
      elif [[ -z "$APP" ]]; then APP="$1"
      else KV_PAIRS+=("$1"); fi
      shift ;;
  esac
done

[[ -n "$TARGET" ]] || die "no target host given; try --help"
[[ -n "$APP" ]]    || die "no app name given (e.g. mediathek-api); try --help"
[[ "$APP" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "app name must be lowercase alphanumeric/dashes: $APP"
[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is required in the environment (the Vault root token)"

# Validate seed pairs locally before touching the server.
for p in "${KV_PAIRS[@]:-}"; do
  [[ -z "$p" || "$p" == *=* ]] || die "seed values must be key=value, got: $p"
done

SSH_OPTS=(-p "$SSH_PORT")
[[ -n "$IDENTITY" ]] && SSH_OPTS+=(-i "$IDENTITY")

# Build the optional `vault kv put` argument list. Values ride inside the remote
# script (stdin), so they stay out of argv/ps on the server.
KV_PUT_ARGS=""
for p in "${KV_PAIRS[@]:-}"; do
  [[ -n "$p" ]] || continue
  key="${p%%=*}"; val="${p#*=}"
  KV_PUT_ARGS+=" '${key}=${val}'"
done

log "Provisioning app '$APP' in Vault on $TARGET"

# VAULT_TOKEN is passed via `docker exec -e VAULT_TOKEN` (name only), so it is
# inherited from the SSH session's environment and never appears in argv.
OUTPUT="$(ssh "${SSH_OPTS[@]}" "$TARGET" "VAULT_TOKEN='${VAULT_TOKEN}' bash -s" <<EOF
set -euo pipefail
docker inspect '${CONTAINER}' >/dev/null 2>&1 || { echo 'error: ${CONTAINER} not running' >&2; exit 1; }

run() { docker exec -e VAULT_TOKEN '${CONTAINER}' "\$@"; }

# Idempotent enables (ignore 'already enabled').
run vault secrets enable -path='${MOUNT}' kv-v2 >/dev/null 2>&1 || true
run vault auth enable approle             >/dev/null 2>&1 || true

# Read-only policy scoped to this single app path.
run vault policy write '${APP}' - >/dev/null <<POLICY
path "${MOUNT}/data/${APP}"     { capabilities = ["read"] }
path "${MOUNT}/metadata/${APP}" { capabilities = ["read", "list"] }
POLICY

# AppRole role bound to that policy. secret_id_num_uses=0 / ttl=0 => the SecretId
# does not expire and can be reused across redeploys; the short token_ttl keeps
# the blast radius of a leaked *token* small.
run vault write auth/approle/role/'${APP}' \
    token_policies='${APP}' \
    token_ttl='${TTL}' token_max_ttl='${MAX_TTL}' \
    secret_id_num_uses=0 secret_id_ttl=0 >/dev/null

# Seed config values only if some were passed.
if [ -n "${KV_PUT_ARGS}" ]; then
  run vault kv put -mount='${MOUNT}' '${APP}'${KV_PUT_ARGS} >/dev/null
  echo "seeded config at ${MOUNT}/${APP}"
fi

ROLE_ID="\$(run vault read -field=role_id auth/approle/role/'${APP}'/role-id)"

# Issue a SecretId only for a new role, or when --rotate was asked for.
HAS_SECRET=0
if run vault list auth/approle/role/'${APP}'/secret-id 2>/dev/null | grep -q .; then HAS_SECRET=1; fi
if [ "${ROTATE}" -eq 1 ] || [ "\$HAS_SECRET" -eq 0 ]; then
  SECRET_ID="\$(run vault write -f -field=secret_id auth/approle/role/'${APP}'/secret-id)"
  echo "ROLE_ID=\$ROLE_ID"
  echo "SECRET_ID=\$SECRET_ID"
else
  echo "ROLE_ID=\$ROLE_ID"
  echo "SECRET_ID="
fi
EOF
)"

echo "$OUTPUT" | grep -vE '^(ROLE_ID|SECRET_ID)=' >&2 || true

ROLE_ID="$(printf '%s\n' "$OUTPUT" | sed -n 's/^ROLE_ID=//p')"
SECRET_ID="$(printf '%s\n' "$OUTPUT" | sed -n 's/^SECRET_ID=//p')"

[[ -n "$ROLE_ID" ]] || die "provisioning failed — no RoleId returned (see errors above)"

{
  echo
  echo "======================================================================"
  echo "  App '$APP' provisioned in Vault"
  echo "======================================================================"
  echo "  Secrets path : ${MOUNT}/${APP}   (put config here)"
  echo "  Policy/role  : ${APP}            (read-only on that path)"
  echo
  echo "  VAULT__ROLEID   = ${ROLE_ID}"
  if [[ -n "$SECRET_ID" ]]; then
    echo "  VAULT__SECRETID = ${SECRET_ID}      <- SAVE NOW, shown once"
  else
    echo "  VAULT__SECRETID = (unchanged — pass --rotate to issue a new one)"
  fi
  echo
  echo "  Put these two into the app's deploy env (GitHub secrets ->"
  echo "  deploy-container.yml extra-env, or the server env-file). Add the"
  echo "  Vault address the app reaches over the meshcaster network:"
  echo "      VAULT__ADDRESS = http://meshcaster-vault:8200"
  echo
  echo "  Seed / edit this app's secrets any time:"
  echo "    VAULT_TOKEN=<root> tools/vault/provision-app.sh ${IDENTITY:+-i $IDENTITY }${TARGET} ${APP} \\"
  echo "        ConnectionStrings__MyDb='...' Some__Key='...'"
  echo "======================================================================"
  echo
} >&2
