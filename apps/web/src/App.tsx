import './App.css'

const commands = [
  ['run', 'swift run openbox run -- echo ok'],
  ['shell', 'swift run openbox run --tty -- bash'],
  ['auth', 'swift run openbox run --ssh-agent -- git clone git@github.com:owner/repo.git'],
]

const details = [
  ['Containers', 'Runs commands inside a local container backend instead of the host shell.'],
  ['Workspace', 'Stages privacy-protected folders through /tmp, then syncs successful writes back.'],
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
          <a href="#docs">Docs</a>
          <a href="https://github.com/philliplakis/open-box">GitHub</a>
        </nav>
      </header>

      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-copy">
          <p className="eyebrow">Container-first command runner</p>
          <h1 id="hero-title">Run workspace commands in a local container.</h1>
          <p className="lede">
            open-box starts with Apple container on macOS 26+. Docker and
            OrbStack backends are next, with the same workspace staging, SSH
            auth, and read-only token handoff.
          </p>
          <div className="hero-actions" aria-label="Primary actions">
            <a href="#install">Start</a>
            <a href="#docs">Docs</a>
          </div>
        </div>

        <aside className="run-sheet" aria-label="Example sandbox run">
          <div className="sheet-head">
            <span>run sheet</span>
            <span>local</span>
          </div>
          <pre><code>{`$ swift run openbox run -- echo ok
staging workspace /tmp/openbox-4231
mounting tokens read-only
starting ghcr.io/philliplakis/open-box
ok
sync complete`}</code></pre>
        </aside>
      </section>

      <section className="command-strip" id="install" aria-labelledby="install-title">
        <h2 id="install-title">Use it from the terminal</h2>
        <div className="command-list">
          {commands.map(([label, command]) => (
            <p key={label}>
              <span>{label}</span>
              <code>{command}</code>
            </p>
          ))}
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

      <section className="docs" id="docs" aria-labelledby="docs-title">
        <div>
          <p className="eyebrow">Minimal docs</p>
          <h2 id="docs-title">The whole flow fits in three notes.</h2>
        </div>
        <pre className="doc-markdown"><code>{`# Quick start

## Install
Add the Swift package or clone the repo, then run swift test.

## Run
swift run openbox run -- <command>

## Secrets
Allowlisted tokens become env vars and mount read-only at /run/openbox/tokens.yaml.`}</code></pre>
      </section>

      <section className="embed" id="embed" aria-labelledby="embed-title">
        <div>
          <p className="eyebrow">Swift package</p>
          <h2 id="embed-title">Embed the same sandbox runner in your app.</h2>
        </div>
        <pre><code>{`import OpenBox

let result = try await SandboxRunner().run(
  options: SandboxRunOptions(
    workspace: URL(fileURLWithPath: "/path/to/project"),
    command: ["echo", "hello"]
  )
)`}</code></pre>
      </section>
    </main>
  )
}

export default App
