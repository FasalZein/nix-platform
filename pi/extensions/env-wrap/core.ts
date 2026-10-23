// env-wrap core: run each agent bash call in the direnv/devenv env of the
// worktree it runs in. pi bash calls are non-interactive, so direnv's prompt
// hook never fires. A plain `direnv exec <wt> <cmd>` costs ~0.75 s warm and
// 4-6 s cold per call, because devenv's direnvrc runs `devenv direnv-export` on
// every load. So this module caches the result of `direnv export json` per
// .envrc and reuses it while every file direnv watches is unchanged (direnv's
// own reload rule; the watch list includes .envrc, devenv.nix, devenv.yaml,
// devenv.lock, devenv.local.*, and direnv's allow/deny files). The
// nix-platform input rev is pinned in devenv.lock, so it is covered.
//
// Flow per call: prepare() finds the .envrc of the cwd and of every literal
// `cd <dir>` target in the command, and refreshes stale cache entries. spawn()
// then builds a shell prefix: cd/pushd/popd hooks plus a per-call file that
// applies the cached envs. A cd to a target that was not prepared (for example
// `cd "$X"`) loads through `direnv export bash` in the shell: correct, uncached.
//
// Limits: bash is the only supported shell. `git -C`, `pnpm --dir` and child
// shells do not switch env. A .envrc reached through a symlinked path loads
// through direnv (uncached). Cache files hold the exported env (it can include
// .env secrets when a repo enables devenv dotenv), so they are mode 0600.
import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { stripVTControlCharacters } from "node:util";
import { inflateSync } from "node:zlib";
import { parseSegments } from "../shell-guard.ts";

export type Env = Record<string, string | undefined>;
type Vars = Record<string, string | null>;

/** One cached `direnv export json` result for one .envrc. */
export type Entry = {
	version: 1;
	envrc: string;
	/** Files direnv watches (from DIRENV_WATCHES). */
	watches: string[];
	/** Stat signature of the watches; "" means: do not reuse. */
	sig: string;
	/** Base values the export was computed from (null = unset). */
	prev: Vars;
	/** Values to apply (null = unset). Empty when error is set. */
	next: Vars;
	/** The .envrc is blocked or failed: commands run without its env. */
	error?: string;
};

// direnv state variables. direnv keeps them out of DIRENV_DIFF.
const STATE_KEYS = ["DIRENV_DIR", "DIRENV_FILE", "DIRENV_DIFF", "DIRENV_WATCHES"];
const NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const q = (s: string) => "'" + s.replace(/'/g, "'\\''") + "'";

// cd/pushd/popd switch to the env of the nearest .envrc, as direnv's prompt
// hook does in an interactive shell. __envwrap_load (redefined per call)
// applies a prepared env; other .envrc files load through direnv itself.
const HOOK = [
	'__envwrap_load() { return 1; }',
	'__envwrap_switch() {',
	'  local d="$PWD" rc=',
	'  while [ -n "$d" ]; do',
	'    if [ -f "$d/.envrc" ]; then rc="$d/.envrc"; break; fi',
	'    d="${d%/*}"',
	'  done',
	'  [ "$rc" = "${DIRENV_FILE-}" ] && return 0',
	'  if [ -n "${DIRENV_DIFF-}" ]; then eval "$(builtin cd / && DIRENV_LOG_FORMAT= direnv export bash)"; fi',
	'  [ -n "$rc" ] || return 0',
	'  __envwrap_load "$rc" || eval "$(DIRENV_LOG_FORMAT= direnv export bash)"',
	'  return 0',
	'}',
	'cd() { builtin cd "$@" && __envwrap_switch; }',
	'pushd() { builtin pushd "$@" && __envwrap_switch; }',
	'popd() { builtin popd "$@" && __envwrap_switch; }',
].join("\n");

/** Decode direnv's gzenv format (base64url of zlib-compressed JSON). */
function gzenv(value: string): unknown {
	return JSON.parse(inflateSync(Buffer.from(value, "base64url")).toString("utf8"));
}

/** The env before direnv: undo a DIRENV_DIFF that pi inherited from its shell. */
export function cleanBase(env: Env): Env {
	const out: Env = { ...env };
	if (env.DIRENV_DIFF) {
		try {
			const diff = gzenv(env.DIRENV_DIFF) as { p?: Record<string, string>; n?: Record<string, string> };
			const p = diff.p ?? {};
			for (const k of new Set([...Object.keys(p), ...Object.keys(diff.n ?? {})])) {
				if (Object.hasOwn(p, k)) out[k] = p[k];
				else delete out[k];
			}
		} catch {
			// Unreadable diff: keep the values, drop only the state keys.
		}
	}
	for (const k of STATE_KEYS) delete out[k];
	return out;
}

const isDir = (p: string) => {
	try {
		return statSync(p).isDirectory();
	} catch {
		return false;
	}
};
const isFile = (p: string) => {
	try {
		return statSync(p).isFile();
	} catch {
		return false;
	}
};

/** The nearest .envrc at or above dir (the filesystem root is not checked). */
export function findEnvrc(dir: string): string | undefined {
	for (let d = dir; dirname(d) !== d; d = dirname(d)) {
		const rc = join(d, ".envrc");
		if (isFile(rc)) return rc;
	}
	return undefined;
}

const SKIP = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "builtin", "command"]);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;
// A word with a variable, command substitution or glob is not a literal path.
const DYNAMIC = /[$`*?[]/;

/** Existing directories named by literal cd/pushd words, resolved in order. */
export function cdTargets(command: string, cwd: string, home: string): string[] {
	const out: string[] = [];
	let dir = cwd;
	for (const { words } of parseSegments(command)) {
		let i = 0;
		while (i < words.length && (SKIP.has(words[i].text) || ASSIGNMENT.test(words[i].text))) i++;
		if (words[i]?.text !== "cd" && words[i]?.text !== "pushd") continue;
		let j = i + 1;
		while (j < words.length && words[j].text.startsWith("-") && words[j].text !== "-") {
			if (words[j++].text === "--") break;
		}
		let arg = words[j]?.text ?? home;
		if (arg === "-" || DYNAMIC.test(arg)) continue;
		if (arg === "~" || arg.startsWith("~/")) arg = home + arg.slice(1);
		else if (arg.startsWith("~")) continue;
		const target = resolve(dir, arg);
		if (!isDir(target)) continue;
		dir = target;
		out.push(target);
	}
	return out;
}

function statSig(paths: string[]): string {
	return paths
		.map((p) => {
			try {
				const s = statSync(p, { bigint: true });
				return [p, s.size, s.mtimeNs, s.ctimeNs].join("\0");
			} catch {
				return p + "\0-";
			}
		})
		.join("\n");
}

const prevMatches = (e: Entry, base: Env) => Object.entries(e.prev).every(([k, v]) => (base[k] ?? null) === v);

type Run = { code: number | null; stdout: string; stderr: string; spawnError?: string };

function runCmd(bin: string, args: string[], cwd: string, env: Env, signal: AbortSignal): Promise<Run> {
	return new Promise((done) => {
		let stdout = "";
		let stderr = "";
		const child = spawn(bin, args, { cwd, env: env as NodeJS.ProcessEnv, signal, stdio: ["ignore", "pipe", "pipe"] });
		child.stdout.on("data", (b) => (stdout += b));
		child.stderr.on("data", (b) => (stderr += b));
		child.on("error", (err) => done({ code: null, stdout, stderr, spawnError: err.message }));
		child.on("close", (code) => done({ code, stdout, stderr }));
	});
}

export type PrepareOptions = { signal?: AbortSignal; timeoutSeconds?: number };

/** The part of `direnv status --json` this module reads. */
type DirenvStatus = { state?: { foundRC?: { path?: string; allowed?: number } | null } };

export type Prepared = {
	/** Build the command and env for the spawn. env is pi's real spawn env. */
	spawn(command: string, env: Env): { command: string; env: Env };
	/** Remove the per-call file. */
	cleanup(): void;
};

export class EnvWrap {
	readonly stateDir: string;
	readonly direnv: string;
	readonly home: string;
	private memory = new Map<string, Entry>();
	private calls = 0;

	constructor(opts: { stateDir: string; direnv?: string; home?: string }) {
		this.stateDir = opts.stateDir;
		this.direnv = opts.direnv ?? "direnv";
		this.home = opts.home ?? process.env.HOME ?? "/";
	}

	private cacheFile(envrc: string) {
		return join(this.stateDir, "cache", createHash("sha256").update(envrc).digest("hex") + ".json");
	}

	private fresh(e: Entry | undefined, base: Env): e is Entry {
		return !!e && e.version === 1 && e.sig !== "" && prevMatches(e, base) && statSig(e.watches) === e.sig;
	}

	private readDisk(envrc: string): Entry | undefined {
		try {
			return JSON.parse(readFileSync(this.cacheFile(envrc), "utf8")) as Entry;
		} catch {
			return undefined;
		}
	}

	private writeDisk(e: Entry) {
		const file = this.cacheFile(e.envrc);
		mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
		const tmp = file + "." + process.pid + "." + randomBytes(4).toString("hex") + ".tmp";
		writeFileSync(tmp, JSON.stringify(e), { mode: 0o600 });
		renameSync(tmp, file);
	}

	/** Run direnv export json for one .envrc and record the result. */
	private async refresh(envrc: string, base: Env, signal: AbortSignal): Promise<Entry> {
		const r = await runCmd(this.direnv, ["export", "json"], dirname(envrc), { ...base, DIRENV_LOG_FORMAT: "" }, signal);
		let out: Vars = {};
		try {
			out = r.stdout.trim() ? (JSON.parse(r.stdout) as Vars) : {};
		} catch {
			out = {};
		}
		let watches: string[] = [];
		let sig = "";
		try {
			const list = gzenv(out.DIRENV_WATCHES ?? "") as { path: string; modtime: number; exists: boolean }[];
			watches = list.map((w) => w.path);
			sig = statSig(watches);
			// A watch that changed while direnv ran: use the result once, do not cache it.
			const changed = list.some((w) => {
				try {
					const s = statSync(w.path, { bigint: true });
					return !w.exists || Number(s.mtimeNs / 1_000_000_000n) !== w.modtime;
				} catch {
					return w.exists;
				}
			});
			if (changed) sig = "";
		} catch {
			sig = "";
		}
		const failed = r.code !== 0;
		const error = r.spawnError
			? "cannot run " + this.direnv + ": " + r.spawnError
			: failed
				? stripVTControlCharacters(r.stderr).trim() || "direnv exited " + r.code
				: undefined;
		// A blocked .envrc is checked again on every call: the main checkout's
		// approval can change without any watched file changing.
		if (error?.includes("is blocked")) sig = "";
		// A failed load records only the state keys, so it is not retried until a watch changes.
		const next: Vars = failed ? {} : out;
		const prev: Vars = {};
		for (const k of Object.keys(out)) prev[k] = base[k] ?? null;
		const entry: Entry = { version: 1, envrc, watches, sig, prev, next };
		if (error) entry.error = error;
		if (sig !== "" && !r.spawnError && !signal.aborted) this.writeDisk(entry);
		return entry;
	}

	/**
	 * Owner decision 2026-10-23: a linked worktree inherits the trust of its
	 * repo's main checkout. Allow its .envrc when the main checkout has the same
	 * .envrc at the same path and direnv reports that one as allowed.
	 * Returns why it did not allow, or "" after a successful direnv allow.
	 */
	private async allowFromMain(envrc: string, base: Env, signal: AbortSignal): Promise<string> {
		const dir = dirname(envrc);
		const git = await runCmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"], dir, base, signal);
		if (git.code !== 0) return "it is not in a git checkout";
		const [common, top] = git.stdout.trim().split("\n");
		if (basename(common) !== ".git") return "its repo has no main checkout";
		const main = dirname(common);
		if (main === top) return "this is the repo's main checkout";
		const mainRc = join(main, relative(top, envrc));
		let same: boolean;
		try {
			same = readFileSync(mainRc, "utf8") === readFileSync(envrc, "utf8");
		} catch {
			return "the main checkout has no " + mainRc;
		}
		if (!same) return "it differs from " + mainRc;
		const status = await runCmd(this.direnv, ["status", "--json"], dirname(mainRc), base, signal);
		let allowed = false;
		try {
			const found = (JSON.parse(status.stdout) as DirenvStatus).state?.foundRC;
			// direnv AllowStatus: 0 = allowed, 1 = not allowed, 2 = denied.
			allowed = found?.path === mainRc && found.allowed === 0;
		} catch {
			allowed = false;
		}
		if (!allowed) return mainRc + " is not allowed either";
		const allow = await runCmd(this.direnv, ["allow", dir], dir, base, signal);
		return allow.code === 0 ? "" : "direnv allow failed: " + stripVTControlCharacters(allow.stderr).trim();
	}

	private async entry(envrc: string, base: Env, opts: PrepareOptions): Promise<{ entry: Entry; refreshed: boolean; note?: string }> {
		const mem = this.memory.get(envrc);
		if (this.fresh(mem, base)) return { entry: mem, refreshed: false };
		const disk = this.readDisk(envrc);
		if (this.fresh(disk, base)) {
			this.memory.set(envrc, disk);
			return { entry: disk, refreshed: false };
		}
		const limits = [opts.signal, opts.timeoutSeconds ? AbortSignal.timeout(opts.timeoutSeconds * 1000) : undefined];
		const signal = AbortSignal.any(limits.filter((s): s is AbortSignal => !!s));
		let entry = await this.refresh(envrc, base, signal);
		let note: string | undefined;
		if (entry.error?.includes("is blocked")) {
			const reason = await this.allowFromMain(envrc, base, signal);
			if (reason) {
				note = "env-wrap: " + envrc + " is not allowed (" + reason + "), so this command runs without its env. Report this: the owner approves a repo's .envrc.";
			} else {
				entry = await this.refresh(envrc, base, signal);
				note = "env-wrap: allowed " + dirname(envrc) + ": its .envrc matches the allowed main checkout.";
			}
		}
		this.memory.set(envrc, entry);
		return { entry, refreshed: true, note };
	}

	async prepare(cwd: string, command: string, base: Env, opts: PrepareOptions = {}): Promise<Prepared> {
		const clean = cleanBase(base);
		const rcs = new Set<string>();
		for (const dir of [cwd, ...cdTargets(command, cwd, this.home)]) {
			const rc = findEnvrc(dir);
			if (rc) rcs.add(rc);
		}
		const notes: string[] = [];
		const entries: Entry[] = [];
		for (const rc of rcs) {
			try {
				const { entry, refreshed, note } = await this.entry(rc, clean, opts);
				entries.push(entry);
				if (note) notes.push(note);
				if (entry.error && !entry.error.includes("is blocked")) {
					notes.push(
						refreshed
							? "env-wrap: " + rc + " did not load; this command runs without its env:\n" + entry.error
							: "env-wrap: " + rc + " did not load (cached result); this command runs without its env. To see the error: direnv exec " + dirname(rc) + " true",
					);
				}
			} catch (err) {
				notes.push("env-wrap: " + rc + " did not load: " + (err instanceof Error ? err.message : String(err)));
			}
		}
		let file: string | undefined;
		return {
			spawn: (cmd, env) => {
				const real = cleanBase(env);
				const branches: string[] = [];
				for (const e of entries) {
					if (e.error) {
						branches.push(q(e.envrc) + ") return 0;;");
					} else if (!prevMatches(e, real)) {
						notes.push("env-wrap: the spawn env differs from the cached base for " + e.envrc + "; loading it through direnv");
					} else {
						const lines = Object.entries(e.next)
							.filter(([k]) => NAME.test(k))
							.map(([k, v]) => (v === null ? "unset " + k : "export " + k + "=" + q(v)));
						branches.push(q(e.envrc) + ")\n" + lines.join("\n") + "\n;;");
					}
				}
				const parts = [HOOK];
				if (branches.length) {
					const dir = join(this.stateDir, "run");
					mkdirSync(dir, { recursive: true, mode: 0o700 });
					file = join(dir, process.pid + "-" + ++this.calls + "-" + randomBytes(4).toString("hex") + ".sh");
					const body = '__envwrap_load() {\ncase "$1" in\n' + branches.join("\n") + "\n*) return 1;;\nesac\n}\n";
					writeFileSync(file, body, { mode: 0o600 });
					parts.push(". " + q(file) + " || printf '%s\\n' " + q("env-wrap: cannot read " + file) + " >&2");
				}
				if (notes.length) parts.push("printf '%s\\n' " + notes.map(q).join(" ") + " >&2");
				parts.push("__envwrap_switch");
				return { command: parts.join("\n") + "\n" + cmd, env: real };
			},
			cleanup: () => {
				if (file) rmSync(file, { force: true });
			},
		};
	}
}
