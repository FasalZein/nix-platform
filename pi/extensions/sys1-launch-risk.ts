import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// Launch-time completion risk for subagents, scored by a System 1 classifier (Cloudflare Clef).
//
// When the parent calls `subagent`, each child's brief goes to Clef while the launch runs. If Clef
// rates the child likely not to finish in one run, one advisory line is appended to the subagent
// tool result. The launch itself is never changed or delayed; every failure leaves the result as is.
//
// The state shape, caps, and questions below match the offline eval in
// ~/.pi/artifacts/clef/offline-eval-report.md (457 past launches: AUC 0.77 for PARTIAL vs DONE;
// at p >= 0.85, 52% precision and 49% recall). Change them only together with a new eval, because
// Clef scores all questions jointly and the measured numbers hold only for this exact request.

const PROVIDER = "cloudflare-workers-ai";
const MODEL_ID = "@cf/cloudflare/clef";
/** P(not complete) at or above this adds the advisory note (top 20% of past launches). */
export const RISK_THRESHOLD = 0.85;
/** Longest wait in tool_result before the note is dropped; the log still records the late answer. */
const RESULT_WAIT_MS = 5_000;
const REQUEST_TIMEOUT_MS = 15_000;
const TASK_CAP_CHARS = 12_000;
const RULES_CAP_CHARS = 6_000;
// HOME first: Bun's homedir() ignores a changed HOME, which tests rely on to isolate the log.
const HOME = process.env.HOME ?? homedir();
const AGENTS_DIR = join(HOME, ".pi/agent/agents");
export const LOG_PATH = join(HOME, ".pi/artifacts/clef/launch-risk.jsonl");

export const QUESTIONS = {
	outcome: {
		type: "choice",
		instructions: "How will this subagent run most likely end?",
		criteria: {
			complete: "The agent finishes everything the task asks in this one run",
			partial: "The agent stops part-way: work remains, gates fail, or it runs out of time or context",
			blocked: "The agent stops because its own rules, missing access, or a needed decision forbid the task",
		},
	},
	scope: {
		type: "score",
		instructions: "How large is the scope of the task?",
		criteria: [
			"one fact or one file",
			"a few files in one area",
			"one subsystem or feature",
			"several subsystems, a whole-repo audit, or a long checklist",
		],
	},
	contract_conflict: {
		type: "bool",
		instructions:
			"Does the task ask the agent to do something that agent_rules forbid, such as rebase, merge, switching branches, or working on a detached HEAD?",
		criteria: { true: "The task conflicts with the agent's rules", false: "The task is allowed by the agent's rules" },
	},
	fits_one_context: {
		type: "bool",
		instructions: "Can one agent run finish this task without running out of context or time?",
		criteria: { true: "Fits in one run", false: "Too large for one run" },
	},
} as const;

export interface Launch {
	name: string;
	agent: string;
	task: string;
}

export interface Assessment {
	launch: Launch;
	/** 1 - P(complete); undefined when the classifier gave no answer. */
	risk?: number;
	usage?: Usage;
	error?: string;
	ms: number;
}

type Usage = NonNullable<Awaited<ReturnType<ExtensionContext["modelRegistry"]["classify"]>>["usage"]>;

/**
 * The fields of pi-subagents' `SubagentParams` this extension reads. Pi validates tool arguments
 * against that schema before `tool_call` handlers run, so the input already has this shape.
 */
export interface SubagentInput {
	name?: string;
	agent?: string;
	task?: string;
	children?: { name: string; agent: string; task: string }[];
}

/** Children of one `subagent` call: a `children` batch, or the single top-level launch. */
export function launchesOf(input: SubagentInput): Launch[] {
	return (input.children ?? [input]).flatMap(({ name, agent, task }) =>
		agent !== undefined && task !== undefined ? [{ name: name ?? agent, agent, task }] : [],
	);
}

interface AgentRules {
	description: string;
	rules: string;
}

/** Agent description and the start of its rules, read the same way as the offline eval. */
export function agentRules(agent: string, dir = AGENTS_DIR): AgentRules {
	const path = join(dir, `${agent}.md`);
	if (!existsSync(path)) return { description: "", rules: "" };
	const text = readFileSync(path, "utf8");
	const match = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(text);
	if (!match) return { description: "", rules: text.slice(0, RULES_CAP_CHARS) };
	const description = /^description: (.*)$/m.exec(match[1])?.[1] ?? "";
	return { description, rules: match[2].slice(0, RULES_CAP_CHARS) };
}

export function classifierState(launch: Launch, batchSize: number, dir = AGENTS_DIR) {
	const { description, rules } = agentRules(launch.agent, dir);
	return {
		agent: launch.agent,
		agent_description: description,
		agent_rules: rules,
		batch_size: batchSize,
		task: launch.task.slice(0, TASK_CAP_CHARS),
	};
}

export async function assess(ctx: ExtensionContext, launch: Launch, batchSize: number): Promise<Assessment> {
	const started = Date.now();
	const model = ctx.modelRegistry.findOfType("classifier", PROVIDER, MODEL_ID);
	if (!model) return { launch, error: `classifier ${PROVIDER}/${MODEL_ID} unavailable`, ms: 0 };
	try {
		const result = await ctx.modelRegistry.classify(
			model,
			{ state: classifierState(launch, batchSize), questions: QUESTIONS as never },
			{ signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) },
		);
		const ms = Date.now() - started;
		const outcome = result.answers.outcome;
		if (result.stopReason !== "stop" || outcome?.type !== "choice") {
			return { launch, usage: result.usage, error: result.errorMessage ?? "no outcome answer", ms };
		}
		return { launch, risk: 1 - (outcome.probabilities.complete ?? 0), usage: result.usage, ms };
	} catch (error) {
		return { launch, error: error instanceof Error ? error.message : String(error), ms: Date.now() - started };
	}
}

export function noteFor(assessments: readonly Assessment[], threshold = RISK_THRESHOLD): string | undefined {
	const flagged = assessments.filter((a) => a.risk !== undefined && a.risk >= threshold);
	if (flagged.length === 0) return undefined;
	return flagged
		.map(
			(a) =>
				`Launch risk (Clef): \`${a.launch.name}\` (${a.launch.agent}) is likely not to finish in one run ` +
				`(P=${a.risk!.toFixed(2)}). Consider splitting the brief or naming a smaller first deliverable.`,
		)
		.join("\n");
}

function addUsage(base: Usage | undefined, extra: readonly (Usage | undefined)[]): Usage | undefined {
	const parts = [base, ...extra].filter((u): u is Usage => u !== undefined);
	if (parts.length === 0) return undefined;
	const sum = (pick: (u: Usage) => number | undefined) => parts.reduce((total, u) => total + (pick(u) ?? 0), 0);
	return {
		...parts[0],
		input: sum((u) => u.input),
		output: sum((u) => u.output),
		cacheRead: sum((u) => u.cacheRead),
		cacheWrite: sum((u) => u.cacheWrite),
		totalTokens: sum((u) => u.totalTokens),
		cost: {
			...parts[0].cost,
			input: sum((u) => u.cost?.input),
			output: sum((u) => u.cost?.output),
			cacheRead: sum((u) => u.cost?.cacheRead),
			cacheWrite: sum((u) => u.cost?.cacheWrite),
			total: sum((u) => u.cost?.total),
		},
	} as Usage;
}

interface LogEntry {
	ts: string;
	session: string;
	toolCallId: string;
	agent: string;
	name: string;
	risk?: number;
	flagged: boolean;
	ms: number;
	cost?: number;
	error?: string;
}

function log(entry: LogEntry, path = LOG_PATH) {
	try {
		mkdirSync(dirname(path), { recursive: true });
		appendFileSync(path, `${JSON.stringify(entry)}\n`);
	} catch {
		// Logging must never affect the launch.
	}
}

// unref: a pending wait must not keep a print-mode pi process alive.
const timeout = (ms: number) => new Promise<undefined>((resolve) => setTimeout(resolve, ms, undefined).unref());

export default function (pi: ExtensionAPI) {
	const pending = new Map<string, Promise<Assessment[]>>();

	pi.on("tool_call", (event, ctx) => {
		if (event.toolName !== "subagent") return;
		const launches = launchesOf(event.input as SubagentInput);
		if (launches.length === 0) return;
		const session = ctx.sessionManager.getSessionId();
		const assessments = Promise.all(launches.map((launch) => assess(ctx, launch, launches.length))).then(
			(results) => {
				for (const a of results) {
					log({
						ts: new Date().toISOString(),
						session,
						toolCallId: event.toolCallId,
						agent: a.launch.agent,
						name: a.launch.name,
						risk: a.risk,
						flagged: a.risk !== undefined && a.risk >= RISK_THRESHOLD,
						ms: a.ms,
						cost: a.usage?.cost?.total,
						error: a.error,
					});
				}
				return results;
			},
		);
		pending.set(event.toolCallId, assessments);
	});

	pi.on("tool_result", async (event) => {
		if (event.toolName !== "subagent") return;
		const assessments = pending.get(event.toolCallId);
		pending.delete(event.toolCallId);
		if (!assessments || event.isError) return;
		const results = await Promise.race([assessments, timeout(RESULT_WAIT_MS)]);
		if (!results) return;
		const usage = addUsage(event.usage, results.map((a) => a.usage));
		const note = noteFor(results);
		if (!note) return usage ? { usage } : undefined;
		return {
			content: [...event.content, { type: "text" as const, text: note }],
			structuredContent: event.structuredContent,
			usage,
		};
	});
}
