# Common Infrastructure Deploy Tool

`deploy-common-infra.sh` brings up the shared **Postgres + RabbitMQ + Redis**
stack ([`applications/infrastructure/common`](../../applications/infrastructure/common/README.md))
on a remote host over SSH — with **freshly generated credentials printed to you
exactly once** and **nothing written to the server** (no `.env`, no compose file).

## Why no files on the server?

Secrets are generated on your laptop, then a single script is streamed to
`ssh <host> bash -s`. That script `export`s the secrets and pipes the compose
file into `docker compose -f -` (stdin). So:

- No `.env` or compose file ever lands on the remote disk.
- Secrets aren't passed as command arguments, so they don't show up in the
  remote process list (`ps`) or shell history.
- The generated passwords are printed **once** at the end — save them to your
  notes immediately; they are not stored anywhere.

## Prerequisites

- Docker + Compose v2 on the remote (install with [`tools/docker`](../docker/README.md)).
- SSH access with a sudo-capable / docker-capable user (use your CONTABO key
  from [`tools/ssh-keys`](../ssh-keys/README.md)).
- `openssl` on your laptop (used to generate the secrets).

## Usage

```bash
# Deploy to CONTABO using the provider deploy key
tools/infra/deploy-common-infra.sh -i ~/.ssh/meshcaster_contabo root@contabo-host

# Custom SSH port / network
tools/infra/deploy-common-infra.sh -p 2222 deploy@vps1 --network meshcaster

# Preview the exact remote script without running it (secrets still shown)
tools/infra/deploy-common-infra.sh --dry-run root@contabo-host
```

| Flag | Description |
|------|-------------|
| `-p <port>` | SSH port (default: `22`). |
| `-i <identity>` | SSH private key file (e.g. `~/.ssh/meshcaster_contabo`). |
| `--network <name>` | Docker network to create/attach (default: `meshcaster`). |
| `--pg-user <u>` | Postgres username (default: `postgres`). |
| `--mq-user <u>` | RabbitMQ username (default: `rabbit`). |
| `--length <n>` | Generated password length (default: `32`). |
| `--compose <path>` | Compose file to deploy (default: the repo's common stack). |
| `--dry-run` | Print the remote script instead of running it. |
| `-h`, `--help` | Show help. |

## After deploying

1. **Save the printed credentials** — they're shown once and not persisted.
2. **Create per-app databases** (the stack ships no init scripts):

   ```bash
   ssh <user@host> "docker exec -i meshcaster-postgres psql -U postgres -c 'CREATE DATABASE streetfood;'"
   ssh <user@host> "docker exec -i meshcaster-postgres psql -U postgres -c 'CREATE DATABASE streetfoodstaging;'"
   ```

3. **Wire the credentials into each app** — e.g. Cafe's connection string /
   GitHub secrets. Apps reach the services by container name over the
   `meshcaster` network (`meshcaster-postgres:5432`, `meshcaster-redis:6379`,
   `meshcaster-rabbitmq:5672`).

> ⚠️ **Passwords are set on first initialization only.** Postgres and RabbitMQ
> bake the password into their data volume the first time they start. Re-running
> against an existing volume will **not** change the password — to rotate, you
> must remove the volume (destroys data) or change the password inside the
> running service.

## Accessing the services from your laptop

Don't connect to the public port directly — forward it over SSH with
`tunnel.sh`. It's encrypted, authenticated by your key, and needs **no port
exposed to the internet**:

```bash
# forward Postgres to localhost:15432 (leave running; Ctrl-C to close)
tools/infra/tunnel.sh -i ~/.ssh/meshcaster_contabo root@contabo-host

# forward everything at once
tools/infra/tunnel.sh --service all root@contabo-host
```

Default local ports: Postgres `15432`, Redis `16379`, RabbitMQ `15672`,
RabbitMQ UI `15673`. Then, in another terminal / your GUI client:

```bash
psql "host=localhost port=15432 user=postgres dbname=streetfood"
redis-cli -h localhost -p 16379 -a <redis-password> ping
open http://localhost:15673            # RabbitMQ management UI
```

| Flag | Description |
|------|-------------|
| `-p <port>` | SSH port (default: `22`). |
| `-i <identity>` | SSH private key. |
| `--service <svc>` | `postgres` \| `redis` \| `rabbitmq` \| `rabbitmq-ui` \| `all` (repeatable). |
| `--local-port <n>` | Override the local port (single service only). |

> 🔒 **Recommended hardening:** since apps reach these services over the
> `meshcaster` Docker network (by container name), the published host ports only
> exist for admin access — which the tunnel provides. Bind them to loopback on
> the server (e.g. `ports: ["127.0.0.1:5432:5432"]`) so nothing is reachable
> from the public internet. The tunnel forwards to the remote's `127.0.0.1`, so
> it keeps working unchanged.
