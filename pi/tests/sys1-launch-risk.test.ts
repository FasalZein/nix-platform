import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

// Redirect the log and agent dir before the module reads homedir().
const home = mkdtempSync(join(tmpdir(), "sys1-launch-risk-"));
process.env.HOME = home;
const mod = await import("../extensions/sys1-launch-risk.ts");
const { launchesOf, noteFor, RISK_THRESHOLD, LOG_PATH } = mod;

type Classify = (model: unknown, context: unknown) => Promise<unknown>;

function harness(classify: Classify | undefined) {
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	mod.default({ on: (name: string, handler: never) => handlers.set(name, handler) } as never);
	const ctx = {
		sessionManager: { getSessionId: () => "test-session" },
		modelRegistry: {
			findOfType: () => (classify ? { provider: "cloudflare-workers-ai", id: "@cf/cloudflare/clef" } : undefined),
			classify: (model: unknown, context: unknown) => classify!(model, context),
		},
	};
	return async (input: Record<string, unknown>, result: Record<string, unknown> = {}) => {
		const id = `call-${Math.random()}`;
		await handlers.get("tool_call")!({ toolName: "subagent", toolCallId: id, input }, ctx);
		return handlers.get("tool_result")!(
			{ toolName: "subagent", toolCallId: id, input, content: [{ type: "text", text: "launched" }], isError: false, ...result },
			ctx,
		) as Promise<{ content?: { text: string }[]; usage?: { cost: { total: number } } } | undefined>;
	};
}

const answer = (complete: number) => async () => ({
	stopReason: "stop",
	answers: { outcome: { type: "choice", choice: "x", confidence: 0, probabilities: { complete, partial: 1 - complete, blocked: 0 } } },
	usage: { input: 2000, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 2000, cost: { input: 0.00048, output: 0, cacheRead: 0, cacheWrite: 0, total: 0.00048 } },
});

const single = { agent: "worker", name: "big-audit", title: "t", task: "Audit every module." };

test("launchesOf reads single launches and batches, and skips a call without agent or task", () => {
	assert.deepEqual(launchesOf(single), [{ name: "big-audit", agent: "worker", task: "Audit every module." }]);
	assert.deepEqual(
		launchesOf({ children: [{ agent: "scout", name: "a", task: "x" }, { agent: "reviewer", name: "b", task: "y" }] }),
		[{ name: "a", agent: "scout", task: "x" }, { name: "b", agent: "reviewer", task: "y" }],
	);
	assert.deepEqual(launchesOf({ agent: "scout" }), []);
});

test("noteFor flags only risks at or above the threshold", () => {
	const launch = { name: "n", agent: "worker", task: "t" };
	assert.equal(noteFor([{ launch, risk: RISK_THRESHOLD - 0.001, ms: 0 }]), undefined);
	assert.equal(noteFor([{ launch, error: "down", ms: 0 }]), undefined);
	assert.match(noteFor([{ launch, risk: RISK_THRESHOLD, ms: 0 }])!, /`n` \(worker\).*P=0\.85/);
});

test("a high-risk launch gets one advisory line, the original content, and the classifier cost", async () => {
	const result = await harness(answer(0.1))(single);
	assert.equal(result?.content?.[0].text, "launched");
	assert.match(result!.content![1].text, /`big-audit` \(worker\) is likely not to finish in one run \(P=0\.90\)/);
	assert.equal(result!.content!.length, 2);
	assert.equal(result!.usage!.cost.total, 0.00048);
});

test("a low-risk launch keeps its content and only adds usage", async () => {
	const result = await harness(answer(0.9))(single);
	assert.equal(result?.content, undefined);
	assert.equal(result?.usage?.cost.total, 0.00048);
});

test("a batch notes only the flagged children", async () => {
	let call = 0;
	const result = await harness(async () => answer(call++ === 0 ? 0.05 : 0.95)())({
		children: [
			{ agent: "reviewer", name: "huge", title: "t", task: "Review everything." },
			{ agent: "scout", name: "small", title: "t", task: "Where is X?" },
		],
	});
	assert.equal(result!.content!.length, 2);
	assert.match(result!.content![1].text, /`huge`/);
	assert.doesNotMatch(result!.content![1].text, /`small`/);
});

test("classifier failures leave the result unchanged", async () => {
	assert.equal(await harness(undefined)(single), undefined, "no classifier model");
	const failed = await harness(async () => ({ stopReason: "error", errorMessage: "400", answers: {} }))(single);
	assert.equal(failed?.content, undefined, "provider error");
	assert.equal(await harness(async () => Promise.reject(new Error("network")))(single), undefined, "thrown error");
	assert.equal(await harness(answer(0.1))(single, { isError: true }), undefined, "rejected launch");
});

test("a classifier slower than the wait adds no note", { timeout: 15_000 }, async () => {
	const slow = async () => new Promise((resolve) => setTimeout(() => resolve(answer(0.1)()), 6_000));
	const started = Date.now();
	assert.equal(await harness(slow)(single), undefined);
	assert.ok(Date.now() - started < 5_900, "tool_result must not wait for the slow classifier");
});

test("every assessment is logged with its risk and flag", () => {
	const lines = readFileSync(LOG_PATH, "utf8").trim().split("\n").map((l) => JSON.parse(l));
	const flagged = lines.find((l) => l.name === "big-audit" && l.flagged);
	assert.ok(flagged, "flagged launch logged");
	assert.equal(flagged.session, "test-session");
	assert.ok(lines.some((l) => l.error === "classifier cloudflare-workers-ai/@cf/cloudflare/clef unavailable"));
});
