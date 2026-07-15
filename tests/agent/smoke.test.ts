import { expect, test } from "bun:test"
import { join } from "node:path"

const agentTest = process.env.OPENBOX_AGENT_TESTS === "1" ? test : test.skip

agentTest("an agent repairs a Bun project in a managed box", async () => {
  const root = join(import.meta.dir, "..", "..")
  const run = Bun.spawn([Bun.which("bun") ?? "bun", "scripts/agent-smoke.ts"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  })
  expect(await run.exited).toBe(0)
}, 180_000)
