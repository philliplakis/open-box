# open-box

Turborepo monorepo.

## Structure

```
open-box/
├── apps/       # Applications (web, api, etc.)
├── packages/   # Shared libraries and config
└── turbo.json
```

## Getting started

Install dependencies:

```bash
bun install
```

Run all apps in dev mode:

```bash
bun dev
```

Build everything:

```bash
bun run build
```

## Adding an app

Create a new directory under `apps/` with its own `package.json`. It will be picked up automatically by the workspace.

## Shared packages

- `@open-box/typescript-config` — shared TypeScript configs (`base`, `nextjs`, `react-library`)

## Apple container sandbox

The embeddable sandbox lives in `packages/openbox`.
It requires macOS 26+ with Apple's `container` CLI available on `PATH`.

Build and test it:

```bash
swift test --package-path packages/openbox
```

Run a command in the sandbox:

```bash
swift run --package-path packages/openbox openbox run -- echo ok
```

The CLI forwards allowlisted local token environment variables into a read-only
YAML file at `/run/openbox/tokens.yaml` inside the container. Defaults:
`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `GITHUB_TOKEN`, and
`GH_TOKEN`.

Apple's container runtime can hang when VirtioFS directly mounts macOS privacy
protected folders such as `~/Documents`. The sandbox stages those workspaces
through `/tmp` automatically and syncs successful writes back after the command
exits.

The base image is built from `sandbox/Dockerfile` and published by
`.github/workflows/openbox-image.yml` to
`ghcr.io/philliplakis/open-box`.
