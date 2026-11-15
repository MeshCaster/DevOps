#!/usr/bin/env bash
#
# init-vault.sh — initialize Vault on a remote host, ONCE, and install the keys
# that let it unseal itself after a reboot.
#
# What it does:
#   1. `vault operator init` on the remote (aborts if already initialized).
#   2. Writes <threshold> unseal keys to /etc/meshcaster/vault/keys (root, 0600),
#      which the unsealer sidecar reads to bring Vault back unattended.
#   3. Prints ALL unseal keys + the root token to YOU exactly once.
#
# The init output travels back over the SSH session; the keys are pushed to the
# server inside a script on stdin, so they never appear in argv or shell history.
#
# ---------------------------------------------------------------------------
#  READ THIS: the key file on the host is unseal-equivalent. Anyone who can read
#  /etc/meshcaster/vault/keys can unseal Vault. That is the deliberate price of
#  surviving a reboot without a human. It is not weaker than what you run today —
#  root can already read /opt/meshcaster/*.env and `docker inspect` every
#  password — but it does mean host security is what protects Vault. To opt out,
#  delete that file and unseal by hand after each restart (see --no-autounseal).
# ---------------------------------------------------------------------------
#
# Usage:
#   ./init-vault.sh [options] <user@host>
#
#   -p <port>          SSH port (default: 22).
#   -i <identity>      SSH private key file.
#   --shares <n>       Unseal key shares to generate (default: 5).
#   --threshold <n>    Shares required to unseal (default: 3).
#   --no-autounseal    Do NOT write keys to the host. Vault stays sealed until you
#                      unseal it by hand after every restart.
#   -h, --help         Show this help.
#
# Examples:
#   ./init-vault.sh -i ~/.ssh/meshcaster_contabo root@contabo-host
#   ./init-vault.sh --no-autounseal root@contabo-host
#
set -euo pipefail

SSH_PORT=22
IDENTITY=""
SHARES=5
THRESHOLD=3
AUTOUNSEAL=1
CONTAINER="meshcaster-vault"
KEY_DIR="/etc/meshcaster/vault"
TARGET=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) SSH_PORT="${2:?-p needs a value}"; shift 2 ;;
    -i) IDENTITY="${2:?-i needs a value}"; shift 2 ;;
    --shares) SHARES="${2:?--shares needs a value}"; shift 2 ;;
    --threshold) THRESHOLD="${2:?--threshold needs a value}"; shift 2 ;;
    --no-autounseal) AUTOUNSEAL=0; shift ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[[ -n "$TARGET" ]] || die "no target host given (e.g. user@host); try --help"
[[ "$THRESHOLD" -le "$SHARES" ]] || die "--threshold ($THRESHOLD) cannot exceed --shares ($SHARES)"
command -v python3 >/dev/null 2>&1 || die "python3 is required locally to parse Vault's init output"

SSH_OPTS=(-p "$SSH_PORT")
[[ -n "$IDENTITY" ]] && SSH_OPTS+=(-i "$IDENTITY")

# ---- 1. Initialize (refuse to touch an already-initialized Vault) -----------
log "Initializing Vault on $TARGET ($SHARES shares, threshold $THRESHOLD)"

INIT_JSON="$(ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' <<EOF
set -euo pipefail
docker inspect '${CONTAINER}' >/dev/null 2>&1 || { echo 'error: ${CONTAINER} is not running; deploy-vault.sh first' >&2; exit 1; }

# 'vault status' exits 2 when sealed, which is the normal pre-init state, so the
# exit code is not an error signal here — the Initialized field is.
if docker exec '${CONTAINER}' vault status 2>/dev/null | grep -qE '^Initialized[[:space:]]+true'; then
  echo 'error: Vault is already initialized. Re-initializing would orphan every existing secret.' >&2
  echo '       If you really mean to start over, destroy the meshcaster_vault volume first.' >&2
  exit 1
fi

docker exec '${CONTAINER}' vault operator init -key-shares=${SHARES} -key-threshold=${THRESHOLD} -format=json
EOF
)"

[[ -n "$INIT_JSON" ]] || die "no init output returned from the remote"

# ---- 2. Parse locally -------------------------------------------------------
parse() { printf '%s' "$INIT_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }

ROOT_TOKEN="$(parse 'print(d["root_token"])')"
# `mapfile`/`readarray` is bash 4+; macOS ships bash 3.2, so read into the array
# by hand to keep this script portable.
KEYS=()
while IFS= read -r _k; do KEYS+=("$_k"); done < <(parse 'print("\n".join(d["unseal_keys_b64"]))')

[[ -n "$ROOT_TOKEN" ]]         || die "could not parse the root token out of the init output"
[[ ${#KEYS[@]} -eq $SHARES ]]  || die "expected $SHARES unseal keys, parsed ${#KEYS[@]}"

# ---- 3. Install the auto-unseal keys ---------------------------------------
if [[ $AUTOUNSEAL -eq 1 ]]; then
  log "Installing $THRESHOLD unseal keys to ${KEY_DIR}/keys on the host (root, 0600)"

  KEYS_QUOTED=""
  for k in "${KEYS[@]:0:$THRESHOLD}"; do KEYS_QUOTED+=" '$k'"; done

  # Keys ride inside this script on stdin — never in argv, never in history.
  ssh "${SSH_OPTS[@]}" "$TARGET" 'bash -s' <<EOF
set -euo pipefail
SUDO=""
[ "\$(id -u)" -ne 0 ] && SUDO="sudo"
umask 077
printf '%s\n'${KEYS_QUOTED} | \$SUDO tee '${KEY_DIR}/keys' >/dev/null
\$SUDO chmod 600 '${KEY_DIR}/keys'
\$SUDO chown root:root '${KEY_DIR}/keys' 2>/dev/null || true
EOF

  log "Waiting for the unsealer sidecar to pick them up (it polls every 15s)"
  UNSEALED=0
  for _ in $(seq 1 12); do
    if ssh "${SSH_OPTS[@]}" "$TARGET" "docker exec '${CONTAINER}' vault status >/dev/null 2>&1"; then
      UNSEALED=1; break
    fi
    sleep 3
  done
  if [[ $UNSEALED -eq 1 ]]; then
    log "Vault is UNSEALED and will unseal itself after a reboot."
  else
    warn "Vault is still sealed. Check: docker logs meshcaster-vault-unsealer"
  fi
else
  warn "--no-autounseal: no keys written. Vault stays SEALED until you run:"
  warn "    ssh $TARGET \"docker exec -it $CONTAINER vault operator unseal\"   # x$THRESHOLD"
fi

# ---- 4. Print everything ONCE ----------------------------------------------
{
  echo
  echo "======================================================================"
  echo "  Vault initialized — SAVE THIS NOW, it is shown once and stored nowhere"
  echo "======================================================================"
  echo "  Host        : ${TARGET#*@}"
  echo
  echo "  Root token  : ${ROOT_TOKEN}"
  echo
  echo "  Unseal keys (${THRESHOLD} of ${SHARES} required):"
  i=1
  for k in "${KEYS[@]}"; do
    if [[ $AUTOUNSEAL -eq 1 && $i -le $THRESHOLD ]]; then
      printf '    %d. %s   <- also on the host, for auto-unseal\n' "$i" "$k"
    else
      printf '    %d. %s\n' "$i" "$k"
    fi
    i=$((i + 1))
  done
  echo
  echo "======================================================================"
  echo "  Next:"
  echo "    1. Store these in your password manager, split across the team."
  echo "    2. Provision an app:"
  echo "         tools/vault/provision-app.sh ${IDENTITY:+-i $IDENTITY }${TARGET} mediathek-api"
  echo "    3. Then REVOKE the root token — provisioning is the only thing that"
  echo "       needs it, and you can mint a new one from the unseal keys anytime"
  echo "       with 'vault operator generate-root':"
  echo "         ssh ${TARGET} \"docker exec -e VAULT_TOKEN=<root> ${CONTAINER} vault token revoke -self\""
  echo "======================================================================"
  echo
} >&2
