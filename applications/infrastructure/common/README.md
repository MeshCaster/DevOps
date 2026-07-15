# Common Infrastructure

Shared backing services — **Postgres**, **RabbitMQ**, and **Redis** — that every
Meshcaster app on a host connects to over the external `meshcaster` Docker
network. Bring this up **once per server**; per-app stacks attach by network
name and reach each service by container name (`meshcaster-postgres:5432`,
`meshcaster-redis:6379`, `meshcaster-rabbitmq:5672`).

## Contents

| Service | Image | Ports | Notes |
|---------|-------|-------|-------|
| Postgres | `postgres:16` | `5432` | Data in the `meshcaster_pg` volume; create DBs manually per app. |
| Redis | `redis:7` | `6379` | AOF persistence in the `meshcaster_redis` volume. |
| RabbitMQ | `rabbitmq:3-management` | `5672`, `15672` | Management UI on `15672`. |

Credentials come from the **environment**, not an `env_file`, so the stack can be
deployed remotely with generated secrets and **no `.env` on the server**.

### Remote (recommended)

Use [`tools/infra/deploy-common-infra.sh`](../../../tools/infra/README.md) — it
generates secrets, streams the compose + env over SSH, prints the credentials
once, and leaves nothing on the host:

```bash
tools/infra/deploy-common-infra.sh -i ~/.ssh/meshcaster_contabo root@contabo-host
```

### Local development

```bash
docker network create meshcaster    # once; ignore "already exists"
cp .env.example .env                 # compose auto-loads ./.env for interpolation
docker compose up -d
docker compose ps
```

## Databases

Create each app's database manually against the running Postgres:

```bash
docker exec -it meshcaster-postgres psql -U "$POSTGRES_USER" -c "CREATE DATABASE streetfood;"
docker exec -it meshcaster-postgres psql -U "$POSTGRES_USER" -c "CREATE DATABASE streetfoodstaging;"
```

## Relationship to the rest of the repo

- Install Docker on the host first with [`tools/docker`](../../../tools/docker/README.md).
- Put an nginx reverse proxy in front of your apps with [`tools/nginx`](../../../tools/nginx/README.md) — it joins the same `meshcaster` network.
- Apps are deployed via the [`deploy-container.yml`](../../../.github/workflows/deploy-container.yml) reusable workflow; run their containers on the `meshcaster` network so they can reach these services.
