# SSH Deploy Key Toolkit

`gen-keys.sh` generates and manages **provider-scoped SSH deploy keypairs** on
your laptop, so moving an app between VPS providers (e.g. **Hostinger →
CONTABO**) is a clean swap instead of a scramble.

One keypair per provider, with predictable names under `~/.ssh`:

| File | Purpose |
|------|---------|
| `~/.ssh/meshcaster_contabo` | **Private** key → goes into `CONTABO_SSH_PRIVATE_KEY` GitHub secret |
| `~/.ssh/meshcaster_contabo.pub` | **Public** key → goes into the CONTABO server's `authorized_keys` |
| `~/.ssh/meshcaster_hostinger` | Old host's private key — kept for rollback |
| `~/.ssh/meshcaster_hostinger.pub` | Old host's public key |

Keys are `ed25519` with no passphrase (deploy keys used non-interactively by CI).

> ⚠️ Private keys live in `~/.ssh`, never in this repo. The `.gitignore` here
> ensures nothing but the script and docs is ever committed.

## Usage

```bash
# Generate the CONTABO deploy key and print the public half
tools/ssh-keys/gen-keys.sh --provider contabo --print

# Generate keys for every known provider (contabo + hostinger)
tools/ssh-keys/gen-keys.sh --all

# Re-print an existing public key (safe — won't overwrite)
tools/ssh-keys/gen-keys.sh --provider contabo --print

# Rotate a key (overwrites the old one)
tools/ssh-keys/gen-keys.sh --provider contabo --force --print
```

| Flag | Description |
|------|-------------|
| `--provider <name>` | Provider to generate a key for (e.g. `contabo`, `hostinger`). |
| `--all` | Generate keys for every provider in the default set. |
| `--repo <owner/name>` | GitHub repo to target in the printed `gh secret set` commands. |
| `--comment <c>` | Key comment (default: `meshcaster-<provider>`). |
| `--force` | Overwrite an existing key of the same name (key rotation). |
| `--print` | Print the public key(s) after generating (or if they already exist). |
| `-h`, `--help` | Show help. |

## Migrating an app from Hostinger to CONTABO

1. **Mint the CONTABO key** on your laptop:

   ```bash
   tools/ssh-keys/gen-keys.sh --provider contabo --print
   ```

2. **Authorize it on the CONTABO server:**

   ```bash
   ssh-copy-id -i ~/.ssh/meshcaster_contabo.pub <user>@<contabo-host>
   ```

3. **Load the secrets into the app repo** (uses the [`gh`](https://cli.github.com) CLI).
   `gh secret set` targets the repo of your **current directory's** `origin`
   remote — so either `cd` into the app's clone first, or pass `-R owner/name`
   explicitly (which `--print --repo` prints for you):

   ```bash
   gh secret set -R MeshCaster/Cafe.Api CONTABO_SSH_PRIVATE_KEY < ~/.ssh/meshcaster_contabo
   gh secret set -R MeshCaster/Cafe.Api CONTABO_HOST     --body "<contabo-host-or-ip>"
   gh secret set -R MeshCaster/Cafe.Api CONTABO_USERNAME --body "<ssh-user>"
   ```

4. **Deploy.** The app's workflow calls the shared
   [`deploy-container.yml`](../../.github/workflows/deploy-container.yml) reusable
   workflow, which SSHes into CONTABO with these secrets and (re)starts the
   container from a freshly-built image.

5. Once CONTABO is verified, the old `meshcaster_hostinger` key can stay for
   rollback or be removed from the old server's `authorized_keys`.
