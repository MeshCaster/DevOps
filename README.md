# Meshcaster DevOps Templates

Reusable GitHub Actions workflows for the Meshcaster organization.

## Available Workflows

| Workflow | File | Description |
|----------|------|-------------|
| npm publish | `npm-publish.yml` | Build and publish to npmjs.com |
| npm publish (GitHub) | `npm-publish-ghp.yml` | Build and publish to GitHub Packages (private) |
| NuGet publish | `nuget-publish.yml` | Build and publish to nuget.org |
| NuGet publish (GitHub) | `nuget-publish-ghp.yml` | Build and publish to GitHub Packages (private) |
| Deploy container | `deploy-container.yml` | Build → push to GHCR → SSH deploy to a **CONTABO** VPS |

## Usage

### npm package (public → npmjs.com)

Add `NPM_TOKEN` to your repo secrets, then create `.github/workflows/publish.yml`:

```yaml
name: Publish
on:
  push:
    tags: ["v*"]

jobs:
  publish:
    uses: Meshcaster/DevOps/.github/workflows/npm-publish.yml@main
    secrets:
      npm-token: ${{ secrets.NPM_TOKEN }}
```

### npm package (private → GitHub Packages)

No extra secrets needed — uses the built-in `GITHUB_TOKEN`:

```yaml
name: Publish
on:
  push:
    tags: ["v*"]

jobs:
  publish:
    uses: Meshcaster/DevOps/.github/workflows/npm-publish-ghp.yml@main
```

### NuGet package (public → nuget.org)

Add `NUGET_API_KEY` to your repo secrets:

```yaml
name: Publish
on:
  push:
    tags: ["v*"]

jobs:
  publish:
    uses: Meshcaster/DevOps/.github/workflows/nuget-publish.yml@main
    with:
      dotnet-version: "8.0.x"
      project-path: src/MyProject
    secrets:
      nuget-api-key: ${{ secrets.NUGET_API_KEY }}
```

### NuGet package (private → GitHub Packages)

```yaml
name: Publish
on:
  push:
    tags: ["v*"]

jobs:
  publish:
    uses: Meshcaster/DevOps/.github/workflows/nuget-publish-ghp.yml@main
    with:
      dotnet-version: "8.0.x"
      project-path: src/MyProject
```

### Deploy a container to CONTABO

Build a Docker image, push it to GHCR, and (re)start the container on a CONTABO
VPS over SSH. Add `CONTABO_HOST`, `CONTABO_USERNAME`, and
`CONTABO_SSH_PRIVATE_KEY` to your repo secrets (see
[`tools/ssh-keys`](tools/ssh-keys/README.md) to mint the key), then:

```yaml
name: Deploy
on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  deploy:
    uses: MeshCaster/DevOps/.github/workflows/deploy-container.yml@main
    with:
      image-name: app-delivery-api
      container-name: app-delivery-api
      host-port: 5000
      container-port: 80
      aspnetcore-environment: Production
      volume-args: "-v /var/www/20kvadrati/uploads:/app/uploads"
    secrets:
      host: ${{ secrets.CONTABO_HOST }}
      username: ${{ secrets.CONTABO_USERNAME }}
      ssh-private-key: ${{ secrets.CONTABO_SSH_PRIVATE_KEY }}
```

## Tools

Host-side tooling lives in [`tools/`](tools/):

| Tool | Description |
|------|-------------|
| [`tools/docker`](tools/docker/README.md) | Bootstrap Docker Engine + Compose on a fresh Linux VPS (local or over SSH). |
| [`tools/nginx`](tools/nginx/README.md) | Containerized nginx reverse proxy with Let's Encrypt SSL + websockets. |
| [`tools/ssh-keys`](tools/ssh-keys/README.md) | Generate provider-scoped SSH deploy keys to migrate apps (Hostinger → CONTABO). |
| [`tools/infra`](tools/infra/README.md) | Deploy the shared Postgres/RabbitMQ/Redis stack to a remote host with generated secrets (no `.env` on the server). |
| [`tools/transfer`](tools/transfer/README.md) | Copy directories (e.g. upload folders) between servers with resumable rsync-over-SSH. |

## Applications

Per-app and shared infrastructure compose stacks live in
[`applications/`](applications/):

| Stack | Description |
|-------|-------------|
| [`applications/infrastructure/common`](applications/infrastructure/common/README.md) | Shared Postgres + RabbitMQ + Redis on the `meshcaster` network. |

## Inputs

### npm workflows

| Input | Default | Description |
|-------|---------|-------------|
| `node-version` | `20` | Node.js version |
| `build-command` | `npm run build` | Build command |
| `working-directory` | `.` | Package directory |
| `registry` | `https://registry.npmjs.org` | Registry URL (npmjs only) |

### NuGet workflows

| Input | Default | Description |
|-------|---------|-------------|
| `dotnet-version` | `8.0.x` | .NET SDK version |
| `project-path` | `.` | Path to .csproj or directory |
| `configuration` | `Release` | Build configuration |
| `nuget-source` | `https://api.nuget.org/v3/index.json` | NuGet source (nuget.org only) |

### Deploy container workflow

| Input | Default | Description |
|-------|---------|-------------|
| `image-name` | — (required) | GHCR image name (without owner). |
| `container-name` | — (required) | Container name on the host. |
| `host-port` | — (required) | Port published on the host. |
| `container-port` | `80` | Port the app listens on inside the container. |
| `aspnetcore-environment` | `Production` | `ASPNETCORE_ENVIRONMENT` value. |
| `volume-args` | `""` | Extra `docker run` volume flags (single line). |
| `extra-env` | `""` | Extra `docker run` `-e` flags (single line). |
| `ssh-port` | `22` | SSH port on the CONTABO host. |

Secrets: `host` (`CONTABO_HOST`), `username` (`CONTABO_USERNAME`),
`ssh-private-key` (`CONTABO_SSH_PRIVATE_KEY`).

## Publishing a new version

From any consumer repo:

```bash
npm version patch   # or minor / major
git push && git push --tags
```

For .NET, tag manually:

```bash
git tag v1.0.0
git push --tags
```
