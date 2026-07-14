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

The embeddable Swift package is exposed from the repo root.
It requires macOS 26+ with Apple's `container` CLI available on `PATH`.

Detailed docs:

- [CLI usage](docs/cli.md)
- [Agent guide](docs/agents.md)
- [Homebrew tap](docs/homebrew.md)

Install the CLI with Homebrew:

```bash
brew install philliplakis/open-box/openbox
```

Or after tapping once:

```bash
brew tap philliplakis/open-box
brew install openbox
```

Import from GitHub:

```swift
.package(url: "https://github.com/philliplakis/open-box.git", branch: "main")
```

Use from Swift:

```swift
import OpenBox

let result = try await SandboxRunner().run(
    options: SandboxRunOptions(
        workspace: URL(fileURLWithPath: "/path/to/project"),
        command: ["echo", "hello"]
    )
)

print(result.stdout)
```

Report image pulls and live process output:

```swift
let runner = SandboxRunner(eventHandler: { event in
    switch event {
    case .pullingImage(let image):
        print("Pulling \(image)...")
    case .output(.stdout(let data)):
        FileHandle.standardOutput.write(data)
    case .output(.stderr(let data)):
        FileHandle.standardError.write(data)
    }
})

let result = try await runner.run(
    options: SandboxRunOptions(command: ["echo", "hello"])
)
```

OpenBox pulls the image before starting the sandbox when it is not already
available locally. The callback receives the `pullingImage` event first, then
the plain pull output as stderr/stdout events.

Build and test it:

```bash
swift test
```

Run a command in the sandbox:

```bash
swift run openbox run -- echo ok
```

Open an interactive shell:

```bash
swift run openbox run --tty -- bash
```

Use a SwiftTerm view from a macOS app:

```swift
import OpenBox
import SwiftTerm

let session = try await SandboxTerminalSession.start(
    options: SandboxRunOptions(
        workspace: projectURL,
        command: ["bash"],
        removeWhenStopped: true
    ),
    columns: 80,
    rows: 24
) { event in
    if case .pullingImage(let image) = event {
        terminalView.feed(Data("Pulling \(image)...\r\n".utf8))
    }
}

Task {
    for await data in session.output {
        terminalView.feed(data)
    }
}

// Call from SwiftTerm's input callback.
try session.write(inputData)

// Call when the terminal view resizes.
try session.resize(columns: columns, rows: rows)
```

OpenBox owns the PTY/container bridge. Your app owns SwiftTerm, so OpenBox does
not force a UI dependency on CLI users.

Forward your host SSH agent for GitHub SSH auth:

```bash
swift run openbox run --ssh-agent -- git clone git@github.com:philliplakis/private-repo.git
```

`--ssh-agent` is for auth forwarding, not SSH login into the container. For
local terminal access, use `--tty -- sh` or `--tty -- bash` instead of running
`sshd`.

The CLI forwards allowlisted local token environment variables into the
container, and also writes them into a read-only YAML file at
`/run/openbox/tokens.yaml`. Defaults:
`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `GITHUB_TOKEN`, and
`GH_TOKEN`. If `GH_TOKEN` is not set but the host GitHub CLI is authenticated,
OpenBox fills it from `gh auth token`.

Apple's container runtime can hang when VirtioFS directly mounts macOS privacy
protected folders such as `~/Documents`. The sandbox stages those workspaces
through `/tmp` automatically and syncs successful writes back after the command
exits.

The base image is built from `sandbox/Dockerfile` and published by
`.github/workflows/openbox-image.yml` to
`ghcr.io/philliplakis/open-box`.
