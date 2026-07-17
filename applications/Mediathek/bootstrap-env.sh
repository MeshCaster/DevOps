#!/usr/bin/env bash
# Create the env files that the Meshcaster.Mediathek containers are deployed with.
#
# Run this ON the CONTABO host, once, before the first deploy. deploy-container.yml
# passes these to `docker run --env-file`, so they must exist or the run aborts.
#
#   curl -fsSL https://raw.githubusercontent.com/MeshCaster/DevOps/main/applications/Mediathek/bootstrap-env.sh | bash -s -- <identity-authority>
#   ...or copy it over and:  ./bootstrap-env.sh https://identity.example.com
#
# The Postgres password is read back out of the running meshcaster-postgres
# container, because tools/infra/deploy-common-infra.sh generates secrets locally
# and deliberately never writes them to the server.

set -euo pipefail

IDENTITY_AUTHORITY="${1:-}"
ENV_DIR=/opt/meshcaster
PG_CONTAINER=meshcaster-postgres
DB_NAME=mediathek

die() { echo "error: $*" >&2; exit 1; }

[ -n "$IDENTITY_AUTHORITY" ] || die "usage: $0 <identity-authority-url>   e.g. https://identity.example.com"
command -v docker >/dev/null || die "docker not found"
docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || die "$PG_CONTAINER is not running; bring up applications/infrastructure/common first"

# Pull the generated password out of the container's environment.
PG_USER="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$PG_CONTAINER" | sed -n 's/^POSTGRES_USER=//p')"
PG_PASS="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$PG_CONTAINER" | sed -n 's/^POSTGRES_PASSWORD=//p')"
PG_USER="${PG_USER:-postgres}"
[ -n "$PG_PASS" ] || die "could not read POSTGRES_PASSWORD from $PG_CONTAINER"

# The API never creates its own database; only the schema, and only in Development.
if docker exec "$PG_CONTAINER" psql -U "$PG_USER" -tAc \
     "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  echo "database '$DB_NAME' already exists"
else
  docker exec "$PG_CONTAINER" createdb -U "$PG_USER" "$DB_NAME"
  echo "created database '$DB_NAME'"
fi

ADMIN_CLIENT_SECRET="${ADMIN_CLIENT_SECRET:-}"
if [ -z "$ADMIN_CLIENT_SECRET" ]; then
  echo "warning: ADMIN_CLIENT_SECRET is unset; writing a placeholder." >&2
  echo "         The admin panel cannot obtain a token until you replace it with the" >&2
  echo "         real mediathek-admin-m2m secret from the identity server." >&2
  ADMIN_CLIENT_SECRET=REPLACE_ME
fi

mkdir -p "$ENV_DIR"

umask 077   # the files hold a DB password and a client secret

cat > "$ENV_DIR/mediathek-api.env" <<EOF
ConnectionStrings__MediathekDb=Host=$PG_CONTAINER;Port=5432;Database=$DB_NAME;Username=$PG_USER;Password=$PG_PASS
Auth__Authority=$IDENTITY_AUTHORITY
Auth__Audience=mediathek-api
Database__AutoMigrate=true
EOF

cat > "$ENV_DIR/mediathek-admin.env" <<EOF
MediathekApi__BaseUrl=http://mediathek-api:8080
Identity__Authority=$IDENTITY_AUTHORITY
Identity__ClientId=mediathek-admin-m2m
Identity__ClientSecret=$ADMIN_CLIENT_SECRET
EOF

chmod 600 "$ENV_DIR"/mediathek-api.env "$ENV_DIR"/mediathek-admin.env

echo
echo "wrote (mode 600):"
echo "  $ENV_DIR/mediathek-api.env"
echo "  $ENV_DIR/mediathek-admin.env"
echo
echo "Re-run the Deploy workflow in MeshCaster/Meshcaster.Mediathek."
echo "The API env sets Database__AutoMigrate=true, so it will build the '$DB_NAME'"
echo "schema on first start. Demo data is never seeded outside Development."
