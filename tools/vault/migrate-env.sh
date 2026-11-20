#!/usr/bin/env bash
#
# migrate-env.sh — move an app's secrets out of its host env file and into Vault.
#
# For an app named <app>, on the remote host this:
#   * makes sure the app has its Vault identity (KV path meshcaster/<app>, a read-only
#     policy and an AppRole role — the same ones provision-app.sh creates);
#   * copies every KEY=value line of /opt/meshcaster/<app>.env into meshcaster/<app>
#     (merged over what is already there, so values added in the UI survive);
#   * reads each value back, and logs in as the app to prove the AppRole can read them;
#   * only then rewrites the env file to the four VAULT__* bootstrap lines, keeping the
#     original as <file>.pre-vault.<timestamp> (mode 600) for rollback.
#
# Secret values never leave the host: they are read from the env file and piped into
# `vault` on stdin there, so nothing is printed, sent over SSH, or put in argv. Only
# key names are shown.
#
# The app must already run an image that calls AddMeshCasterVault, and needs
# redeploying afterwards: docker reads --env-file when the container is CREATED, so
# `docker restart` keeps the old environment. After that first redeploy, an edit in
# the Vault UI only needs `docker restart <container>`.
#
# Needs a token that can write policies and auth (the root token). Pass it in the
# environment as VAULT_TOKEN; it travels inside the script on stdin, never in argv.
#
# Usage:
#   VAULT_TOKEN=<token> ./migrate-env.sh [options] <user@host> <app>
#
#   -p <port>          SSH port (default: 22).
#   -i <identity>      SSH private key file.
#   --env-file <path>  Env file on the host (default: /opt/meshcaster/<app>.env).
#   --dry-run          List the keys that would move; change nothing.
#   -h, --help         Show this help.
#
# Examples:
#   VAULT_TOKEN=$ROOT ./migrate-env.sh --dry-run root@host beautybook-api
#   VAULT_TOKEN=$ROOT ./migrate-env.sh -i ~/.ssh/key root@host beautybook-api
#   VAULT_TOKEN=$ROOT ./migrate-env.sh root@host identity
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
ENV_FILE=""
DRY_RUN=0
TTL="1h"
MAX_TTL="24h"
CONTAINER="meshcaster-vault"
MOUNT="meshcaster"
VAULT_ADDRESS="http://meshcaster-vault:8200"
TARGET=""
APP=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?--env-file needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"
      elif [[ -z "$APP" ]]; then APP="$1"
      else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[[ -n "$TARGET" ]] || die "no target host given; try --help"
[[ -n "$APP" ]]    || die "no app name given (e.g. beautybook-api); try --help"
[[ "$APP" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "app name must be lowercase alphanumeric/dashes: $APP"
[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is required in the environment (the Vault root token)"
ENV_FILE="${ENV_FILE:-/opt/meshcaster/${APP}.env}"

SSH_OPTS=(-p "$SSH_PORT")
[[ -n "$IDENTITY" ]] && SSH_OPTS+=(-i "$IDENTITY")

# Parameters first (quoted for the remote shell), then the body as a quoted heredoc so
# nothing in it is expanded locally.
PARAMS="$(
  printf 'export VAULT_TOKEN=%q\n' "$VAULT_TOKEN"
  printf 'APP=%q ENV_FILE=%q DRY_RUN=%q TTL=%q MAX_TTL=%q\n' "$APP" "$ENV_FILE" "$DRY_RUN" "$TTL" "$MAX_TTL"
  printf 'CONTAINER=%q MOUNT=%q VAULT_ADDRESS=%q\n' "$CONTAINER" "$MOUNT" "$VAULT_ADDRESS"
)"

# read -d '' rather than $(cat <<...): macOS's bash 3.2 cannot parse a `case` inside $(...).
IFS= read -r -d '' BODY <<'REMOTE' || true
set -euo pipefail
die() { echo "error: $*" >&2; exit 1; }

# VAULT_TOKEN is exported above; -e passes it by name, so it is never in argv.
run() { docker exec -i -e VAULT_TOKEN "$CONTAINER" "$@"; }
# Same, as another token (the app's), for the read-back check.
run_as() { local t="$1"; shift; VAULT_TOKEN="$t" docker exec -i -e VAULT_TOKEN "$CONTAINER" "$@"; }

docker inspect "$CONTAINER" >/dev/null 2>&1 || die "$CONTAINER is not running"
run vault status >/dev/null 2>&1 || die "Vault is sealed or unreachable"
[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE"

# ---- parse the env file (docker's format: KEY=value, split on the first '=', no quoting) ----
keys=(); vals=(); old_secret_id=""; json="{"; sep=""
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  # Never echo the line itself: it holds a secret.
  [[ "$line" == *=* ]] || die "$ENV_FILE line $lineno has no '='"
  key="${line%%=*}"; val="${line#*=}"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_.:-]*$ ]] || die "$ENV_FILE line $lineno: unexpected key name"
  case "$key" in
    VAULT__SECRETID) old_secret_id="$val"; continue ;;
    VAULT__*) continue ;;
  esac
  esc="${val//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\t'/\\t}"
  json+="${sep}\"${key}\":\"${esc}\""; sep=","
  keys+=("$key"); vals+=("$val")
done < "$ENV_FILE"
json+="}"

if [ "${#keys[@]}" -eq 0 ]; then
  echo "nothing to move: $ENV_FILE has only VAULT__* lines (already migrated?)"
  exit 10
fi

echo "keys in $ENV_FILE that move to $MOUNT/$APP:"
printf '  %s\n' "${keys[@]}"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: nothing changed"
  exit 10
fi

# ---- the app's Vault identity (same shape as provision-app.sh) ----
run vault secrets enable -path="$MOUNT" kv-v2 >/dev/null 2>&1 || true
run vault auth enable approle               >/dev/null 2>&1 || true

run vault policy write "$APP" - >/dev/null <<POLICY
path "${MOUNT}/data/${APP}"     { capabilities = ["read"] }
path "${MOUNT}/metadata/${APP}" { capabilities = ["read", "list"] }
POLICY

run vault write "auth/approle/role/$APP" \
    token_policies="$APP" token_ttl="$TTL" token_max_ttl="$MAX_TTL" \
    secret_id_num_uses=0 secret_id_ttl=0 >/dev/null

# ---- write the values (JSON on stdin) ----
if run vault kv metadata get -mount="$MOUNT" "$APP" >/dev/null 2>&1; then
  printf '%s' "$json" | run vault kv patch -mount="$MOUNT" "$APP" - >/dev/null
else
  printf '%s' "$json" | run vault kv put -mount="$MOUNT" "$APP" - >/dev/null
fi

# ---- read every value back before touching the env file ----
for i in "${!keys[@]}"; do
  got="$(run vault kv get -mount="$MOUNT" -field="${keys[$i]}" "$APP")" \
    || die "could not read ${keys[$i]} back; $ENV_FILE left unchanged"
  [ "$got" = "${vals[$i]}" ] || die "${keys[$i]} did not round-trip; $ENV_FILE left unchanged"
done
echo "all ${#keys[@]} values stored and read back"

# ---- AppRole credentials: keep a SecretId the file already had, else issue one ----
role_id="$(run vault read -field=role_id "auth/approle/role/$APP/role-id")"
secret_id="$old_secret_id"
if [ -z "$secret_id" ]; then
  secret_id="$(run vault write -f -field=secret_id "auth/approle/role/$APP/secret-id")"
fi

# Log in exactly as the app will, and read one key, so a bad role or policy is caught
# here instead of as a crash loop after the redeploy.
app_token="$(printf '{"role_id":"%s","secret_id":"%s"}' "$role_id" "$secret_id" \
  | run_as "" vault write -field=token auth/approle/login - 2>/dev/null)" \
  || die "AppRole login as $APP failed; $ENV_FILE left unchanged"
run_as "$app_token" vault kv get -mount="$MOUNT" -field="${keys[0]}" "$APP" >/dev/null \
  || die "$APP's AppRole cannot read $MOUNT/$APP; $ENV_FILE left unchanged"
run_as "$app_token" vault token revoke -self >/dev/null 2>&1 || true
echo "AppRole $APP logs in and reads its secrets"

# ---- swap the env file ----
umask 077
backup="$ENV_FILE.pre-vault.$(date +%Y%m%d%H%M%S)"
cp -p "$ENV_FILE" "$backup"
tmp="$(mktemp "$ENV_FILE.XXXXXX")"
{
  echo "# Secrets for $APP live in Vault at $MOUNT/$APP (see tools/vault in MeshCaster/DevOps)."
  echo "# Edit them in the Vault UI, then: docker restart <container>."
  echo "VAULT__ADDRESS=$VAULT_ADDRESS"
  echo "VAULT__SECRETPATH=$APP"
  echo "VAULT__ROLEID=$role_id"
  echo "VAULT__SECRETID=$secret_id"
} > "$tmp"
chmod 600 "$tmp"
chown --reference="$ENV_FILE" "$tmp" 2>/dev/null || true
mv "$tmp" "$ENV_FILE"

echo "rewrote $ENV_FILE to the VAULT__* bootstrap lines"
echo "original kept at $backup"
REMOTE

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry run: keys in the env file for '$APP' on $TARGET"
else
  log "Moving '$APP' secrets into Vault on $TARGET"
fi

# The body runs as one function so bash has read all of it before the first command:
# `docker exec -i` inherits stdin, and would otherwise swallow the rest of the script.
# Exit 10 means the remote side changed nothing on purpose (dry run, or no keys left).
rc=0
ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' <<<"${PARAMS}
main() {
${BODY}
}
main" || rc=$?
[[ $rc -eq 10 ]] && exit 0
[[ $rc -eq 0 ]] || exit "$rc"

cat >&2 <<EOF

======================================================================
  '$APP' now reads its secrets from Vault at ${MOUNT}/${APP}
======================================================================
  1. Redeploy the app (re-run its Deploy workflow). docker reads the
     env file only when it creates the container, so a restart is not
     enough this first time.
  2. Check it started:  docker logs --tail 50 <container>
  3. Once it works, delete the backup on the host:
       rm ${ENV_FILE}.pre-vault.*
     To roll back instead: move the backup over ${ENV_FILE} and redeploy.

  From now on edit values in the Vault UI (see tools/vault/README.md),
  then apply them with:  docker restart <container>
======================================================================
EOF
