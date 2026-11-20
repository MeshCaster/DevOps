# Vault Tooling

Host-side scripts to deploy and operate the [Vault stack](../../applications/infrastructure/vault/README.md).
They follow the same conventions as [`tools/infra`](../infra/README.md): the compose
file is streamed over SSH (nothing lands on the server), and secrets ride inside the
streamed script on stdin — never in argv, so they don't show up in `ps` or shell
history.

Run them in order, from the repo root.

## 1. `deploy-vault.sh` — start Vault

Brings up the Vault + unsealer stack on a remote host. Idempotent, holds no secrets.
Vault comes up **sealed**.

```bash
tools/vault/deploy-vault.sh -i ~/.ssh/meshcaster_contabo root@contabo-host
tools/vault/deploy-vault.sh --dry-run root@contabo-host   # preview the remote script
```

| Flag | Description |
|------|-------------|
| `-p <port>` | SSH port (default: `22`). |
| `-i <identity>` | SSH private key file. |
| `--network <name>` | Docker network (default: `meshcaster`). |
| `--compose <path>` | Compose file (default: the repo's Vault stack). |
| `--dry-run` | Print the remote script instead of running it. |

It also creates `/etc/meshcaster/vault` (mode 700) on the host — where the unsealer
looks for its keys.

## 2. `init-vault.sh` — initialize once

Runs `vault operator init`, installs the auto-unseal keys on the host, and prints the
unseal keys + root token **exactly once**. Refuses to touch an already-initialized
Vault.

```bash
tools/vault/init-vault.sh -i ~/.ssh/meshcaster_contabo root@contabo-host
tools/vault/init-vault.sh --no-autounseal root@contabo-host   # manual unseal instead
```

| Flag | Description |
|------|-------------|
| `-p <port>` / `-i <identity>` | SSH port / key. |
| `--shares <n>` | Unseal key shares to generate (default: `5`). |
| `--threshold <n>` | Shares required to unseal (default: `3`). |
| `--no-autounseal` | Don't write keys to the host; unseal by hand after each restart. |

> **Save the output immediately** — it is shown once and stored nowhere. With
> auto-unseal, `threshold` keys are also written to `/etc/meshcaster/vault/keys`
> (root, 0600) so the sidecar can recover after a reboot. Revoke the root token once
> provisioning is done; mint a new one from the unseal keys with
> `vault operator generate-root` when needed.

## 3. `provision-app.sh` — give an app its identity

Creates a KV v2 path, a read-only policy, and an AppRole for one app, then prints its
`VAULT__ROLEID` / `VAULT__SECRETID`. Optionally seeds config values. Needs the root
token in `VAULT_TOKEN` (passed via the environment, never argv).

```bash
# create role + policy + path, print RoleId/SecretId
VAULT_TOKEN=<root> tools/vault/provision-app.sh -i ~/.ssh/key root@host mediathek-api

# also seed / update secret values
VAULT_TOKEN=<root> tools/vault/provision-app.sh -i ~/.ssh/key root@host mediathek-api \
    ConnectionStrings__MediathekDb='Host=meshcaster-postgres;Database=mediathek;Username=postgres;Password=…' \
    Auth__Authority='https://identity.in-vent.online'

# rotate an app's SecretId
VAULT_TOKEN=<root> tools/vault/provision-app.sh --rotate -i ~/.ssh/key root@host mediathek-api
```

| Flag | Description |
|------|-------------|
| `-p <port>` / `-i <identity>` | SSH port / key. |
| `--rotate` | Issue a new SecretId even if the role already exists. |
| `--ttl <dur>` | Token TTL for the app's login (default: `1h`). |
| `--max-ttl <dur>` | Token max TTL (default: `24h`). |

Re-running is safe: the policy and role are rewritten, seeded values are upserted,
and the SecretId is only reissued for a new role or with `--rotate`.

## 4. `migrate-env.sh` — move an app's env file into Vault

For an app that already runs with a host env file (`/opt/meshcaster/<app>.env`), this
copies every `KEY=value` line into `meshcaster/<app>`, reads each value back, logs in
as the app's AppRole to prove it can read them, and only then rewrites the env file to
the four `VAULT__*` bootstrap lines. The original is kept beside it as
`<file>.pre-vault.<timestamp>` for rollback. Values never leave the host and are never
printed — only key names are.

```bash
VAULT_TOKEN=<root> tools/vault/migrate-env.sh --dry-run -i ~/.ssh/key root@host beautybook-api
VAULT_TOKEN=<root> tools/vault/migrate-env.sh -i ~/.ssh/key root@host beautybook-api
```

| Flag | Description |
|------|-------------|
| `-p <port>` / `-i <identity>` | SSH port / key. |
| `--env-file <path>` | Env file on the host (default: `/opt/meshcaster/<app>.env`). |
| `--dry-run` | List the keys that would move; change nothing. |

It creates the app's policy and AppRole itself, so `provision-app.sh` is not needed
first. Values already in Vault are kept; a key in both places takes the env file's
value. Re-running after a migration does nothing.

The app's image must already call `AddMeshCasterVault`. Then **redeploy** it — docker
reads `--env-file` only when it creates the container, so a restart keeps the old
environment. Delete the `.pre-vault.*` backup once the app is up.

The apps wired for this:

| App (Vault path) | Container(s) | Env file |
|------------------|--------------|----------|
| `identity` | `meshcaster-identity` | `/opt/meshcaster/identity.env` |
| `beautybook-api` | `beautybook-api` | `/opt/meshcaster/beautybook-api.env` |
| `beautybook-admin` | `beautybook-admin` | `/opt/meshcaster/beautybook-admin.env` |
| `beautybook-my` | `beautybook-my` | `/opt/meshcaster/beautybook-my.env` |

The two admin consoles get separate paths on purpose: `beautybook-my` is public and must
not be able to read the operator console's `Identity__ClientSecret`.

## 5. `add-admin.sh` — a UI login for managing secrets

Creates a username/password login bound to the `secrets-admin` policy: create, read,
edit and delete secrets under `meshcaster/`, and change its own password. It cannot
touch policies, auth methods, AppRole credentials or seal state, so the root token can
stay in the drawer. Re-running for the same user resets the password.

```bash
VAULT_TOKEN=<root> tools/vault/add-admin.sh -i ~/.ssh/key root@host nugi
```

| Flag | Description |
|------|-------------|
| `-p <port>` / `-i <identity>` | SSH port / key. |
| `--ttl <dur>` | How long a login lasts (default: `8h`). |
| `--length <n>` | Generated password length (default: `24`). |

The password is printed once. To use the UI:

1. `tools/infra/tunnel.sh --service vault -i ~/.ssh/key root@host`
2. Open <http://127.0.0.1:18200/ui>, method **Username**, sign in.
3. **Secrets engines → meshcaster → `<app>`**, then **Create new version** to edit.
   Keys are spelled like environment variables (`ConnectionStrings__BeautyBookDb`).
4. Apply it: `ssh root@host docker restart <container>`. Apps read Vault once at
   startup, so nothing changes until the restart. Vault keeps earlier versions, so a
   bad edit can be rolled back from the same screen.

## Wiring an app

Put the four values into the app's deploy environment (GitHub secrets →
`deploy-container.yml`'s `extra-env`, or a server env-file):

```
VAULT__ADDRESS=http://meshcaster-vault:8200
VAULT__SECRETPATH=mediathek-api
VAULT__ROLEID=…
VAULT__SECRETID=…
```

The app pulls the rest from Vault via
[`MeshCaster.Configuration.Vault`](https://github.com/MeshCaster/MeshCaster.Configuration.Vault).

## Admin access

Vault's port is loopback-only on the host. Forward it with the shared tunnel tool:

```bash
tools/infra/tunnel.sh --service vault -i ~/.ssh/meshcaster_contabo root@contabo-host
# Vault API/UI then at http://127.0.0.1:18200
```
