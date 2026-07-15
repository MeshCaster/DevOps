#!/usr/bin/env bash
#
# init-nginx.sh — scaffold a containerized nginx reverse-proxy + certbot stack.
#
# Creates a tidy, well-organized layout under a base directory, writes the
# nginx main config, shared snippets (SSL params, proxy headers, the websocket
# upgrade map), a docker-compose.yml running nginx + certbot, ensures the shared
# app network exists, and starts nginx. Idempotent: never touches per-app vhosts
# in conf.d/, only the shared infrastructure files.
#
# Layout it produces:
#   <base>/
#     docker-compose.yml
#     nginx/
#       nginx.conf
#       conf.d/                 per-app vhosts live here (added by add-app.sh)
#         00-websocket-map.conf   map $http_upgrade -> $connection_upgrade
#         00-default.conf         default catch-all + ACME webroot
#       snippets/
#         ssl-params.conf
#         proxy-common.conf
#     certbot/
#       conf/                   /etc/letsencrypt (certs + accounts)
#       www/                    ACME http-01 webroot
#     logs/
#       nginx/  certbot/
#
# Usage:
#   sudo ./init-nginx.sh [--base <dir>] [--network <name>] [--no-network] [-h]
#
#   --base <dir>     Base directory for the stack (default: /opt/nginx).
#   --network <name> External Docker network apps attach to (default: meshcaster).
#   --no-network     Do not create the network (assume it already exists).
#   -h, --help       Show this help.
#
set -euo pipefail

BASE="/opt/nginx"
NETWORK="meshcaster"
CREATE_NETWORK=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)       BASE="${2:?--base needs a value}"; shift 2 ;;
    --network)    NETWORK="${2:?--network needs a value}"; shift 2 ;;
    --no-network) CREATE_NETWORK=0; shift ;;
    -h|--help)    usage 0 ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
done

priv() { if [[ $(id -u) -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
writef() { # writef <path> <mode> ; content on stdin
  priv tee "$1" >/dev/null
  priv chmod "$2" "$1"
}

command -v docker >/dev/null 2>&1 || die "docker not found — run tools/docker/setup-docker.sh first"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin not found"

log "Creating layout under $BASE"
priv install -d -m 0755 \
  "$BASE" "$BASE/nginx" "$BASE/nginx/conf.d" "$BASE/nginx/snippets" \
  "$BASE/certbot/conf" "$BASE/certbot/www" "$BASE/logs/nginx" "$BASE/logs/certbot"

log "Writing nginx.conf"
writef "$BASE/nginx/nginx.conf" 0644 <<'EOF'
user  nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events { worker_connections 1024; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;
    client_max_body_size 50m;

    gzip on;
    gzip_vary on;
    gzip_disable "msie6";
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript;

    # Per-app vhosts and shared maps live here.
    include /etc/nginx/conf.d/*.conf;
}
EOF

log "Writing shared snippets"
writef "$BASE/nginx/snippets/ssl-params.conf" 0644 <<'EOF'
# Modern, broadly-compatible TLS. Managed by init-nginx.sh.
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000" always;
add_header X-Content-Type-Options "nosniff" always;
EOF

writef "$BASE/nginx/snippets/proxy-common.conf" 0644 <<'EOF'
# Shared reverse-proxy headers. Includes websocket upgrade handling so ANY
# proxied location can transparently upgrade. Managed by init-nginx.sh.
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header Upgrade           $http_upgrade;
proxy_set_header Connection        $connection_upgrade;
proxy_read_timeout 60s;
proxy_send_timeout 60s;
proxy_buffering off;
EOF

log "Writing websocket upgrade map + default server (loaded first)"
writef "$BASE/nginx/conf.d/00-websocket-map.conf" 0644 <<'EOF'
# Maps the Upgrade header to the Connection value nginx must send upstream.
# Defined once in the http context; referenced by snippets/proxy-common.conf.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

writef "$BASE/nginx/conf.d/00-default.conf" 0644 <<'EOF'
# Default catch-all: serves ACME http-01 challenges for any host, drops the
# rest (444) so unknown hostnames never fall through to a real app.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 444;
    }
}
EOF

log "Writing docker-compose.yml (network: $NETWORK)"
writef "$BASE/docker-compose.yml" 0644 <<EOF
name: nginx-proxy

services:
  nginx:
    image: nginx:1.27-alpine
    container_name: nginx-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/snippets:/etc/nginx/snippets:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
      - ./logs/nginx:/var/log/nginx
    networks:
      - proxy

  # Run on demand: docker compose run --rm certbot ...  (see add-app.sh / renew.sh)
  certbot:
    image: certbot/certbot:latest
    container_name: certbot
    profiles: ["certbot"]
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
      - ./logs/certbot:/var/log/letsencrypt

networks:
  proxy:
    external: true
    name: ${NETWORK}
EOF

if [[ $CREATE_NETWORK -eq 1 ]]; then
  if priv docker network inspect "$NETWORK" >/dev/null 2>&1; then
    log "Network '$NETWORK' already exists"
  else
    log "Creating external network '$NETWORK'"
    priv docker network create "$NETWORK"
  fi
fi

log "Validating and starting nginx"
priv docker compose --project-directory "$BASE" -f "$BASE/docker-compose.yml" up -d nginx
priv docker compose --project-directory "$BASE" -f "$BASE/docker-compose.yml" exec nginx nginx -t

log "Done. nginx is up. Add an app with: sudo ./add-app.sh --base $BASE"
