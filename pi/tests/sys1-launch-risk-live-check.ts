// Live check (paid, about $0.002): the extension's real Clef request reproduces the offline eval scores.
// Run: bun ~/.pi/agent/tests/sys1-launch-risk-live-check.ts
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "/Users/tothemoon/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/index.js";
import { assess } from "../extensions/sys1-launch-risk.ts";

const art = join(homedir(), ".pi/artifacts");
const launches = readFileSync(join(art, "scout/sys1-retro/launches.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
const offline = readFileSync(join(art, "clef/clef-launch-answers.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l))
	.filter((a) => a.model === "clef" && a.answers);
const risk = (a: { answers: { outcome: { probabilities: { complete: number } } } }) => 1 - a.answers.outcome.probabilities.complete;
// highest, median, and lowest offline risk
const sorted = [...offline].sort((a, b) => risk(b) - risk(a));
const picks = [sorted[0], sorted[Math.floor(sorted.length / 2)], sorted.at(-1)];

const rt = await ModelRuntime.create({ allowModelNetwork: false, refreshOnCreate: false });
const ctx = { modelRegistry: { findOfType: rt.getModelOfType.bind(rt), classify: rt.classify.bind(rt) } } as never;
let failed = 0;
for (const a of picks) {
	const row = launches.find((r) => r.session === a.session && r.name === a.name && r.ts === a.ts);
	const live = await assess(ctx, { name: row.name, agent: row.agent, task: row.task }, row.batch_size);
	const diff = Math.abs((live.risk ?? Number.NaN) - risk(a));
	const ok = diff <= 0.03;
	if (!ok) failed++;
	console.log(`${ok ? "ok  " : "FAIL"} ${row.name}: offline ${risk(a).toFixed(3)} live ${live.risk?.toFixed(3)} diff ${diff.toFixed(3)} ${live.ms}ms $${live.usage?.cost?.total?.toFixed(5)} ${live.error ?? ""}`);
}
process.exit(failed ? 1 : 0);
