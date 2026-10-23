import type {
	ContextWithSystemEvent,
	ExtensionAPI,
} from "@earendil-works/pi-coding-agent";

// Skills the model may see in the ambient catalog.
//
// Skills with disable-model-invocation: true stay command-only even when named
// here; pi's prompt builder drops them from the catalog.
export const MODEL_VISIBLE_SKILLS: readonly string[] = [
	"torpathy",
	"grilling",
	"grill-me",
	"grill-with-docs",
	"domain-modeling",
	"diagnosing-bugs",
	"research",
	"agentsmd",
	"msw",
];

const VISIBLE = new Set(MODEL_VISIBLE_SKILLS);

// A child that pi-subagents launched with an explicit skill list already has a
// curated catalog (--no-skills, plus one --skill per allowed skill). Gating it
// again would delete the skills its agent definition asked for. A child with no
// skill flags inherited `skills: all`, so it needs the same gate as the parent.
//
// tests/skill-gate-check.ts pins this assumption against pi-subagents.
function hasExplicitSkillList(argv: readonly string[]): boolean {
	return argv.some(
		(arg) => arg === "--no-skills" || arg === "-ns" || arg === "--skill",
	);
}

// This extension gates the ambient skill catalog and nothing else.
//
// It deliberately leaves the <subagent-roster> and <subagent-rules> blocks
// untouched. An earlier version compacted each roster entry onto one line. That
// saved about 117 tokens and merged default_model, models, and the lifecycle
// fields into one sentence, which made model selection harder to read. Routing
// accuracy is worth more than those tokens.
type RequestMessages = ContextWithSystemEvent["messages"];
type RequestMessage = RequestMessages[number];

// One catalog entry as pi's formatSkillsForPrompt writes it. Removing whole
// entries gives the same text pi renders for the filtered list, so a gated
// section is identical whichever path produced it.
const SKILL_ENTRY =
	/\n {2}<skill>\n {4}<name>([^<]*)<\/name>\n[\s\S]*?\n {2}<\/skill>/g;

// Returns undefined when no visible skill remains; pi then omits the section.
function gateSkillsSection(section: string): string | undefined {
	let kept = 0;
	const gated = section.replace(SKILL_ENTRY, (entry, name: string) => {
		if (!VISIBLE.has(name)) return "";
		kept += 1;
		return entry;
	});
	return kept > 0 ? gated : undefined;
}

function isEmptySystemMessage(message: RequestMessage): boolean {
	if (message.role !== "system") return false;
	return (
		message.content.length === 0 &&
		Object.keys(message.sections ?? {}).length === 0 &&
		(message.toolsAdded?.length ?? 0) === 0 &&
		(message.toolsRemoved?.length ?? 0) === 0
	);
}

// Rewrites the `skills` section of every system message in a request clone to
// the gated catalog. A later message that only repeats the gated catalog the
// model already has is dropped, so a full-catalog update recorded by a run
// that skipped before_agent_start never reaches the wire. The result depends
// only on the transcript prefix, so every request repeats the same bytes.
function gateRequestSkills(
	messages: RequestMessages,
): RequestMessages | undefined {
	let current: string | undefined;
	let changed = false;
	const gatedMessages: RequestMessages = [];
	for (const [index, message] of messages.entries()) {
		if (message.role !== "system" || !message.sections) {
			gatedMessages.push(message);
			continue;
		}
		if (!Object.hasOwn(message.sections, "skills")) {
			gatedMessages.push(message);
			continue;
		}

		const skills = message.sections.skills;
		const gated = skills === null ? undefined : gateSkillsSection(skills);
		// Rebuild in the recorded key order. Pi renders sections in object key
		// order, so moving `skills` would change the request prefix as surely as
		// the ungated catalog does. A `context` handler that edits the
		// conversation makes pi collapse every system message into the head
		// first, so the head itself can arrive here with the full catalog.
		const sections: Record<string, string | null> = {};
		for (const [name, value] of Object.entries(message.sections)) {
			if (name !== "skills") sections[name] = value;
			else if (gated !== current) sections.skills = gated ?? null;
		}
		current = gated;

		if (sections.skills === skills) {
			gatedMessages.push(message);
			continue;
		}
		changed = true;
		const { sections: _recorded, ...rest } = message;
		const next: RequestMessage =
			Object.keys(sections).length > 0 ? { ...rest, sections } : rest;
		// Index 0 carries the prompt and initial tools; never drop it.
		if (index > 0 && isEmptySystemMessage(next)) continue;
		gatedMessages.push(next);
	}
	return changed ? gatedMessages : undefined;
}

// This extension gates the ambient skill catalog and nothing else.
//
// It deliberately leaves the <subagent-roster> and <subagent-rules> blocks
// untouched. An earlier version compacted each roster entry onto one line. That
// saved about 117 tokens and merged default_model, models, and the lifecycle
// fields into one sentence, which made model selection harder to read. Routing
// accuracy is worth more than those tokens.
export default function skillGate(pi: ExtensionAPI) {
	if (process.env.PI_SUBAGENT_NAME && hasExplicitSkillList(process.argv)) return;

	// Filter the structured skill list instead of returning a rewritten
	// `systemPrompt`: a returned prompt is forced onto the request head and
	// would hide pi's structured sections. This keeps the recorded prompt, a
	// forced prompt that another extension builds from it, and
	// ctx.getSystemPrompt() gated for runs started by a user prompt.
	pi.on("before_agent_start", (event) => {
		const skills = event.systemPromptOptions.skills;
		if (!skills?.length) return;

		const gated = skills.filter((skill) => VISIBLE.has(skill.name));
		if (gated.length === skills.length) return;
		event.systemPromptOptions.skills = gated;
	});

	// before_agent_start alone is not enough. Runs started by triggerTurn
	// messages (subagent results) skip it, and pi builds their prompt from the
	// ungated options. Pi then records a system message that switches the
	// catalog to every skill, and the next user prompt records a switch back.
	// Each switch changes the request prefix, so Claude Opus 5.5 drops every
	// earlier thinking block and the prompt cache restarts. context_with_system
	// runs before every provider request on a clone of the transcript, so the
	// wire always carries the same gated catalog and the session keeps its
	// recorded entries.
	pi.on("context_with_system", (event) => {
		const gated = gateRequestSkills(event.messages);
		return gated ? { messages: gated } : undefined;
	});
}
