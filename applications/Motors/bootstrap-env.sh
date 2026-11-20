#!/usr/bin/env bash
# Bootstrap the Meshcaster.Motors (Tvali) staging stack on the CONTABO host.
#
# Run ON the host (or stream it:  ssh contabo 'bash -s' < bootstrap-env.sh), once before
# the first API deploy. Safe to re-run: existing env files and secrets are never replaced.
#
# Also writes the Motors Admin and Motor website env files and adds Admin__*/Site__IpSalt to the API env.
#
# Motors needs TimescaleDB, which the shared meshcaster-postgres (postgres:16) doesn't have,
# so it gets its own Postgres on the `meshcaster` network with no published port. Messaging
# runs in-process (Messaging:Transport=InMemory), so no RabbitMQ is involved.
#
# Secrets are generated here, on the host, and only ever written to the mode-600 env files.

set -euo pipefail

DOMAIN="${1:-motors.in-vent.online}"
ENV_DIR=/opt/meshcaster
NETWORK=meshcaster
PG_CONTAINER=motors-postgres
PG_IMAGE=timescale/timescaledb:latest-pg17
PG_ENV="$ENV_DIR/motors-postgres.env"
API_ENV="$ENV_DIR/motors-api.env"
ADMIN_ENV="$ENV_DIR/motors-admin.env"
WEB_ENV="$ENV_DIR/motors-web.env"
IDENTITY_AUTHORITY="${IDENTITY_AUTHORITY:-https://identity.in-vent.online}"

die() { echo "error: $*" >&2; exit 1; }
rand() { openssl rand -base64 "$1" | tr -d '\n/+=' | cut -c1-"$2"; }

command -v docker >/dev/null || die "docker not found"
command -v openssl >/dev/null || die "openssl not found"
docker network inspect "$NETWORK" >/dev/null 2>&1 || die "docker network '$NETWORK' missing; run tools/nginx/init-nginx.sh first"

mkdir -p "$ENV_DIR"
umask 077

if [ -f "$PG_ENV" ]; then
  echo "kept existing $PG_ENV"
else
  cat > "$PG_ENV" <<EOF
POSTGRES_USER=motors
POSTGRES_DB=motors
POSTGRES_PASSWORD=$(rand 48 40)
EOF
  echo "wrote $PG_ENV"
fi
PG_PASS="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$PG_ENV")"

if [ -f "$API_ENV" ]; then
  echo "kept existing $API_ENV"
else
  cat > "$API_ENV" <<EOF
# Staging: OTP codes are not sent (console sender) and the fixed code 1234 signs anyone in.
# Switch to Production only once a real SMS sender and Profiles:SigningKeyPem are configured.
ASPNETCORE_ENVIRONMENT=Staging
# nginx is the only way in; trust its X-Forwarded-For/Proto (per-IP OTP rate limits need the real IP).
ASPNETCORE_FORWARDEDHEADERS_ENABLED=true
ConnectionStrings__Motors=Host=$PG_CONTAINER;Port=5432;Database=motors;Username=motors;Password=$PG_PASS
Database__MigrateOnStartup=true
Auth__Jwt__SigningKey=$(rand 64 64)
Auth__Otp__Sender=Console
Auth__Otp__DevFixedCode=1234
Billing__RevenueCat__WebhookSecret=$(rand 48 40)
Storage__Local__RootPath=/app/storage
Storage__Local__PublicBaseUrl=https://$DOMAIN
Storage__Local__SigningKey=$(rand 48 40)
Reports__PublicBaseUrl=https://$DOMAIN
Ai__Enabled=false
EOF
  echo "wrote $API_ENV"
fi

# Motors Admin (MeshCaster.Identity tokens on /api/v1/admin). Added to an existing API env without touching
# anything else in it.
ensure_line() { grep -q "^$2=" "$1" || echo "$2=$3" >> "$1"; }
ensure_line "$API_ENV" Admin__Authority "$IDENTITY_AUTHORITY"
ensure_line "$API_ENV" Admin__Audience motors-admin-api
# Salt for the hashed IPs stored with website form submissions.
ensure_line "$API_ENV" Site__IpSalt "$(rand 48 40)"

if [ -f "$ADMIN_ENV" ]; then
  echo "kept existing $ADMIN_ENV"
else
  cat > "$ADMIN_ENV" <<EOF
# Motors Admin (Blazor). Oidc__ClientSecret must equal Motors__AdminClientSecret in MeshCaster.Identity's env.
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_FORWARDEDHEADERS_ENABLED=true
Oidc__Authority=$IDENTITY_AUTHORITY
Oidc__ClientId=motors-admin
Oidc__ClientSecret=$(rand 48 43)
# The admin app calls the API over the docker network, not through Cloudflare.
Api__BaseUrl=http://motors-api:8080
EOF
  echo "wrote $ADMIN_ENV (new Oidc client secret: copy it to Identity as Motors__AdminClientSecret)"
fi

if [ -f "$WEB_ENV" ]; then
  echo "kept existing $WEB_ENV"
else
  cat > "$WEB_ENV" <<EOF
# Motor info website (Blazor static SSR). No secrets: it reads public catalog endpoints and posts forms.
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_FORWARDEDHEADERS_ENABLED=true
# Server-to-server over the docker network; image URLs point at the public API origin.
Api__BaseUrl=http://motors-api:8080
Api__PublicBaseUrl=https://$DOMAIN
Site__PublicUrl=https://motor.in-vent.online
EOF
  echo "wrote $WEB_ENV"
fi

chmod 600 "$PG_ENV" "$API_ENV" "$ADMIN_ENV" "$WEB_ENV"

if docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
  echo "$PG_CONTAINER already exists"
else
  docker run -d --name "$PG_CONTAINER" \
    --network "$NETWORK" \
    --restart unless-stopped \
    --env-file "$PG_ENV" \
    -v motors_pg:/var/lib/postgresql/data \
    --health-cmd 'pg_isready -U motors -d motors' --health-interval 10s --health-retries 10 \
    "$PG_IMAGE" >/dev/null
  echo "started $PG_CONTAINER ($PG_IMAGE, volume motors_pg, no published port)"
fi

echo
echo "next: deploy motors-api (--env-file $API_ENV --network $NETWORK -v motors_storage:/app/storage)"
echo "      motors-admin (--env-file $ADMIN_ENV --network $NETWORK) and motors-web (--env-file $WEB_ENV),"
echo "      add nginx/motors.conf, motors-admin.conf and motors-web.conf, request the certs, and set"
echo "      Identity's Motors__AdminClientSecret."
