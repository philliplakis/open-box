import { expect, test } from "bun:test"
import { join } from "node:path"

test("the API agent repairs a Bun project in a managed box", async () => {
  const root = join(import.meta.dir, "..", "..")
  const run = Bun.spawn([Bun.which("bun") ?? "bun", "scripts/api-agent-smoke.ts"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  })
  expect(await run.exited).toBe(0)
}, 180_000)
