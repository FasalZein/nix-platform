import { createHash } from "node:crypto";
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Per-request composition and cache-break telemetry.
//
// The session JSONL already stores usage by billing type on each assistant
// message. It does not store what was sent: the forced system prompt, the wire
// tool list, and which prefix block changed since the previous request. This
// extension logs that, one JSON line per provider request plus one per
// assistant usage, to ~/.pi/agent/telemetry/requests-YYYY-MM-DD.jsonl.
//
// It loads as the last package in settings.json so it sees the payload after
// every other before_provider_request handler. pi-claude-auth relocates the
// system prompt into the first user message after this hook (stream-level
// onPayload); that move is deterministic, so block hashes still locate breaks.
//
// PI_REQUEST_TELEMETRY=0 disables it. PI_DUMP_PAYLOADS=1 also writes each full
// payload to ~/.pi/artifacts/token-efficiency/payloads/<session>/<seq>.json.

export type Block = { where: string; chars: number; hash: string };

const TELEMETRY_DIR = join(homedir(), ".pi", "agent", "telemetry");
const PAYLOAD_DIR = join(homedir(), ".pi", "artifacts", "token-efficiency", "payloads");

/** JSON with cache_control removed: markers move every request and are not content. */
function stableJson(value: unknown): string {
	return JSON.stringify(value, (key, inner) => (key === "cache_control" ? undefined : inner));
}

function block(where: string, value: unknown): Block {
	const text = typeof value === "string" ? value : stableJson(value);
	return {
		where,
		chars: text.length,
		hash: createHash("sha1").update(text).digest("hex").slice(0, 12),
	};
}

function contentBlocks(where: string, content: unknown): Block[] {
	if (Array.isArray(content)) return content.map((part, i) => block(`${where}[${i}]`, part));
	return [block(where, content)];
}

/**
 * Payload blocks in provider cache-prefix order. Anthropic hashes tools, then
 * system, then messages. OpenAI Responses and chat payloads put instructions or
 * system text first; tools are listed after them here.
 */
export function flattenPayload(payload: Record<string, unknown>): Block[] {
	const blocks: Block[] = [];
	const tools = Array.isArray(payload.tools) ? payload.tools : [];
	const toolBlocks = tools.map((tool, i) => block(`tools[${i}]`, tool));
	const isAnthropic = Array.isArray(payload.messages) && "system" in payload;

	if (isAnthropic) blocks.push(...toolBlocks);
	if (typeof payload.instructions === "string") blocks.push(block("instructions", payload.instructions));
	if (payload.system !== undefined) blocks.push(...contentBlocks("system", payload.system));
	if (!isAnthropic) blocks.push(...toolBlocks);

	const turns = (payload.messages ?? payload.input) as unknown;
	if (Array.isArray(turns)) {
		turns.forEach((turn, i) => {
			const record = turn as { content?: unknown };
			if (record && typeof record === "object" && "content" in record) {
				blocks.push(...contentBlocks(`messages[${i}]`, record.content));
			} else {
				blocks.push(block(`messages[${i}]`, turn));
			}
		});
	}
	return blocks;
}

/**
 * Index of the first block that differs from the previous request, or -1 when
 * the two are identical. A pure append returns previous.length, which is the
 * healthy case: everything already sent is still a reusable prefix.
 */
export function firstDivergence(previous: readonly string[], next: readonly string[]): number {
	const shared = Math.min(previous.length, next.length);
	for (let i = 0; i < shared; i++) if (previous[i] !== next[i]) return i;
	return previous.length === next.length ? -1 : shared;
}

/** Top-level `<name>` sections of a system prompt string, with character counts. */
export function systemSections(text: string): Record<string, number> {
	const sizes: Record<string, number> = {};
	const pattern = /^<([a-z][a-z0-9_-]*)>\n[\s\S]*?\n<\/\1>$/gm;
	let covered = 0;
	for (const match of text.matchAll(pattern)) {
		sizes[match[1]] = (sizes[match[1]] ?? 0) + match[0].length;
		covered += match[0].length;
	}
	sizes._untagged = text.length - covered;
	return sizes;
}

function systemText(payload: Record<string, unknown>): string {
	if (typeof payload.instructions === "string") return payload.instructions;
	const system = payload.system;
	if (typeof system === "string") return system;
	if (Array.isArray(system)) {
		return system.map((part) => (part as { text?: string })?.text ?? "").join("\n\n");
	}
	return "";
}

/** Wire chars per tool, keyed by name (Anthropic `name`, OpenAI `name` or `function.name`). */
export function toolSizes(payload: Record<string, unknown>): Record<string, number> {
	const sizes: Record<string, number> = {};
	if (!Array.isArray(payload.tools)) return sizes;
	for (const tool of payload.tools as Array<{ name?: string; function?: { name?: string } }>) {
		const name = tool?.name ?? tool?.function?.name ?? "?";
		sizes[name] = (sizes[name] ?? 0) + stableJson(tool).length;
	}
	return sizes;
}

type Marked = { cache_control?: { ttl?: string } };

/** Anthropic cache_control sites as `where:ttl`, in prefix order. */
export function markerSites(payload: Record<string, unknown>): string[] {
	const sites: string[] = [];
	const check = (where: string, value: unknown) => {
		const marker = (value as Marked | null)?.cache_control;
		if (marker) sites.push(`${where}:${marker.ttl ?? "5m"}`);
	};
	const list = (value: unknown) => (Array.isArray(value) ? value : []);
	list(payload.tools).forEach((tool, i) => check(`tools[${i}]`, tool));
	list(payload.system).forEach((part, i) => check(`system[${i}]`, part));
	list(payload.messages).forEach((message, i) =>
		list((message as { content?: unknown }).content).forEach((part, j) =>
			check(`messages[${i}][${j}]`, part),
		),
	);
	return sites;
}

export default function requestTelemetry(pi: ExtensionAPI) {
	if (process.env.PI_REQUEST_TELEMETRY === "0") return;
	const dump = process.env.PI_DUMP_PAYLOADS === "1";

	let previousHashes: string[] = [];
	let seq = 0;

	const write = (record: Record<string, unknown>) => {
		try {
			mkdirSync(TELEMETRY_DIR, { recursive: true });
			const day = new Date().toISOString().slice(0, 10);
			appendFileSync(join(TELEMETRY_DIR, `requests-${day}.jsonl`), `${JSON.stringify(record)}\n`);
		} catch {
			// Telemetry must never fail a request.
		}
	};

	pi.on("session_start", (_event, ctx) => {
		previousHashes = [];
		seq = 0;
		// Tool name -> owning extension, so per-tool wire sizes can be summed by extension.
		const active = new Set(pi.getActiveTools());
		write({
			kind: "tools",
			ts: new Date().toISOString(),
			session: ctx.sessionManager.getSessionId(),
			child: process.env.PI_SUBAGENT_NAME ?? null,
			tools: pi.getAllTools().map((tool) => ({
				name: tool.name,
				source: tool.sourceInfo?.path ?? tool.sourceInfo?.source ?? null,
				active: active.has(tool.name),
			})),
		});
	});

	pi.on("before_provider_request", (event, ctx) => {
		const payload = event.payload as Record<string, unknown> | null;
		if (!payload || typeof payload !== "object") return;
		const sessionId = ctx.sessionManager.getSessionId();
		seq += 1;

		const blocks = flattenPayload(payload);
		const hashes = blocks.map((b) => b.hash);
		const previousLength = previousHashes.length;
		const diverge = previousLength === 0 ? 0 : firstDivergence(previousHashes, hashes);
		previousHashes = hashes;

		const charsBefore = (end: number) => blocks.slice(0, end).reduce((sum, b) => sum + b.chars, 0);
		const sum = (prefix: string) =>
			blocks.filter((b) => b.where.startsWith(prefix)).reduce((total, b) => total + b.chars, 0);
		const text = systemText(payload);

		write({
			kind: "request",
			ts: new Date().toISOString(),
			session: sessionId,
			child: process.env.PI_SUBAGENT_NAME ?? null,
			seq,
			model: payload.model ?? ctx.model?.id ?? null,
			chars: {
				tools: sum("tools"),
				system: sum("system") + sum("instructions"),
				messages: sum("messages"),
				total: charsBefore(blocks.length),
			},
			toolCount: Array.isArray(payload.tools) ? payload.tools.length : 0,
			toolChars: toolSizes(payload),
			systemSections: systemSections(text),
			systemHash: createHash("sha1").update(text).digest("hex").slice(0, 12),
			blocks: blocks.length,
			divergeAt:
				diverge < 0
					? null
					: {
							index: diverge,
							where: blocks[diverge]?.where ?? "end",
							charsBefore: charsBefore(diverge),
							appendOnly: previousLength > 0 && diverge === previousLength,
						},
			markers: markerSites(payload),
		});

		if (dump) {
			try {
				const dir = join(PAYLOAD_DIR, sessionId);
				mkdirSync(dir, { recursive: true });
				writeFileSync(join(dir, `${Date.now()}-${String(seq).padStart(4, "0")}.json`), JSON.stringify(payload, null, 1));
			} catch {
				// Dumping is diagnostic only.
			}
		}
	});

	pi.on("message_end", (event, ctx) => {
		const message = event.message as {
			role?: string;
			usage?: Record<string, unknown>;
			stopReason?: string;
			provider?: string;
			model?: string;
		};
		if (message.role !== "assistant" || !message.usage) return;
		write({
			kind: "usage",
			ts: new Date().toISOString(),
			session: ctx.sessionManager.getSessionId(),
			child: process.env.PI_SUBAGENT_NAME ?? null,
			seq,
			provider: message.provider ?? null,
			model: message.model ?? null,
			stopReason: message.stopReason ?? null,
			usage: message.usage,
		});
	});
}
