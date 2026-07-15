import { expect, test } from "bun:test"
import { join } from "node:path"

test("Codex repairs a Bun project in an OpenBox sandbox", async () => {
  const root = join(import.meta.dir, "..", "..")
  const run = Bun.spawn([Bun.which("bun") ?? "bun", "tests/agent/codex-smoke.ts"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  })
  expect(await run.exited).toBe(0)
}, 180_000)
