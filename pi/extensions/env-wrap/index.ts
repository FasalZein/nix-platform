import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createBashToolDefinition, getAgentDir } from "@earendil-works/pi-coding-agent";
import { type Env, EnvWrap } from "./core.ts";

// Replaces the built-in bash tool with the same definition plus a spawn hook:
// each call runs in the direnv/devenv env of its worktree (see core.ts). The
// command text in the transcript stays unchanged.

/** pi's bash spawn env before PI_* keys (mirrors getShellEnv in dist/utils/shell.js). */
function piShellEnv(): Env {
	const bin = join(getAgentDir(), "bin");
	const path = process.env.PATH ?? "";
	return { ...process.env, PATH: path.split(":").includes(bin) ? path : [bin, path].filter(Boolean).join(":") };
}

export default function envWrap(pi: ExtensionAPI) {
	const wrap = new EnvWrap({ stateDir: join(getAgentDir(), "state", "env-wrap") });
	const builtin = createBashToolDefinition(process.cwd());
	pi.registerTool({
		...builtin,
		async execute(toolCallId, params, signal, onUpdate, ctx) {
			const cwd = ctx?.cwd || process.cwd();
			// prepare() checks the cache against this env; spawn() re-checks against the real one.
			const call = await wrap.prepare(cwd, params.command, piShellEnv(), { signal, timeoutSeconds: params.timeout });
			const settings = pi.getSettings();
			const bash = createBashToolDefinition(cwd, {
				commandPrefix: settings.shellCommandPrefix ?? undefined,
				shellPath: settings.shellPath ?? undefined,
				spawnHook: (spawnContext) => ({ ...spawnContext, ...call.spawn(spawnContext.command, spawnContext.env) }),
			});
			try {
				return await bash.execute(toolCallId, params, signal, onUpdate, ctx);
			} finally {
				call.cleanup();
			}
		},
	});
}
