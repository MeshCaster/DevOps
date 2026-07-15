#!/usr/bin/env bash
#
# setup-docker.sh — bootstrap Docker Engine + Compose plugin on a Linux host.
#
# Installs Docker Engine, the CLI, containerd, Buildx and the Compose v2 plugin
# from Docker's official apt/dnf repositories, enables the service, and (unless
# told otherwise) adds the invoking user to the `docker` group.
#
# Supported: Debian/Ubuntu (apt) and RHEL/Fedora/Rocky/Alma (dnf).
#
# Usage:
#   ./setup-docker.sh [--no-usermod] [--user <name>] [--dry-run] [-h|--help]
#
#   --no-usermod   Do not add a user to the `docker` group.
#   --user <name>  User to add to the `docker` group (default: $SUDO_USER or you).
#   --dry-run      Print the commands that would run without executing them.
#
set -euo pipefail

NO_USERMOD=0
DRY_RUN=0
TARGET_USER="${SUDO_USER:-$(id -un)}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-usermod) NO_USERMOD=1; shift ;;
    --user)       TARGET_USER="${2:?--user needs a value}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage 0 ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
done

# Run a privileged command, honoring --dry-run and only using sudo when needed.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_distro() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release; unsupported OS"
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "${ID}:${ID_LIKE:-}"
}

install_apt() {
  log "Installing Docker via apt for $1"
  run install -m 0755 -d /etc/apt/keyrings
  run apt-get update -y
  run apt-get install -y ca-certificates curl gnupg
  if [[ $DRY_RUN -eq 0 ]]; then
    curl -fsSL "https://download.docker.com/linux/${1}/gpg" \
      | run gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    run chmod a+r /etc/apt/keyrings/docker.gpg
    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${1} ${codename} stable" \
      | run tee /etc/apt/sources.list.d/docker.list >/dev/null
  else
    printf '  [dry-run] configure docker apt repo + gpg key for %s\n' "$1"
  fi
  run apt-get update -y
  run apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

install_dnf() {
  log "Installing Docker via dnf for $1"
  run dnf -y install dnf-plugins-core
  run dnf config-manager --add-repo "https://download.docker.com/linux/${1}/docker-ce.repo"
  run dnf -y install docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

main() {
  [[ "$(uname -s)" == "Linux" ]] || die "this script only supports Linux hosts"

  if command -v docker >/dev/null 2>&1; then
    warn "docker is already installed: $(docker --version 2>/dev/null || echo unknown)"
  fi

  local distro id like
  distro="$(detect_distro)"
  id="${distro%%:*}"
  like="${distro#*:}"

  case "$id" in
    ubuntu)                 install_apt ubuntu ;;
    debian)                 install_apt debian ;;
    fedora)                 install_dnf fedora ;;
    centos|rhel|rocky|almalinux) install_dnf centos ;;
    *)
      case "$like" in
        *debian*|*ubuntu*)  install_apt "${id}" ;;
        *rhel*|*fedora*)    install_dnf centos ;;
        *) die "unsupported distro: $id (like: ${like:-none})" ;;
      esac ;;
  esac

  log "Enabling and starting the docker service"
  run systemctl enable --now docker

  if [[ $NO_USERMOD -eq 0 ]]; then
    log "Adding user '$TARGET_USER' to the 'docker' group"
    run usermod -aG docker "$TARGET_USER"
    warn "log out and back in (or run 'newgrp docker') for group membership to apply"
  fi

  log "Done. Verify with: docker run --rm hello-world"
}

main "$@"
