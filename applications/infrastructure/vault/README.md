# Vault — secret store for MeshCaster apps

HashiCorp Vault is the single source of truth for application secrets on the host.
Apps authenticate with **AppRole** over the shared `meshcaster` Docker network and
read their configuration from the `meshcaster/` **KV v2** mount at startup (via the
[`MeshCaster.Configuration.Vault`](https://github.com/MeshCaster/MeshCaster.Configuration.Vault)
NuGet package), so a deploy no longer needs a per-app `.env` file or secrets baked
into the image.

This stack runs alongside [`applications/infrastructure/common`](../common/README.md)
(Postgres + RabbitMQ + Redis) on the same network.

## What's in the stack

| Service | Container | Purpose |
|---------|-----------|---------|
| `vault` | `meshcaster-vault` | Vault server, raft storage, KV v2 + AppRole. API on `:8200` (loopback only). |
| `unsealer` | `meshcaster-vault-unsealer` | Sidecar that unseals Vault after a restart using keys at `/etc/meshcaster/vault/keys`. |

Vault's entire configuration lives in `VAULT_LOCAL_CONFIG` inside the compose file —
the image writes it to `/vault/config/local.json` and runs `vault server`, so **no
config file is ever copied to the host**.

## Deploy

From the repo root, using the tooling in [`tools/vault`](../../../tools/vault/README.md):

```bash
# 1. Start Vault (idempotent, holds no secrets). It comes up SEALED.
tools/vault/deploy-vault.sh -i ~/.ssh/meshcaster_contabo root@contabo-host

# 2. Initialize ONCE. Prints unseal keys + root token, installs auto-unseal keys.
tools/vault/init-vault.sh   -i ~/.ssh/meshcaster_contabo root@contabo-host

# 3. Provision an app: creates its KV path, policy, and AppRole; prints RoleId/SecretId.
VAULT_TOKEN=<root> tools/vault/provision-app.sh -i ~/.ssh/meshcaster_contabo \
    root@contabo-host mediathek-api \
    ConnectionStrings__MediathekDb='Host=meshcaster-postgres;Database=mediathek;Username=postgres;Password=…' \
    Auth__Authority='https://identity.in-vent.online'
```

Then wire the printed `VAULT__ROLEID` / `VAULT__SECRETID` (plus
`VAULT__ADDRESS=http://meshcaster-vault:8200` and `VAULT__SECRETPATH=<app>`) into the
app's deploy environment. See the package README for the app side.

## Auto-unseal, and the tradeoff

Vault boots **sealed** and answers nothing until unsealed. The `unsealer` sidecar
watches for that and applies the keys from `/etc/meshcaster/vault/keys` (root-owned,
mode 600), so a host reboot brings every app back with no human in the loop.

The price is that those unseal keys sit on the host. Anyone who can read that file
can unseal Vault — so **host security is what ultimately protects Vault**. This is not
weaker than the status quo (root can already read any `.env` and `docker inspect`
every password); it adds central control, audit logging, per-app scoping, and
rotation on top. To opt out and unseal by hand after every restart, initialize with
`init-vault.sh --no-autounseal`.

## Admin access

Vault's port is published on **loopback only** (`127.0.0.1:8200`) — never to the
public internet. Apps reach it over the `meshcaster` network by container name. For
admin access (CLI or the web UI), forward it over SSH:

```bash
tools/infra/tunnel.sh --service vault -i ~/.ssh/meshcaster_contabo root@contabo-host
# then:
export VAULT_ADDR=http://127.0.0.1:18200
vault login <root-token>
open http://127.0.0.1:18200/ui
```

## Backups

The raft storage lives in the `meshcaster_vault` volume. Snapshot it with a token
that has the `sys/storage/raft/snapshot` capability:

```bash
ssh root@host "docker exec -e VAULT_TOKEN=<token> meshcaster-vault \
    vault operator raft snapshot save /tmp/vault.snap && docker cp meshcaster-vault:/tmp/vault.snap -" \
    > vault-$(date +%F).snap
```

## Local development

Prefer a throwaway dev-mode Vault for local work — it starts unsealed with a known
root token and an in-memory KV mount:

```bash
docker run --rm -p 8200:8200 -e VAULT_DEV_ROOT_TOKEN_ID=dev hashicorp/vault:2.0.3
```

To instead run *this* stack locally, provide a key directory for the unsealer via a
compose override (the production path `/etc/meshcaster/vault` is root-owned):

```yaml
# docker-compose.override.yml
services:
  unsealer:
    volumes:
      - ./.vault-keys:/unseal:ro
```

> ⚠️ **Never commit unseal keys or the root token.** `.vault-keys/` is for local
> throwaway instances only.
