import { cpSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const root = join(import.meta.dir, "..")
const fixture = join(root, "fixtures", "bun-agent")
const workspacePath = mkdtempSync(join(tmpdir(), "openbox-api-smoke-"))
cpSync(fixture, workspacePath, { recursive: true })
const openbox = process.env.OPENBOX_BIN ?? join(root, ".build", "arm64-apple-macosx", "release", "openbox")
const apiKey = process.env.OPENAI_API_KEY

if (!apiKey) throw new Error("OPENAI_API_KEY is required")

function command(arguments_: string[], cwd = root) {
  const result = Bun.spawnSync([openbox, ...arguments_], { cwd, stdout: "pipe", stderr: "pipe" })
  const output = `${result.stdout.toString()}${result.stderr.toString()}`.trim()
  if (result.exitCode !== 0) throw new Error(`${openbox} ${arguments_.join(" ")}\n${output}`)
  return output
}

async function response(input: unknown[]) {
  const result = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-5.4-nano",
      reasoning: { effort: "low" },
      input,
      tools: [{
        type: "function",
        name: "run_shell",
        description: "Run a shell command in the Bun project. Use it to inspect, edit, and test the project.",
        parameters: {
          type: "object",
          properties: { command: { type: "string" } },
          required: ["command"],
          additionalProperties: false,
        },
        strict: true,
      }],
    }),
  })
  if (!result.ok) throw new Error(`OpenAI API: ${result.status} ${await result.text()}`)
  return await result.json() as { output: Array<{ type: string; call_id?: string; arguments?: string }> }
}

const workspace = JSON.parse(command(["workspace", "add", workspacePath, "--name", `api-smoke-${Date.now()}`])) as { id: string }
let box: { id: string } | undefined

try {
  box = JSON.parse(command(["box", "create", "--workspace", workspace.id, "--image", "oven/bun:1", "--ttl", "300"])) as { id: string }
  let input: unknown[] = [{ role: "user", content: "The Bun project in /workspace has a failing test. Use the shell to inspect the files, fix the bug, and rerun bun test. Do not change package.json." }]

  for (let turn = 0; turn < 8; turn++) {
    const result = await response(input)
    const calls = result.output.filter((item) => item.type === "function_call")
    if (calls.length === 0) break
    input.push(...result.output)
    for (const call of calls) {
      const { command: shell } = JSON.parse(call.arguments ?? "{}") as { command?: string }
      if (!shell || !call.call_id) throw new Error("agent returned an invalid shell call")
      const run = Bun.spawnSync([openbox, "box", "exec", box.id, "--", "sh", "-lc", shell], { cwd: workspacePath, stdout: "pipe", stderr: "pipe" })
      input.push({ type: "function_call_output", call_id: call.call_id, output: `${run.stdout.toString()}${run.stderr.toString()}`.slice(-12_000) })
    }
  }

  command(["box", "exec", box.id, "--", "bun", "test"], workspacePath)
  console.log("API agent smoke passed")
} finally {
  if (box) try { command(["box", "delete", box.id]) } catch {}
  try { command(["workspace", "remove", workspace.id]) } catch {}
  rmSync(workspacePath, { recursive: true, force: true })
}
