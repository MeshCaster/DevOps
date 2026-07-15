#!/usr/bin/env bash
#
# add-app.sh — interactively add a reverse-proxy vhost for a new application,
# obtain a Let's Encrypt certificate, and wire up websocket upgrades.
#
# It asks all the questions it needs (app name, domain(s), upstream container +
# port, websocket path, ACME email), generates a clean per-app vhost under
# <base>/nginx/conf.d/<app>.conf, issues the certificate via the certbot
# container (http-01 webroot), then reloads nginx — rolling back the vhost if
# the new config fails to validate.
#
# Any prompt can be pre-filled with a flag (handy for re-runs / automation):
#
# Usage:
#   sudo ./add-app.sh [--base <dir>] [--app <slug>] [--domains "<d1 d2>"]
#                     [--upstream <host:port>] [--ws-path </path>|none]
#                     [--email <addr>] [--staging] [--dry-run] [-h]
#
#   --base <dir>       Stack base directory (default: /opt/nginx).
#   --app <slug>       App name / vhost slug ([a-z0-9-]).
#   --domains "<...>"  Space-separated domains; the first is the primary (cert CN).
#   --upstream <h:p>   Upstream target, e.g. booking-api:8080 (container name:port).
#   --ws-path <p>      Websocket location needing long timeouts (e.g. /ws, /hubs).
#                      Pass 'none' to skip a dedicated block (upgrades still work).
#   --email <addr>     ACME registration email.
#   --staging          Use Let's Encrypt staging (for testing; avoids rate limits).
#   --dry-run          Print the generated vhost and planned steps; change nothing.
#   -h, --help         Show this help.
#
set -euo pipefail

BASE="/opt/nginx"
APP=""; DOMAINS=""; UPSTREAM=""; WS_PATH=""; EMAIL=""
STAGING=""; DRY_RUN=0; WS_ASKED=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)     BASE="${2:?}"; shift 2 ;;
    --app)      APP="${2:?}"; shift 2 ;;
    --domains)  DOMAINS="${2:?}"; shift 2 ;;
    --upstream) UPSTREAM="${2:?}"; shift 2 ;;
    --ws-path)  WS_PATH="${2:?}"; WS_ASKED=1; shift 2 ;;
    --email)    EMAIL="${2:?}"; shift 2 ;;
    --staging)  STAGING="--staging"; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
done

priv() { if [[ $(id -u) -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
dc()   { priv docker compose --project-directory "$BASE" -f "$BASE/docker-compose.yml" "$@"; }

# ask <var> <prompt> <default>  — prompt only if the var is still empty.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  [[ -n "${!__var}" ]] && return 0
  if [[ -n "$__default" ]]; then
    read -rp "$(printf '\033[1;36m?\033[0m %s [%s]: ' "$__prompt" "$__default")" __reply
    __reply="${__reply:-$__default}"
  else
    read -rp "$(printf '\033[1;36m?\033[0m %s: ' "$__prompt")" __reply
  fi
  printf -v "$__var" '%s' "$__reply"
}

[[ -f "$BASE/docker-compose.yml" ]] || die "stack not found at $BASE — run init-nginx.sh first"

# ---- gather configuration -------------------------------------------------
ask APP      "App name / vhost slug (lowercase, e.g. booking-api)"
[[ "$APP" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid app slug: '$APP' (use [a-z0-9-])"

ask DOMAINS  "Domain(s), space-separated (first = primary)"
[[ -n "$DOMAINS" ]] || die "at least one domain is required"
PRIMARY="${DOMAINS%% *}"

ask UPSTREAM "Upstream target (container-name:port, e.g. ${APP}:8080)"
[[ "$UPSTREAM" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]] || die "upstream must be host:port, got '$UPSTREAM'"

if [[ $WS_ASKED -eq 0 ]]; then
  read -rp "$(printf '\033[1;36m?\033[0m Does this app use websockets? (adds a long-timeout location) [y/N]: ')" _ws
  if [[ "$_ws" =~ ^[Yy] ]]; then
    ask WS_PATH "  Websocket path" "/ws"
  else
    WS_PATH="none"
  fi
fi
[[ "$WS_PATH" == "none" ]] && WS_PATH=""

ask EMAIL "ACME (Let's Encrypt) email for expiry notices"
[[ "$EMAIL" == *@*.* ]] || die "invalid email: '$EMAIL'"

CONF="$BASE/nginx/conf.d/${APP}.conf"

# ---- render the vhost ------------------------------------------------------
render_http() {
cat <<EOF
# Managed by tools/nginx/add-app.sh — app: $APP — upstream: $UPSTREAM
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAINS;

    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
}

render_https() {
cat <<EOF

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAINS;

    ssl_certificate         /etc/letsencrypt/live/$PRIMARY/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/$PRIMARY/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$PRIMARY/chain.pem;
    include /etc/nginx/snippets/ssl-params.conf;

    access_log /var/log/nginx/${APP}.access.log main;
    error_log  /var/log/nginx/${APP}.error.log warn;
EOF
  if [[ -n "$WS_PATH" ]]; then
cat <<EOF

    location $WS_PATH {
        proxy_pass http://$UPSTREAM;
        include /etc/nginx/snippets/proxy-common.conf;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
EOF
  fi
cat <<EOF

    location / {
        proxy_pass http://$UPSTREAM;
        include /etc/nginx/snippets/proxy-common.conf;
    }
}
EOF
}

log "Planned vhost for '$APP' -> http://$UPSTREAM"
printf '  domains : %s\n  primary : %s\n  ws-path : %s\n  file    : %s\n' \
  "$DOMAINS" "$PRIMARY" "${WS_PATH:-<none>}" "$CONF"

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry run — generated config:"
  echo "----------------------------------------"
  { render_http; render_https; }
  echo "----------------------------------------"
  log "Dry run complete. Nothing changed."
  exit 0
fi

if [[ -e "$CONF" ]]; then
  read -rp "$(printf '\033[1;33m!\033[0m %s exists. Overwrite? [y/N]: ' "$CONF")" _ov
  [[ "$_ov" =~ ^[Yy] ]] || die "aborted"
  priv cp "$CONF" "$CONF.bak"
fi

# validate + reload, restoring the previous vhost on failure.
reload_nginx() {
  if ! dc exec nginx nginx -t; then
    warn "nginx config test failed"
    if [[ -e "$CONF.bak" ]]; then priv mv "$CONF.bak" "$CONF"; else priv rm -f "$CONF"; fi
    dc exec nginx nginx -t >/dev/null 2>&1 || true
    die "rolled back $APP; nginx left running on the previous config"
  fi
  dc exec nginx nginx -s reload
}

log "Ensuring nginx is running"
dc up -d nginx

# 1) HTTP-only first, so ACME http-01 can reach the domain.
log "Writing HTTP vhost (for ACME challenge)"
render_http | priv tee "$CONF" >/dev/null
reload_nginx

# 2) Obtain the certificate via the certbot container (webroot method).
log "Requesting certificate for: $DOMAINS ${STAGING:+(staging)}"
domain_args=(); for d in $DOMAINS; do domain_args+=(-d "$d"); done
dc run --rm certbot certonly --webroot -w /var/www/certbot \
  --email "$EMAIL" --agree-tos --no-eff-email --keep-until-expiring \
  $STAGING "${domain_args[@]}" \
  || die "certbot failed — check DNS points at this host and ports 80/443 are open"

# 3) Add the HTTPS server block now that the cert exists, then reload.
log "Writing full HTTPS vhost"
{ render_http; render_https; } | priv tee "$CONF" >/dev/null
reload_nginx
priv rm -f "$CONF.bak"

log "Done. https://$PRIMARY is live."
[[ -n "$WS_PATH" ]] && log "Websocket upgrades enabled globally; $WS_PATH has extended timeouts."
