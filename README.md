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
