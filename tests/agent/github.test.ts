import { expect, test } from "bun:test"
import { join } from "node:path"

test("GitHub authentication crosses openbox run", async () => {
  const root = join(import.meta.dir, "..", "..")
  const openbox = process.env.OPENBOX_BIN ?? join(root, ".build", "arm64-apple-macosx", "release", "openbox")
  const run = Bun.spawn([openbox, "run", "--workspace", "/tmp", "--timeout", "300", "--", "gh", "api", "user", "--jq", ".login"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  })
  expect(await run.exited).toBe(0)
}, 180_000)
