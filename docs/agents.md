# Agent Guide

Use `openbox` when an agent needs a local Linux sandbox to inspect, edit, build,
or test a project without running directly on the macOS host.

## Tool Contract

Assume this command is available on `PATH`:

```bash
openbox
```

Verify once:

```bash
openbox run --image docker.io/library/alpine:latest -- echo ok
```

Default pattern:

```bash
openbox run --workspace "$PWD" --timeout 300 -- <command> <args>
```

For interactive investigation:

```bash
openbox run --workspace "$PWD" --tty -- bash
```

## Agent Rules

- Use `--timeout` for non-interactive commands.
- Use `--workspace "$PWD"` unless the user points at another project.
- Use `--ssh-agent` only when git-over-SSH is required.
- Do not run `sshd`; use `--tty -- bash` for terminal access.
- Do not print `/run/openbox/tokens.yaml` or token values.
- Prefer a single purposeful command over starting background services.
- Use `--name` only when you need `openbox status` or `openbox stop`.

## Installed Tools

The default OpenBox image includes:

- JavaScript/TypeScript: `node`, `npm`, `npx`, `bun`
- Python: `python3`, `uv`, `uvx`
- Shell: `bash`, `zsh`, POSIX tools
- Data/dev tools: `sqlite3`, `jq`, `ripgrep`, `git`, `gh`

Heavy language toolchains are intentionally not bundled in the default image.
Use `--image` when a project needs one:

```bash
openbox run --image docker.io/library/swift:6.3-noble --workspace "$PWD" --timeout 600 -- swift test
openbox run --image docker.io/library/golang:bookworm --workspace "$PWD" --timeout 600 -- go test ./...
openbox run --image docker.io/library/rust:bookworm --workspace "$PWD" --timeout 600 -- cargo test
```

## Common Tasks

Run Swift tests:

```bash
openbox run --image docker.io/library/swift:6.3-noble --workspace "$PWD" --timeout 600 -- swift test
```

Run Node/npm checks:

```bash
openbox run --workspace "$PWD" --timeout 600 -- npm test
```

Run Bun checks:

```bash
openbox run --workspace "$PWD" --timeout 600 -- bun test
```

Run Python:

```bash
openbox run --workspace "$PWD" --timeout 300 -- python3 script.py
```

Run Python tooling with uv:

```bash
openbox run --workspace "$PWD" --timeout 300 -- uv run python script.py
```

Run Go:

```bash
openbox run --image docker.io/library/golang:bookworm --workspace "$PWD" --timeout 600 -- go test ./...
```

Run Rust:

```bash
openbox run --image docker.io/library/rust:bookworm --workspace "$PWD" --timeout 600 -- cargo test
```

Build C/C++ with make:

```bash
openbox run --image docker.io/library/gcc:bookworm --workspace "$PWD" --timeout 600 -- make test
```

Query SQLite:

```bash
openbox run --workspace "$PWD" --timeout 120 -- sqlite3 app.db '.tables'
```

Clone a private repo with the host SSH agent:

```bash
openbox run --ssh-agent --timeout 300 -- git clone git@github.com:OWNER/REPO.git
```

Use GitHub token-based tools:

```bash
GITHUB_TOKEN=... openbox run --env GITHUB_TOKEN --timeout 120 -- gh auth status
```

Open a shell for manual work:

```bash
openbox run --workspace "$PWD" --tty -- bash
```

## Prompt Snippet

Give this to agents that are allowed to use OpenBox:

```text
You may use `openbox run` to execute commands inside a local Linux sandbox.
Use `openbox run --workspace "$PWD" --timeout <seconds> -- <command>` for
non-interactive work. Use `openbox run --tty -- bash` only when an interactive
terminal is required. Use `--ssh-agent` only for git-over-SSH. Never print token
values or `/run/openbox/tokens.yaml`.
```

## Failure Recovery

List running containers:

```bash
container ls
```

Stop a named OpenBox container:

```bash
openbox stop <name>
```

Stop leaked `openbox-*` containers and clean stopped containers:

```bash
openbox cache clean
```

If Apple containers hang during startup, first verify the runtime outside
OpenBox:

```bash
container system start
container run --rm docker.io/library/alpine:latest echo ok
```
