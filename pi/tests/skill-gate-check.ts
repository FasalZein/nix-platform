import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, existsSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
// The allowlist lives at the top of skill-gate.ts. That module imports
// @earendil-works/pi-coding-agent, which does not resolve from this directory,
// so the test reads the list out of the source instead of importing it.
function readAllowlist(source: string): string[] {
	const block = /MODEL_VISIBLE_SKILLS:\s*readonly string\[\]\s*=\s*\[([\s\S]*?)\];/.exec(source);
	assert.ok(block, "skill-gate.ts no longer declares MODEL_VISIBLE_SKILLS as a literal array");
	return [...block[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

const SKILLS_DIR = "/Users/tothemoon/.pi/agent/skills";
const GATE = join(import.meta.dirname, "../extensions/skill-gate.ts");
const FIXTURE = join(import.meta.dirname, "fixtures/inspect-skill-gate.ts");
const SUBAGENTS =
	"/Users/tothemoon/.pi/agent/git/github.com/edxeth/pi-subagents/src/index.ts";
const ROSTER_FIXTURE = join(import.meta.dirname, "fixtures/skill-gate-roster");
const ROSTER_AGENT = "roster-fixture-worker";

// 1. The allowlist is a plain literal at the top of the gate.
const gateSource = readFileSync(GATE, "utf8");
const MODEL_VISIBLE_SKILLS = readAllowlist(gateSource);
const visible = new Set(MODEL_VISIBLE_SKILLS);
assert.ok(visible.size > 1, "curated set unexpectedly empty");
assert.equal(
	visible.size,
	MODEL_VISIBLE_SKILLS.length,
	"allowlist contains a duplicate name",
);

// The gate does skill gating only. It must not reach the provider payload or
// rewrite conversation messages, so roster and rules stay exactly as upstream
// wrote them. Comments are stripped first so the prose explaining this rule is
// not mistaken for code that breaks it.
const gateCode = gateSource
	.replace(/\/\*[\s\S]*?\*\//g, "")
	.split("\n")
	.filter((line) => !line.trim().startsWith("//"))
	.join("\n");
for (const forbidden of ["before_provider_request", "subagent-roster", "subagent-rules"]) {
	assert.ok(
		!gateCode.includes(forbidden),
		`skill-gate.ts must not handle ${forbidden}; it gates skills only`,
	);
}
assert.ok(
	!/pi\.on\(\s*"context"/.test(gateCode),
	"skill-gate.ts must not rewrite conversation messages; it gates skills only",
);
// A returned systemPrompt applies only to runs started by a user prompt. Runs
// started by subagent results would send the ungated catalog, and on Claude
// Opus 5.5 that prefix switch drops thinking blocks and restarts the cache.
assert.ok(
	!/\bsystemPrompt\s*[:}]/.test(gateCode),
	"skill-gate.ts must filter systemPromptOptions.skills, not return a systemPrompt",
);

// 2. Every visible skill must exist on disk.
const bodies = new Map<string, string>();
for (const name of readdirSync(SKILLS_DIR)) {
	const file = join(SKILLS_DIR, name, "SKILL.md");
	if (existsSync(file)) bodies.set(name, readFileSync(file, "utf8"));
}
for (const name of visible) {
	assert.ok(bodies.has(name), `visible skill has no SKILL.md: ${name}`);
}

// 3. Command-only skills stay command-only even when named in the curated set.
const modelVisible = new Set<string>();
const commandOnly = new Set<string>();
for (const name of visible) {
	const body = bodies.get(name)!;
	if (/^disable-model-invocation:\s*true\s*$/m.test(body)) commandOnly.add(name);
	else modelVisible.add(name);
}
assert.ok(commandOnly.has("grill-me"), "grill-me must remain command-only");
assert.ok(
	commandOnly.has("grill-with-docs"),
	"grill-with-docs must remain command-only",
);

function reportedSkills(
	args: string[],
	env: NodeJS.ProcessEnv = {},
	label = args.join(" "),
): string[] {
	const result = spawnSync("pi", args, {
		encoding: "utf8",
		env: { ...process.env, ...env },
	});
	assert.equal(result.status, 0, result.stderr || result.stdout);
	const reported = /VISIBLE_SKILLS=(.*)/.exec(result.stderr);
	assert.ok(reported, `fixture did not report visible skills for ${label}:\n${result.stderr}`);
	return reported[1].split(",").filter(Boolean).sort();
}

// 4. The gate filters the native live system prompt to exactly that set.
assert.deepEqual(
	reportedSkills(["-ne", "-e", GATE, "-e", FIXTURE, "-p", "hi"], {}, "parent"),
	[...modelVisible].sort(),
	"system prompt skill list does not match model-invocable curated skills",
);
console.log(
	`OK — ${modelVisible.size} model-visible, ${commandOnly.size} command-only`,
);

// 5. A subagent that inherited `skills: all` gets the same gate as the parent.
assert.deepEqual(
	reportedSkills(
		["-ne", "-e", GATE, "-e", FIXTURE, "-p", "hi"],
		{ PI_SUBAGENT_NAME: "gate-check-child" },
		"child without a skill list",
	),
	[...modelVisible].sort(),
	"child with no explicit skill list must be gated like the parent",
);

// 6. A subagent launched with an explicit skill list keeps exactly that list.
const explicitSkill = "/Users/tothemoon/.agents/skills/writing-for-agents";
assert.ok(
	existsSync(join(explicitSkill, "SKILL.md")),
	`fixture skill missing: ${explicitSkill}`,
);
assert.ok(
	!visible.has("writing-for-agents"),
	"the opt-out probe must use a skill outside the allowlist",
);
assert.deepEqual(
	reportedSkills(
		["-ne", "-e", GATE, "-e", FIXTURE, "-ns", "--skill", explicitSkill, "-p", "hi"],
		{ PI_SUBAGENT_NAME: "gate-check-child" },
		"child with an explicit skill list",
	),
	["writing-for-agents"],
	"child launched with --skill must keep its curated list ungated",
);
console.log("OK — subagent gate applies only without an explicit skill list");

// 7. Contract with pi-subagents: the gate stands down inside a child because
// pi-subagents passes --no-skills and --skill. If that mechanism is ever
// replaced, this fails instead of the gate silently stripping a curated list.
const { buildSkillLaunchPlanForTest } = await import(
	"/Users/tothemoon/.pi/agent/git/github.com/edxeth/pi-subagents/src/subagents.ts"
);
const onlyPlan = await buildSkillLaunchPlanForTest("research", undefined, process.cwd());
assert.equal(onlyPlan.availability.mode, "only", "a skills list must give mode: only");
assert.ok(
	onlyPlan.launchArgs.includes("--no-skills") && onlyPlan.launchArgs.includes("--skill"),
	`pi-subagents no longer passes --no-skills/--skill: ${JSON.stringify(onlyPlan.launchArgs)}`,
);
const nonePlan = await buildSkillLaunchPlanForTest("none", undefined, process.cwd());
assert.deepEqual(
	nonePlan.launchArgs,
	["--no-skills"],
	"`skills: none` must still launch a child with --no-skills",
);
const allPlan = await buildSkillLaunchPlanForTest(undefined, undefined, process.cwd());
assert.deepEqual(
	allPlan.launchArgs,
	[],
	"an unset skills line must still mean mode: all with no flags",
);
console.log("OK — pi-subagents still signals a curated catalog with --no-skills/--skill");

// 8. Every provider-stage probe uses Pi's supported models.json override. The
// effective model must point at a closed local port, even if the observer fails.
const LOCAL_PROVIDER_BASE_URL = "http://127.0.0.1:1/v1";
const modelsConfig = JSON.parse(
	readFileSync(join(ROSTER_FIXTURE, "models.json"), "utf8"),
) as { providers?: { xai?: { baseUrl?: string } } };
assert.equal(
	modelsConfig.providers?.xai?.baseUrl,
	LOCAL_PROVIDER_BASE_URL,
	"the fixture provider must fail closed on localhost",
);

function spawnProviderProbe(gated: boolean, observe: boolean) {
	return spawnSync(
		"pi",
		[
			"-ne",
			...(gated ? ["-e", GATE] : []),
			"-e",
			SUBAGENTS,
			...(observe ? ["-e", FIXTURE] : []),
			"-ns",
			...[...modelVisible].flatMap((name) => ["--skill", join(SKILLS_DIR, name)]),
			"--tools",
			"read,subagent",
			"--provider",
			"xai",
			"--model",
			"grok-4.3",
			"--api-key",
			"fixture-no-send",
			"--no-session",
			"--offline",
			"-p",
			"hi",
		],
		{
			encoding: "utf8",
			cwd: ROSTER_FIXTURE,
			timeout: 15_000,
			env: {
				...process.env,
				PI_CODING_AGENT_DIR: ROSTER_FIXTURE,
				PI_DENY_TOOLS: "",
				PI_ORCHESTRATOR_MODE: "",
				PI_SUBAGENT_AGENT: "",
				PI_SUBAGENT_NAME: "",
				PI_SUBAGENT_SPAWNABLE: "",
				SKILL_GATE_PROVIDER_CHECK: "1",
			},
		},
	);
}

function runProviderProbe(gated: boolean): string {
	const result = spawnProviderProbe(gated, true);
	assert.equal(result.status, 0, result.stderr || result.stdout || String(result.error));
	return result.stderr;
}

function reportedJson<T>(stderr: string, label: string): T {
	const reported = new RegExp(`^${label}=(.*)$`, "m").exec(stderr);
	assert.ok(reported, `fixture did not report ${label}:\n${stderr}`);
	return JSON.parse(reported[1]) as T;
}

const boundaryFailure = spawnProviderProbe(false, false);
assert.equal(boundaryFailure.status, 1, boundaryFailure.stderr || boundaryFailure.stdout || String(boundaryFailure.error));
assert.equal(boundaryFailure.stderr.trim(), "Connection error.");
console.log("OK — missing observer fails locally without retry");

const baselineStderr = runProviderProbe(false);
const gatedStderr = runProviderProbe(true);
for (const stderr of [baselineStderr, gatedStderr]) {
	assert.deepEqual(
		reportedJson(stderr, "PROVIDER"),
		{ provider: "xai", model: "grok-4.3", baseUrl: LOCAL_PROVIDER_BASE_URL },
		"the effective provider endpoint must stay local and fail closed",
	);
}
console.log(`OK — provider fail-closed at ${LOCAL_PROVIDER_BASE_URL}`);

// 9. The provider payload keeps the gated catalog.
const providerReported = /MARKDOWN_SKILLS=(.*)/.exec(gatedStderr);
assert.ok(providerReported, `fixture did not report provider skills:\n${gatedStderr}`);
assert.deepEqual(
	providerReported[1].split(",").filter(Boolean).sort(),
	[...modelVisible].sort(),
	"provider payload skill list does not match model-visible skills",
);

// 10. Compare the complete upstream rules from identical real pi-subagents
// runs. Only the gated run loads skill-gate. The gate does skill gating only,
// so both runs must produce identical rules.
const baselineRules = reportedJson<string>(baselineStderr, "RULES");
const gatedRules = reportedJson<string>(gatedStderr, "RULES");
assert.equal(gatedRules, baselineRules, "the gate must preserve the complete upstream rules exactly");
for (const upstreamRule of ["context-warn", "idle-timeout", "Do not resume an agent"]) {
	assert.ok(
		gatedRules.includes(upstreamRule),
		`the gate must not delete upstream rules; missing: ${upstreamRule}`,
	);
}
console.log("OK — complete upstream roster rules preserved exactly");

// 11. A real pi-subagents extension discovers the hermetic agent. The gate must
// hand the roster to the provider exactly as upstream wrote it, because the
// model reads default_model, models, and the lifecycle fields to route work.
type RosterReport = {
	agents: string[];
	chars: number;
	entryLines: number;
	text: string;
};
const baselineRoster = reportedJson<RosterReport>(baselineStderr, "ROSTER");
const roster = reportedJson<RosterReport>(gatedStderr, "ROSTER");
assert.deepEqual(
	roster.agents,
	[ROSTER_AGENT],
	"the real provider request must contain the hermetic spawnable agent",
);
assert.equal(new Set(roster.agents).size, roster.agents.length, "agent names must be unique");
assert.deepEqual(roster, baselineRoster, "the gate must not rewrite the upstream roster");
for (const sentinel of [
	"tool_return: wait_here",
	"runs_as: hidden_process",
	"context: copy_of_this_chat",
	"completion: exits_automatically",
	"default_model: xai/grok-4.3",
	"models: any model ref",
]) {
	assert.ok(
		roster.text.includes(sentinel),
		`the roster must keep its upstream routing field: ${sentinel}`,
	);
}
assert.ok(
	roster.entryLines > roster.agents.length,
	`the roster must keep upstream's one-field-per-line shape: ${roster.entryLines} lines for ${roster.agents.length} agents`,
);
console.log(
	`OK — roster untouched by the gate, ${roster.agents.length} agent, ${roster.entryLines} lines, ${roster.chars} chars`,
);

// 12. A run started by a triggerTurn message (how subagent results arrive)
// skips before_agent_start, and pi prepares its later turns from the ungated
// options. Pi then records a system message that switches the catalog to every
// skill. The gate must still send one unchanged gated catalog, or the request
// prefix changes and Claude Opus 5.5 drops earlier thinking blocks.
//
// The probe registers pi-ai's faux provider, so the run is local and scripted:
// request 1 answers the user prompt; agent_settled then starts an idle
// triggerTurn run, like a subagent result; request 2 calls read; request 3 is
// the turn pi prepares after that tool call. The faux provider sees the
// context after every context_with_system handler, which is what the provider
// serializes. The probe lives in a temp dir because only this check uses it.
//
// With SKILL_GATE_PROBE_EDIT_CONTEXT set, the probe also registers a `context`
// handler that edits the conversation, as context-profile.ts does. Pi then
// collapses every system message into one head before context_with_system
// runs, so the head arrives with the ungated catalog.
const PROBE_SOURCE = `
import { fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentSystemPrompt, getSystemMessageText } from "@earendil-works/pi-ai";

export default function triggerProbe(pi) {
	let starts = 0;
	let triggered = false;
	const record = (context) => {
		const catalogs = [];
		for (const message of context.messages) {
			if (message.role !== "system") continue;
			const texts = [message.content, ...Object.values(message.sections ?? {})];
			for (const text of texts) {
				if (typeof text === "string" && text.includes("<available_skills>")) catalogs.push(text);
			}
		}
		const head = context.messages[0];
		console.error("REQUEST=" + JSON.stringify({
			starts,
			catalogs,
			headText: head?.role === "system" ? getSystemMessageText(head) : "",
			sectionOrder: head?.role === "system" ? Object.keys(head.sections ?? {}) : [],
			systemText: getCurrentSystemPrompt(context.messages),
		}));
	};
	const faux = fauxProvider({ provider: "skill-gate-probe", models: [{ id: "probe" }] });
	faux.setResponses([
		(context) => {
			record(context);
			return fauxAssistantMessage("ok");
		},
		(context) => {
			record(context);
			return fauxAssistantMessage(fauxToolCall("read", { path: import.meta.filename }), {
				stopReason: "toolUse",
			});
		},
		(context) => {
			record(context);
			return fauxAssistantMessage("done");
		},
	]);
	pi.registerProvider(faux.provider);
	pi.on("before_agent_start", () => {
		starts += 1;
	});
	if (process.env.SKILL_GATE_PROBE_EDIT_CONTEXT) {
		pi.on("context", (event) => ({ messages: event.messages.map((message) => ({ ...message })) }));
	}
	pi.on("agent_settled", () => {
		if (triggered) return;
		triggered = true;
		pi.sendMessage(
			{ customType: "skill-gate-probe", content: "continue", display: true },
			{ triggerTurn: true },
		);
	});
}
`;
// Every skill on disk, so the ungated catalog differs from the gated one.
function commandOnlyOnDisk(name: string): boolean {
	return /^disable-model-invocation:\s*true\s*$/m.test(bodies.get(name) ?? "");
}
assert.ok(
	[...bodies.keys()].some((name) => !visible.has(name) && !commandOnlyOnDisk(name)),
	"the trigger probe needs a model-invocable skill outside the allowlist",
);
type ProbeRequest = {
	starts: number;
	catalogs: string[];
	headText: string;
	sectionOrder: string[];
	systemText: string;
};
function runTriggerProbe(options: {
	extensions: string[];
	cwd: string;
	env?: NodeJS.ProcessEnv;
}): ProbeRequest[] {
	const probeDir = mkdtempSync(join(tmpdir(), "skill-gate-trigger-"));
	const probeFile = join(probeDir, "trigger-probe.ts");
	writeFileSync(probeFile, PROBE_SOURCE);
	let result: ReturnType<typeof spawnSync>;
	try {
		result = spawnSync(
			"pi",
			[
				"-ne",
				"-e",
				GATE,
				...options.extensions.flatMap((extension) => ["-e", extension]),
				"-e",
				probeFile,
				"-ns",
				...[...bodies.keys()].flatMap((name) => ["--skill", join(SKILLS_DIR, name)]),
				"--tools",
				"read",
				"--provider",
				"skill-gate-probe",
				"--model",
				"probe",
				"--api-key",
				"fixture-no-send",
				"--no-session",
				"--offline",
				"-p",
				"hi",
			],
			{
				encoding: "utf8",
				cwd: options.cwd,
				timeout: 30_000,
				env: {
					...process.env,
					PI_CODING_AGENT_DIR: ROSTER_FIXTURE,
					PI_SUBAGENT_NAME: "",
					...options.env,
				},
			},
		);
	} finally {
		rmSync(probeDir, { recursive: true, force: true });
	}
	const stderr = String(result.stderr);
	assert.equal(result.status, 0, stderr || String(result.stdout) || String(result.error));
	const requests = [...stderr.matchAll(/^REQUEST=(.*)$/gm)].map(
		(match) => JSON.parse(match[1]) as ProbeRequest,
	);
	assert.equal(requests.length, 3, `the probe must observe three requests:\n${stderr}`);
	assert.deepEqual(
		requests.map((request) => request.starts),
		[1, 1, 1],
		"requests 2 and 3 must come from a triggerTurn run that skipped before_agent_start",
	);
	return requests;
}

const gatedNames = [...modelVisible].sort();
const triggerRequests = runTriggerProbe({ extensions: [], cwd: ROSTER_FIXTURE });
for (const [index, request] of triggerRequests.entries()) {
	assert.equal(
		request.catalogs.length,
		1,
		`request ${index + 1} must carry exactly one skill catalog, found ${request.catalogs.length}`,
	);
	const names = [...request.catalogs[0].matchAll(/<name>([^<]+)<\/name>/g)].map((match) => match[1]);
	assert.deepEqual(names.sort(), gatedNames, `request ${index + 1} must carry the gated catalog`);
	assert.equal(
		request.catalogs[0],
		triggerRequests[0].catalogs[0],
		`request ${index + 1} must repeat the first request's catalog byte for byte`,
	);
}
console.log(`OK — triggerTurn run sends the same gated catalog (${gatedNames.length} skills, 3 requests)`);

// 13. The same run in the shape of a real session: a project AGENTS.md gives
// the head a project_context section before skills and cwd, pi-better-skills
// adds its agent_skills section in its own context_with_system handler, and a
// `context` handler edits the conversation, so pi collapses the full-catalog
// update into the head. The provider-facing system text must be byte-identical
// on every request. A gate that rebuilt the head with `skills` moved after
// `cwd` sent the right catalog in the wrong place, and Claude Opus 5.5 dropped
// 3 thinking blocks in session 01a0e386.
const BETTER_SKILLS = "/Users/tothemoon/Dev/AI/pi/extensions/pi-better-skills/src/index.ts";
const projectDir = mkdtempSync(join(tmpdir(), "skill-gate-project-"));
let sessionRequests: ProbeRequest[];
try {
	writeFileSync(join(projectDir, "AGENTS.md"), "# Probe project\n\nProject instructions for the skill-gate check.\n");
	sessionRequests = runTriggerProbe({
		extensions: [BETTER_SKILLS],
		cwd: projectDir,
		env: { SKILL_GATE_PROBE_EDIT_CONTEXT: "1" },
	});
} finally {
	rmSync(projectDir, { recursive: true, force: true });
}
const firstOrder = sessionRequests[0].sectionOrder;
for (const section of ["project_context", "skills", "cwd", "agent_skills"]) {
	assert.ok(firstOrder.includes(section), `the probe head must have a ${section} section: ${firstOrder.join(" ")}`);
}
assert.ok(
	firstOrder.indexOf("skills") < firstOrder.indexOf("cwd"),
	`pi must place skills before cwd in the head: ${firstOrder.join(" ")}`,
);
for (const [index, request] of sessionRequests.entries()) {
	assert.deepEqual(
		request.sectionOrder,
		firstOrder,
		`request ${index + 1} must keep the head's section order`,
	);
	assert.equal(
		request.headText,
		sessionRequests[0].headText,
		`request ${index + 1} must send the same leading system text byte for byte`,
	);
	assert.equal(
		request.systemText,
		sessionRequests[0].systemText,
		`request ${index + 1} must send the same system prompt byte for byte`,
	);
}
console.log(
	`OK — system text byte-identical across 3 requests with project_context, agent_skills, and a collapsed head (${firstOrder.join(" ")})`,
);
