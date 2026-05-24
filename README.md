# Meshcaster DevOps Templates

Reusable GitHub Actions workflows for the Meshcaster organization.

## Available Workflows

| Workflow | File | Description |
|----------|------|-------------|
| npm publish | `npm-publish.yml` | Build and publish to npmjs.com |
| npm publish (GitHub) | `npm-publish-ghp.yml` | Build and publish to GitHub Packages (private) |
| NuGet publish | `nuget-publish.yml` | Build and publish to nuget.org |
| NuGet publish (GitHub) | `nuget-publish-ghp.yml` | Build and publish to GitHub Packages (private) |

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
