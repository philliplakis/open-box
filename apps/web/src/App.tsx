import './App.css'

const installMethods = [
  ['brew', 'brew install philliplakis/open-box/openbox', 'coming soon'],
  ['source', 'git clone https://github.com/philliplakis/open-box.git && cd open-box && swift build -c release'],
]

const commands = [
  ['run', 'openbox run --workspace "$PWD" --timeout 300 -- echo ok'],
  ['shell', 'openbox run --workspace "$PWD" --tty -- bash'],
  ['auth', 'openbox run --ssh-agent -- git clone git@github.com:owner/repo.git'],
]

const details = [
  ['Containers', 'Runs commands inside a local container backend instead of the host shell.'],
  ['Pre-built image', 'ghcr.io/philliplakis/open-box ships node, bun, python, uv, git, gh, ripgrep, and common agent CLIs.'],
  ['Workspace', 'Stages privacy-protected folders through /tmp, then syncs successful writes back.'],
  ['Agents', 'Gives coding agents a local Linux sandbox to inspect, edit, build, and test without touching the macOS host.'],
  ['Backends', 'Apple container is first. Docker and OrbStack are next.'],
]

function App() {
  return (
    <main className="site">
      <header className="masthead">
        <a className="wordmark" href="/" aria-label="open-box home">
          open-box
        </a>
        <nav aria-label="Primary">
          <a href="#install">Install</a>
          <a href="#agents">Agents</a>
          <a href="#docs">Docs</a>
          <a href="https://github.com/philliplakis/open-box">GitHub</a>
        </nav>
      </header>

      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-copy">
          <p className="eyebrow">Container-first command runner</p>
          <h1 id="hero-title">Run workspace commands in a local container.</h1>
          <p className="lede">
            open-box starts with Apple container on macOS 26+. Agents get a
            pre-built Linux image, workspace staging, SSH auth, and read-only
            token handoff. Docker and OrbStack backends are next.
          </p>
          <div className="hero-actions" aria-label="Primary actions">
            <a href="#install">Start</a>
            <a href="#agents">Agents</a>
          </div>
        </div>

        <aside className="run-sheet" aria-label="Example sandbox run">
          <div className="sheet-head">
            <span>run sheet</span>
            <span>local</span>
          </div>
          <pre><code>{`$ openbox run -- echo ok
staging workspace /tmp/openbox-4231
mounting tokens read-only
starting ghcr.io/philliplakis/open-box
ok
sync complete`}</code></pre>
        </aside>
      </section>

      <section className="command-strip" id="install" aria-labelledby="install-title">
        <h2 id="install-title">Install and run</h2>
        <div className="command-stack">
          <div className="command-list">
            {installMethods.map(([label, command, note]) => (
              <p key={label}>
                <span>{label}</span>
                <code>
                  {command}
                  {note ? <em className="command-note"> {note}</em> : null}
                </code>
              </p>
            ))}
          </div>
          <div className="command-list">
            {commands.map(([label, command]) => (
              <p key={label}>
                <span>{label}</span>
                <code>{command}</code>
              </p>
            ))}
          </div>
        </div>
      </section>

      <section className="grid-section" id="scope" aria-labelledby="scope-title">
        <h2 id="scope-title">What it handles</h2>
        <div className="detail-grid">
          {details.map(([title, body]) => (
            <article key={title}>
              <h3>{title}</h3>
              <p>{body}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="agents" id="agents" aria-labelledby="agents-title">
        <div>
          <p className="eyebrow">Agent guide</p>
          <h2 id="agents-title">A local sandbox contract for coding agents.</h2>
        </div>
        <pre className="doc-markdown"><code>{`# Tool contract

openbox run --workspace "$PWD" --timeout 300 -- <command> <args>

# Interactive shell
openbox run --workspace "$PWD" --tty -- bash

# Rules
- Use --timeout for non-interactive commands.
- Use --ssh-agent only for git-over-SSH.
- Do not print /run/openbox/tokens.yaml or token values.
- Use --image when a project needs a heavy toolchain.

# Pre-built image includes
node, npm, bun, python3, uv, git, gh, ripgrep, jq, sqlite3

# Language images
openbox run --image docker.io/library/swift:6.3-noble -- swift test
openbox run --image docker.io/library/golang:bookworm -- go test ./...`}</code></pre>
      </section>

      <section className="docs" id="docs" aria-labelledby="docs-title">
        <div>
          <p className="eyebrow">Minimal docs</p>
          <h2 id="docs-title">The whole flow fits in three notes.</h2>
        </div>
        <pre className="doc-markdown"><code>{`# Quick start

## Install
brew install philliplakis/open-box/openbox   # coming soon
Or clone the repo and run swift build -c release.

## Run
openbox run --workspace "$PWD" -- <command>

## Secrets
Allowlisted tokens become env vars and mount read-only at /run/openbox/tokens.yaml.`}</code></pre>
      </section>

      <section className="embed" id="embed" aria-labelledby="embed-title">
        <div>
          <p className="eyebrow">Swift package</p>
          <h2 id="embed-title">Embed the same sandbox runner in your macOS app.</h2>
          <p className="embed-lede">
            Add the package from GitHub, run commands with SandboxRunner, or wire
            a live terminal through SandboxTerminalSession and SwiftTerm.
          </p>
        </div>
        <pre><code>{`// Package.swift
.package(
  url: "https://github.com/philliplakis/open-box.git",
  branch: "main"
)

import OpenBox

let result = try await SandboxRunner().run(
  options: SandboxRunOptions(
    workspace: URL(fileURLWithPath: "/path/to/project"),
    command: ["echo", "hello"]
  )
)

// Live terminal via SwiftTerm
let session = try await SandboxTerminalSession.start(
  options: SandboxRunOptions(
    workspace: projectURL,
    command: ["bash"]
  ),
  columns: 80,
  rows: 24
) { event in
  // handle pull + output events
}`}</code></pre>
      </section>
    </main>
  )
}

export default App
