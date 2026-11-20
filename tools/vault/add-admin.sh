#!/usr/bin/env bash
#
# add-admin.sh — give a person a Vault UI login for managing app secrets.
#
# Creates (or resets) a userpass user bound to the `secrets-admin` policy, which can
# create, read, edit and delete secrets under the meshcaster/ KV mount and change
# its own password — and nothing else: no policies, no auth methods, no AppRoles, no
# unseal. That keeps the root token for break-glass only.
#
# A password is generated locally and printed ONCE; change it after the first login
# (person icon, top right of the UI, "Change password" — or `vault write
# auth/userpass/users/<name>/password password=-`). Re-running for an existing user
# resets their password.
#
# Needs the root token (or any token that can write policies and auth) in VAULT_TOKEN.
# It travels inside the script on stdin, never in argv.
#
# Usage:
#   VAULT_TOKEN=<token> ./add-admin.sh [options] <user@host> <username>
#
#   -p <port>         SSH port (default: 22).
#   -i <identity>     SSH private key file.
#   --ttl <dur>       How long a UI login lasts (default: 8h).
#   --length <n>      Generated password length (default: 24).
#   -h, --help        Show this help.
#
# Then open the UI through the tunnel and sign in with method "Username":
#   tools/infra/tunnel.sh --service vault -i ~/.ssh/key root@host
#   open http://127.0.0.1:18200/ui
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
TTL="8h"
PW_LEN=24
CONTAINER="meshcaster-vault"
MOUNT="meshcaster"
POLICY="secrets-admin"
TARGET=""
USERNAME=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --ttl) TTL="${2:?--ttl needs a value}"; shift 2 ;;
    --length) PW_LEN="${2:?--length needs a value}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"
      elif [[ -z "$USERNAME" ]]; then USERNAME="$1"
      else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[[ -n "$TARGET" ]]   || die "no target host given; try --help"
[[ -n "$USERNAME" ]] || die "no username given; try --help"
[[ "$USERNAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "username must be lowercase alphanumeric/.-_: $USERNAME"
[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is required in the environment (the Vault root token)"
command -v openssl >/dev/null 2>&1 || die "openssl is required to generate the password"

# Alphanumeric only, so it pastes cleanly. Same generator as deploy-common-infra.sh.
gen_secret() {
  local s
  s="$(openssl rand -base64 $((PW_LEN * 2)) | LC_ALL=C tr -dc 'A-Za-z0-9')"
  printf '%s' "${s:0:$PW_LEN}"
}
PASSWORD="$(gen_secret)"

SSH_OPTS=(-p "$SSH_PORT")
[[ -n "$IDENTITY" ]] && SSH_OPTS+=(-i "$IDENTITY")

PARAMS="$(
  printf 'export VAULT_TOKEN=%q\n' "$VAULT_TOKEN"
  printf 'PASSWORD=%q USERNAME=%q TTL=%q\n' "$PASSWORD" "$USERNAME" "$TTL"
  printf 'CONTAINER=%q MOUNT=%q POLICY=%q\n' "$CONTAINER" "$MOUNT" "$POLICY"
)"

# read -d '' rather than $(cat <<...): macOS's bash 3.2 cannot parse a `case` inside $(...).
IFS= read -r -d '' BODY <<'REMOTE' || true
set -euo pipefail
die() { echo "error: $*" >&2; exit 1; }
run() { docker exec -i -e VAULT_TOKEN "$CONTAINER" "$@"; }

docker inspect "$CONTAINER" >/dev/null 2>&1 || die "$CONTAINER is not running"
run vault status >/dev/null 2>&1 || die "Vault is sealed or unreachable"

run vault secrets enable -path="$MOUNT" kv-v2 >/dev/null 2>&1 || true
run vault auth enable userpass              >/dev/null 2>&1 || true
accessor="$(run vault read -field=accessor sys/auth/userpass)"

# Everything the KV v2 screens of the UI touch, for this one mount. The last block lets
# a user change their own password and no one else's: the templated name resolves to
# the username they signed in with.
run vault policy write "$POLICY" - >/dev/null <<POLICY
path "${MOUNT}/data/*"     { capabilities = ["create", "read", "update", "patch", "delete"] }
path "${MOUNT}/metadata"   { capabilities = ["list"] }
path "${MOUNT}/metadata/*" { capabilities = ["read", "list", "update", "delete"] }
path "${MOUNT}/subkeys/*"  { capabilities = ["read"] }
path "${MOUNT}/delete/*"   { capabilities = ["update"] }
path "${MOUNT}/undelete/*" { capabilities = ["update"] }
path "${MOUNT}/destroy/*"  { capabilities = ["update"] }
path "${MOUNT}/config"     { capabilities = ["read"] }

path "sys/mounts"                { capabilities = ["read"] }
path "sys/internal/ui/mounts"    { capabilities = ["read"] }
path "sys/internal/ui/mounts/*"  { capabilities = ["read"] }

path "auth/userpass/users/{{identity.entity.aliases.${accessor}.name}}/password" {
  capabilities = ["update"]
}
POLICY

# password=- reads the value from stdin.
printf '%s' "$PASSWORD" | run vault write "auth/userpass/users/$USERNAME" \
    password=- token_policies="$POLICY" token_ttl="$TTL" token_max_ttl="$TTL" >/dev/null

echo "user $USERNAME can sign in with policy $POLICY"
REMOTE

log "Creating Vault UI login '$USERNAME' on $TARGET"
# The body runs as one function so bash has read all of it before the first command:
# `docker exec -i` inherits stdin, and would otherwise swallow the rest of the script.
ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' <<<"${PARAMS}
main() {
${BODY}
}
main"

cat >&2 <<EOF

======================================================================
  Vault UI login — SAVE THE PASSWORD NOW (shown once, stored nowhere)
======================================================================
  Method   : Username
  Username : ${USERNAME}
  Password : ${PASSWORD}

  Open it:
    tools/infra/tunnel.sh --service vault ${IDENTITY:+-i $IDENTITY }${TARGET}
    http://127.0.0.1:18200/ui

  Secrets are under "${MOUNT}/", one entry per app. After saving an
  edit, apply it with:  docker restart <container>
======================================================================
EOF
