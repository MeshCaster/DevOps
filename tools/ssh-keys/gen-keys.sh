#!/usr/bin/env bash
#
# gen-keys.sh — generate and manage named SSH deploy keypairs on your laptop.
#
# Keeps one keypair per VPS provider so migrating an app between hosts (e.g.
# Hostinger -> CONTABO) is just a matter of swapping which key you install on
# the server and which private key lives in the repo's GitHub secrets.
#
# Keys are written to ~/.ssh with predictable, provider-scoped names:
#
#   ~/.ssh/meshcaster_contabo        (private — goes into CONTABO_SSH_PRIVATE_KEY)
#   ~/.ssh/meshcaster_contabo.pub    (public  — goes into the server's authorized_keys)
#   ~/.ssh/meshcaster_hostinger      (private — the old host, kept for rollback)
#   ~/.ssh/meshcaster_hostinger.pub  (public)
#
# Usage:
#   ./gen-keys.sh [--provider <name>] [--all] [--force] [--comment <c>] [--print]
#
#   --provider <name>  Provider to generate a key for (e.g. contabo, hostinger).
#   --all              Generate keys for every provider in the default set.
#   --repo <o/r>       GitHub repo (owner/name) to target in the printed
#                      `gh secret set` commands. Without it, gh falls back to the
#                      origin remote of your current directory.
#   --comment <c>      Key comment (default: meshcaster-<provider>).
#   --force            Overwrite an existing key of the same name.
#   --print            Print the public key(s) after generating (or if they exist).
#   -h, --help         Show this help.
#
# Examples:
#   ./gen-keys.sh --provider contabo --print --repo MeshCaster/Cafe.Api
#   ./gen-keys.sh --all                          # mint contabo + hostinger keys
#   ./gen-keys.sh --provider contabo --print     # re-print an existing public key
#
set -euo pipefail

SSH_DIR="${HOME}/.ssh"
PREFIX="meshcaster_"
DEFAULT_PROVIDERS=(contabo hostinger)

PROVIDERS=()
ALL=0
FORCE=0
PRINT=0
COMMENT=""
REPO=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDERS+=("${2:?--provider needs a value}"); shift 2 ;;
    --all)      ALL=1; shift ;;
    --repo)     REPO="${2:?--repo needs a value}"; shift 2 ;;
    --comment)  COMMENT="${2:?--comment needs a value}"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    --print)    PRINT=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found on PATH"

[[ $ALL -eq 1 ]] && PROVIDERS=("${DEFAULT_PROVIDERS[@]}")
[[ ${#PROVIDERS[@]} -gt 0 ]] || die "no provider given; use --provider <name> or --all"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

print_pub() {
  local pub="$1"
  echo
  log "Public key ($pub) — add this to the server's ~/.ssh/authorized_keys:"
  echo "----------------------------------------------------------------------"
  cat "$pub"
  echo "----------------------------------------------------------------------"
}

for provider in "${PROVIDERS[@]}"; do
  key="${SSH_DIR}/${PREFIX}${provider}"
  pub="${key}.pub"
  comment="${COMMENT:-meshcaster-${provider}}"

  if [[ -f "$key" && $FORCE -eq 0 ]]; then
    warn "key already exists: $key (use --force to overwrite)"
    [[ $PRINT -eq 1 && -f "$pub" ]] && print_pub "$pub"
    continue
  fi

  [[ -f "$key" && $FORCE -eq 1 ]] && { warn "overwriting $key"; rm -f "$key" "$pub"; }

  log "Generating ed25519 keypair for '$provider' -> $key"
  ssh-keygen -t ed25519 -a 100 -N "" -C "$comment" -f "$key" >/dev/null
  chmod 600 "$key"
  chmod 644 "$pub"

  [[ $PRINT -eq 1 ]] && print_pub "$pub"
done

# Target flag for the gh commands: explicit --repo if given, else gh uses the
# origin remote of whatever directory you run these in.
if [[ -n "$REPO" ]]; then
  gh_target="-R ${REPO} "
  repo_note="targeting ${REPO}"
else
  gh_target=""
  repo_note="run these inside the app's repo, or add -R <owner/repo>"
fi

echo
log "Next steps to migrate an app to CONTABO:"
cat <<EOF
  1. Add the CONTABO public key to the server:
       ssh-copy-id -i ~/.ssh/meshcaster_contabo.pub <user>@<contabo-host>
     (or paste ~/.ssh/meshcaster_contabo.pub into the server's authorized_keys)

  2. Put the matching PRIVATE key into the repo's GitHub secrets (${repo_note}):
       gh secret set ${gh_target}CONTABO_SSH_PRIVATE_KEY < ~/.ssh/meshcaster_contabo
       gh secret set ${gh_target}CONTABO_HOST     --body "<contabo-host-or-ip>"
       gh secret set ${gh_target}CONTABO_USERNAME --body "<ssh-user>"

  3. The deploy-container.yml reusable workflow will now use these to
     build, push, and (re)start the container on CONTABO.
EOF
