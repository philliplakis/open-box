# OpenBox CLI

`openbox` runs commands inside an Apple-container-backed Linux sandbox on macOS.

## Requirements

- macOS 26+
- Apple Silicon
- Swift toolchain if installing from source
- Apple's `container` CLI available on `PATH`

Check the container runtime:

```bash
container system start
container run --rm docker.io/library/alpine:latest echo ok
```

## Install

From this repo:

```bash
git clone https://github.com/philliplakis/open-box.git
cd open-box
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/openbox ~/.local/bin/openbox
```

Make sure `~/.local/bin` is on `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
openbox --help
```

With Homebrew (preferred):

```bash
brew install philliplakis/open-box/openbox
```

Or tap once, then use the bare formula name:

```bash
brew tap philliplakis/open-box
brew install openbox
```

See [Homebrew tap](homebrew.md) for release and tap setup details.

## Run Commands

Run in the current directory:

```bash
openbox run -- echo ok
```

Run in another workspace:

```bash
openbox run --workspace ~/src/my-app -- npm test
```

Limit runtime:

```bash
openbox run --image docker.io/library/swift:6.3-noble --timeout 120 -- swift test
```

Stop a command that produces no output for too long:

```bash
openbox run --idle-timeout 300 -- npm run build
```

Open a shell:

```bash
openbox run --tty -- bash
```

Use more resources:

```bash
openbox run --cpus 8 --memory 8G -- make test
```

Use a named container when you want to inspect or stop it:

```bash
openbox run --name my-job --keep -- sleep 600
openbox status my-job
openbox stop my-job
```

Stop leaked `openbox-*` containers and clean stopped containers:

```bash
openbox cache clean
```

## Secrets

By default, OpenBox forwards these host environment variables into the
container when they are set, and also writes them into a read-only YAML file at
`/run/openbox/tokens.yaml`:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `GOOGLE_API_KEY`
- `GITHUB_TOKEN`
- `GH_TOKEN`

If `GH_TOKEN` is not set but the GitHub CLI is authenticated on the host,
OpenBox uses `gh auth token` automatically.

Add another env var:

```bash
MY_SERVICE_TOKEN=... openbox run --env MY_SERVICE_TOKEN -- printenv MY_SERVICE_TOKEN
```

Disable defaults and pass only explicit names:

```bash
openbox run --no-default-env --env GITHUB_TOKEN -- gh auth status
```

Do not print token values in logs. Treat environment tokens and
`/run/openbox/tokens.yaml` as secret material.

## GitHub and SSH

Forward your host SSH agent for git-over-SSH:

```bash
openbox run --ssh-agent -- git ls-remote git@github.com:philliplakis/private-repo.git
```

`--ssh-agent` forwards auth only. It does not run SSH login into the container.
For local terminal access, use `--tty -- bash`.

For private GHCR images, authenticate with the registry before pulling the
default image, or pass an image you can already pull:

```bash
openbox run --image docker.io/library/alpine:latest -- echo ok
```

## Mounts

Mount another host directory:

```bash
openbox run --mount ~/data:/data:ro -- python3 script.py
```

Format:

```text
hostpath:containerpath[:ro|rw]
```

The main workspace is mounted at `/workspace`. If the workspace is under a
macOS privacy-protected folder such as `~/Documents`, OpenBox stages it through
`/tmp` and syncs changes back after the command exits. Extra mounts are passed
through directly, so prefer non-protected paths for extra mounts.

## Exit Codes

`openbox run` exits with the sandboxed command's exit code.

Completed commands sync workspace changes back, even when they exit non-zero.
Timed-out commands are stopped and do not sync staged workspace changes back.
