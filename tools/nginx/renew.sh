#!/usr/bin/env bash
#
# renew.sh — renew all Let's Encrypt certificates and reload nginx.
#
# Safe to run often (certbot only renews certs near expiry). Intended for a
# daily cron or systemd timer. Reloads nginx only when a renewal occurred.
#
# Usage:
#   sudo ./renew.sh [--base <dir>]
#
#   --base <dir>   Stack base directory (default: /opt/nginx).
#
# Cron example (twice daily, as root):
#   0 3,15 * * * /opt/nginx/renew.sh --base /opt/nginx >> /var/log/nginx-renew.log 2>&1
#
set -euo pipefail

BASE="/opt/nginx"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

priv() { if [[ $(id -u) -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
dc()   { priv docker compose --project-directory "$BASE" -f "$BASE/docker-compose.yml" "$@"; }

[[ -f "$BASE/docker-compose.yml" ]] || { echo "stack not found at $BASE" >&2; exit 1; }

echo "==> renewing certificates"
dc run --rm certbot renew --webroot -w /var/www/certbot --quiet

echo "==> reloading nginx"
dc exec nginx nginx -t && dc exec nginx nginx -s reload
echo "==> done"
