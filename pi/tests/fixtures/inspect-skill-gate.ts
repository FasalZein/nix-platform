import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function inspectSkillGate(pi: ExtensionAPI) {
	let providerObserverRegistered = false;
	pi.on("before_agent_start", (event, ctx) => {
		if (process.env.SKILL_GATE_PROVIDER_CHECK) {
			if (providerObserverRegistered) return;
			providerObserverRegistered = true;
			console.error(`PROVIDER=${JSON.stringify({
				provider: ctx.model?.provider,
				model: ctx.model?.id,
				baseUrl: ctx.model?.baseUrl,
			})}`);
			// Register immediately before the provider phase, after startup-time
			// provider handlers, so this observes the final chained payload.
			pi.on("before_provider_request", (providerEvent) => {
				const payload = providerEvent.payload as Record<string, unknown>;
				const textParts: string[] = [];
				const collect = (value: unknown) => {
					if (typeof value === "string") textParts.push(value);
					else if (Array.isArray(value)) value.forEach(collect);
					else if (value && typeof value === "object") {
						const record = value as Record<string, unknown>;
						for (const key of ["text", "content", "parts"]) collect(record[key]);
					}
				};
				for (const key of ["input", "messages", "system", "system_instruction", "systemInstruction"]) {
					collect(payload[key]);
				}
				const text = textParts.join("\n");
				// Report the catalog pi actually builds. An earlier version unioned
				// this with a Markdown catalog that no extension produces, so the
				// assertion passed on the XML alone and proved nothing.
				const nativeSection = /<available_skills>([\s\S]*?)<\/available_skills>/.exec(text)?.[1] ?? "";
				const names = [...nativeSection.matchAll(/<name>([^<]+)<\/name>/g)].map((match) => match[1]);
				const reminder = text.slice(text.lastIndexOf("<system-reminder>"));
				const roster = /<subagent-roster>([\s\S]*?)<\/subagent-roster>/.exec(reminder)?.[1] ?? "";
				const agents = [...roster.matchAll(/^- `([^`]+)`:/gm)].map((match) => match[1]);
				const rules = /<subagent-rules>([\s\S]*?)<\/subagent-rules>/.exec(reminder)?.[1] ?? "";
				console.error(`MARKDOWN_SKILLS=${names.join(",")}`);
				console.error(`RULES=${JSON.stringify(rules)}`);
				console.error(`ROSTER=${JSON.stringify({
					agents,
					chars: roster.length,
					entryLines: roster.trim() ? roster.trim().split("\n").length : 0,
					text: roster.trim(),
				})}`);
				process.exit(0);
			});
			return;
		}
		const visible = [
			...event.systemPrompt.matchAll(/<name>([^<]+)<\/name>/g),
		].map((m) => m[1]);
		console.error(`VISIBLE_SKILLS=${visible.join(",")}`);
		process.exit(0);
	});

}
