// Round trip for secrets/load-shell-secrets.zsh (flake check shell-secrets-loader):
// renders fake values with 2password's own env renderer (src/env.ts, the code
// behind `2password env resolve`) and writes the expected bytes as hex.
// Run with bun from a copy of the packaged 2password folder.
import { Effect } from "effect"
import { Env } from "./src/env.ts"
import { writeFileSync } from "node:fs"

const values: Record<string, string> = {
  PLAIN: "abc123XYZ",
  POOL: "key-one,key-two,key-three",
  DOLLAR: "a$HOME$(id)${PATH}b",
  BACKTICK: "x`id`y",
  QUOTES: `he said "hi" it's`,
  BACKSLASH: "C:\\path\\n-not-newline\\",
  NEWLINE: "line1\nline2\rend",
  SPACES: "  padded  ",
  UNICODE: "ключ✓",
  EQUALS: "a=b==c",
}
const names = Object.keys(values)
const template = ["# comment line stays literal", ...names.map((n) => `${n}=op://vault/${n}/credential`), ""].join("\n")
const lookup = (ref: string) => values[ref.split("/")[3]!]!
const result = Effect.runSync(Env.resolveEnv(template, (refs) => Effect.succeed(refs.map((r) => lookup(r) + "\n"))))
const [envFile, expectedFile] = process.argv.slice(2)
writeFileSync(envFile!, result.content)
writeFileSync(expectedFile!, names.map((n) => `${n} ${Buffer.from(values[n]!).toString("hex")}`).join("\n") + "\n")
