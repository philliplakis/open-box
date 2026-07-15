import { cpSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const root = join(import.meta.dir, "..")
const fixture = join(root, "fixtures", "bun-agent")
const workspace = mkdtempSync(join(tmpdir(), "openbox-agent-smoke-"))
const openbox = process.env.OPENBOX_BIN ?? join(root, ".build", "arm64-apple-macosx", "release", "openbox")

const apiKey = process.env.OPENAI_API_KEY
if (!apiKey) throw new Error("OPENAI_API_KEY is required")

function command(arguments_: string[]) {
  const result = Bun.spawnSync([openbox, ...arguments_], { cwd: root, stdout: "pipe", stderr: "pipe" })
  const output = `${result.stdout.toString()}${result.stderr.toString()}`.trim()
  if (result.exitCode !== 0) throw new Error(`${openbox} ${arguments_.join(" ")}\n${output}`)
}

cpSync(fixture, workspace, { recursive: true })
try {
  const agent = Bun.spawnSync([
    "codex", "exec", "--ignore-user-config", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "--ephemeral", "-m", "gpt-5.4-mini",
    "The Bun project has a failing test. Inspect the files, fix the bug, and run bun test. Do not change package.json.",
  ], { cwd: workspace, stdout: "pipe", stderr: "pipe", env: { ...process.env, CODEX_API_KEY: apiKey } })
  if (agent.exitCode !== 0) throw new Error(`${agent.stdout.toString()}${agent.stderr.toString()}`.trim())
  command(["run", "--no-default-env", "--workspace", workspace, "--timeout", "300", "--", "bun", "test"])
  console.log("agent smoke passed")
} finally {
  rmSync(workspace, { recursive: true, force: true })
}
