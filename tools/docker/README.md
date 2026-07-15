# Docker Setup Tool

`setup-docker.sh` bootstraps **Docker Engine + Compose v2** on a fresh Linux
host from Docker's official repositories.

It installs `docker-ce`, `docker-ce-cli`, `containerd.io`, the Buildx plugin and
the Compose plugin, enables the `docker` service, and adds your user to the
`docker` group so you can run Docker without `sudo`.

## Supported hosts

| Family | Distros | Package manager |
|--------|---------|-----------------|
| Debian | Debian, Ubuntu | `apt` |
| RHEL   | CentOS, RHEL, Rocky, Alma, Fedora | `dnf` |

macOS / Windows are not supported — use [Docker Desktop](https://docs.docker.com/desktop/) there.

## Usage

```bash
# from a host with sudo
curl -fsSL https://raw.githubusercontent.com/MeshCaster/DevOps/main/tools/docker/setup-docker.sh -o setup-docker.sh
chmod +x setup-docker.sh
./setup-docker.sh
```

Or clone the repo and run it directly:

```bash
tools/docker/setup-docker.sh
```

### Options

| Flag | Description |
|------|-------------|
| `--no-usermod` | Don't add any user to the `docker` group. |
| `--user <name>` | User to add to the `docker` group (default: `$SUDO_USER` or the current user). |
| `--dry-run` | Print the commands that would run without executing them. |
| `-h`, `--help` | Show help. |

### Examples

```bash
# See exactly what it will do, without changing anything
./setup-docker.sh --dry-run

# Install for a specific service account
sudo ./setup-docker.sh --user deploy

# Install without touching group membership (e.g. rootless setups)
sudo ./setup-docker.sh --no-usermod
```

## Running on a remote VPS (no git/download on the host)

`remote-setup.sh` streams `setup-docker.sh` into the remote shell over SSH, so
the target host needs nothing but SSH access and a sudo-capable user — no git,
no `curl`, and no leftover files on the remote.

```bash
# dry-run against a host first
tools/docker/remote-setup.sh root@vps1 -- --dry-run

# real run
tools/docker/remote-setup.sh root@vps1

# custom port, key, and a service user
tools/docker/remote-setup.sh -p 2222 -i ~/.ssh/vps1 deploy@vps1 -- --user deploy
```

| Flag | Description |
|------|-------------|
| `-p <port>` | SSH port (default: `22`). |
| `-i <identity>` | SSH private key file. |
| Args after `--` | Forwarded verbatim to `setup-docker.sh` (e.g. `--dry-run`, `--user`, `--no-usermod`). |

## After install

Group membership takes effect on your next login. To apply it immediately:

```bash
newgrp docker
```

Verify the install:

```bash
docker run --rm hello-world
docker compose version
```
