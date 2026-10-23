import { readFileSync, realpathSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Agents wrote `timeout 300 vitest ... | tail` in 283 sessions (2026-10-07..21);
// macOS had no `timeout`, the pipe hid "command not found", and the call looked
// green. About a quarter of test, typecheck and build calls also skipped `heavy`.
// The guard reads the command the way a shell does: quotes, heredoc bodies and
// comments are data, not commands. It checks the command word of every simple
// command after wrappers (env, VAR=, nohup, sudo, heavy --, xargs, ...), and
// re-reads the script argument of `sh -c` / `bash -c` and `$(...)` bodies.

const LINUX_ONLY = {
	timeout: "Set command limits with the bash tool `timeout` parameter (seconds).",
	gtimeout: "Set command limits with the bash tool `timeout` parameter (seconds).",
	setsid: "It does not exist on this Mac. Start background work with `nohup <cmd> > <log> 2>&1 &`.",
	nproc: "Use `sysctl -n hw.ncpu`.",
} as const;
type LinuxOnlyWord = keyof typeof LINUX_ONLY;
// Own keys only: `in` would also match "toString" and other prototype names.
const isLinuxOnly = (word: string): word is LinuxOnlyWord => Object.hasOwn(LINUX_ONLY, word);

export type Finding =
	| { kind: "linux-only"; word: LinuxOnlyWord }
	| { kind: "needs-heavy"; segment: string; fix: string }
	| { kind: "destructive"; reason: string }
	| { kind: "bsd-sed"; fix: string };

/** dynamic: the word holds a command substitution (its text shows "_" there). */
type Word = { text: string; start: number; end: number; dynamic?: boolean };
/** depth: subshell nesting, for cd tracking. */
type Segment = { words: Word[]; source: string; depth: number };

const SHELLS = new Set(["sh", "bash", "zsh", "dash"]);
const KEYWORDS = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"]);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/** Split a command string into simple commands (word lists), like a shell. */
export function parseSegments(source: string, baseDepth = 0): Segment[] {
	const segments: Segment[] = [];
	let words: Word[] = [];
	let word: Word | undefined;
	const pendingHeredocs: { tag: string; strip: boolean }[] = [];
	let depth = baseDepth;
	const add = (ch: string, at: number) => {
		if (!word) word = { text: "", start: at, end: at };
		word.text += ch;
		word.end = at + 1;
	};
	const endWord = () => {
		if (word) words.push(word);
		word = undefined;
	};
	const endSegment = () => {
		endWord();
		if (words.length) segments.push({ words, source, depth });
		words = [];
	};
	// Returns the index of the matching close of a `$(` that opens at i.
	const closeParen = (i: number) => {
		let depth = 1;
		let quote = "";
		for (let j = i; j < source.length; j++) {
			const c = source[j];
			if (quote) {
				if (c === "\\" && quote === '"') j++;
				else if (c === quote) quote = "";
			} else if (c === "'" || c === '"') quote = c;
			else if (c === "\\") j++;
			else if (c === "(") depth++;
			else if (c === ")" && --depth === 0) return j;
		}
		return source.length;
	};
	const substitution = (i: number) => {
		// `$(...)` or backticks: parse the body as its own command list.
		if (source[i] === "`") {
			const close = source.indexOf("`", i + 1);
			const end = close < 0 ? source.length : close;
			segments.push(...parseSegments(source.slice(i + 1, end), depth + 1));
			add("_", i);
			word!.dynamic = true;
			return end;
		}
		const end = closeParen(i + 2);
		segments.push(...parseSegments(source.slice(i + 2, end), depth + 1));
		add("_", i);
		word!.dynamic = true;
		return end;
	};

	for (let i = 0; i < source.length; i++) {
		const c = source[i];
		if (c === "\\") {
			if (source[i + 1] !== "\n") add(source[i + 1] ?? "", i);
			i++;
		} else if (c === "'") {
			const close = source.indexOf("'", i + 1);
			const end = close < 0 ? source.length : close;
			add("", i);
			word!.text += source.slice(i + 1, end);
			word!.end = end + 1;
			i = end;
		} else if (c === '"') {
			add("", i);
			let j = i + 1;
			for (; j < source.length && source[j] !== '"'; j++) {
				if (source[j] === "\\") add(source[++j] ?? "", j);
				else if (source[j] === "`" || (source[j] === "$" && source[j + 1] === "(")) j = substitution(j);
				else add(source[j], j);
			}
			word!.end = j + 1;
			i = j;
		} else if (c === "`" || (c === "$" && source[i + 1] === "(")) {
			i = substitution(i);
		} else if (c === "#" && !word) {
			while (i + 1 < source.length && source[i + 1] !== "\n") i++;
		} else if (c === "<" && source[i + 1] === "<" && source[i + 2] !== "<") {
			// Heredoc: remember the tag; its body starts after the next newline.
			endWord();
			let j = i + 2;
			const strip = source[j] === "-";
			if (strip) j++;
			while (source[j] === " " || source[j] === "\t") j++;
			const tagMatch = /^(['"]?)([^\s'";&|<>()]+)\1/.exec(source.slice(j));
			if (tagMatch) {
				pendingHeredocs.push({ tag: tagMatch[2], strip });
				j += tagMatch[0].length;
			}
			i = j - 1;
		} else if (c === ">" || c === "<") {
			// Redirection: drop the operator, a leading fd number, and the target.
			if (word && /^\d+$/.test(word.text)) word = undefined;
			endWord();
			let j = i + 1;
			if (source[j] === ">" || source[j] === "&" || source[j] === "|") j++;
			while (source[j] === " " || source[j] === "\t") j++;
			while (j < source.length && !/[\s;&|()<>]/.test(source[j])) j++;
			i = j - 1;
		} else if (c === "&" && source[i + 1] === ">") {
			endWord();
			let j = i + 2;
			if (source[j] === ">") j++;
			while (source[j] === " " || source[j] === "\t") j++;
			while (j < source.length && !/[\s;&|()<>]/.test(source[j])) j++;
			i = j - 1;
		} else if (c === "\n") {
			endSegment();
			for (const { tag, strip } of pendingHeredocs.splice(0)) {
				// Skip body lines up to the line that holds only the tag.
				while (i < source.length) {
					const next = source.indexOf("\n", i + 1);
					const lineEnd = next < 0 ? source.length : next;
					const line = source.slice(i + 1, lineEnd);
					i = lineEnd;
					if ((strip ? line.replace(/^\t+/, "") : line).trim() === tag) break;
				}
			}
		} else if (";&|()".includes(c)) {
			endSegment();
			if (c === "(") depth++;
			else if (c === ")") depth = Math.max(baseDepth, depth - 1);
		} else if (c === " " || c === "\t") {
			endWord();
		} else {
			add(c, i);
		}
	}
	endSegment();
	return segments;
}

const base = (w: string) => w.slice(w.lastIndexOf("/") + 1);

/** Skip options; `valued` options consume the next word. */
function skipOptions(words: Word[], i: number, valued: Set<string>): number {
	while (i < words.length && words[i].text.startsWith("-") && words[i].text !== "--") {
		i += valued.has(words[i].text) ? 2 : 1;
	}
	return i;
}

const HEAVY_SCRIPT = /^(?:test|typecheck|build|verify)(?::\S*)?$/;
const PM_VALUED = new Set(["--filter", "-F", "-C", "--dir", "--cwd", "--prefix", "--workspace", "-w"]);
const UV_VALUED = new Set(["--with", "--package", "--project", "--directory", "-p", "--python", "--group", "--extra"]);
const CARGO_VALUED = new Set(["--manifest-path", "-Z", "--config", "-C", "--color"]);
const CARGO_HEAVY = new Set(["test", "t", "build", "b", "check", "c", "clippy", "nextest"]);
const INFO_FLAGS = new Set(["--help", "-h", "--version", "-v", "-V", "--init"]);
const NIX_VALUED = new Set(["--extra-experimental-features", "--experimental-features", "--store", "--eval-store", "--log-format", "--max-jobs", "-j", "--cores", "--builders", "--system"]);

/** Whether argv (wrappers already removed) is a test, typecheck or build run. */
function isHeavyCommand(words: Word[], i: number): boolean {
	const cmd = base(words[i]?.text ?? "");
	const next = (k = 1) => words[i + k]?.text;
	// Package runners: run the tool they name.
	if (cmd === "npx" || cmd === "bunx" || cmd === "pnpx") return isHeavyCommand(words, skipOptions(words, i + 1, PM_VALUED));
	if (cmd === "uv" || cmd === "poetry") {
		if (next() !== "run") return false;
		return isHeavyCommand(words, skipOptions(words, i + 2, UV_VALUED));
	}
	if (/^python3?(\.\d+)?$/.test(cmd)) return next() === "-m" && next(2) === "pytest";
	if (cmd === "vitest" || cmd === "tsc") return !INFO_FLAGS.has(next() ?? "");
	if (cmd === "pytest" || cmd === "py.test") return !INFO_FLAGS.has(next() ?? "");
	if (cmd === "go") return next() === "test";
	if (cmd === "nix") {
		// nix build and nix flake check build derivations. run, shell, eval and other flake subcommands stay allowed.
		let j = i + 1;
		while (j < words.length && words[j].text.startsWith("-")) {
			const w = words[j].text;
			j += w === "--option" ? 3 : NIX_VALUED.has(w) ? 2 : 1;
		}
		const sub = words[j]?.text;
		const rest = words.slice(j + 1).map((w) => w.text);
		if (rest.includes("--help")) return false;
		return sub === "build" || (sub === "flake" && rest[0] === "check");
	}
	if (cmd === "cargo") {
		let j = i + 1;
		if (words[j]?.text.startsWith("+")) j++;
		j = skipOptions(words, j, CARGO_VALUED);
		return CARGO_HEAVY.has(words[j]?.text ?? "");
	}
	if (cmd === "turbo") {
		let j = skipOptions(words, i + 1, PM_VALUED);
		if (words[j]?.text === "run") j++;
		for (; j < words.length && !words[j].text.startsWith("-"); j++) {
			if (HEAVY_SCRIPT.test(words[j].text)) return true;
		}
		return false;
	}
	if (cmd === "bun" || cmd === "npm" || cmd === "pnpm" || cmd === "yarn") {
		let j = skipOptions(words, i + 1, PM_VALUED);
		let sub = words[j]?.text ?? "";
		if (sub === "exec" || sub === "dlx" || (cmd === "bun" && sub === "x")) {
			return isHeavyCommand(words, skipOptions(words, j + 1, PM_VALUED));
		}
		if (sub === "run" || sub === "run-script") {
			j = skipOptions(words, j + 1, PM_VALUED);
			return HEAVY_SCRIPT.test(words[j]?.text ?? "");
		}
		if (sub === "t") sub = "test";
		if (HEAVY_SCRIPT.test(sub)) return true;
		// pnpm, yarn and bun run unknown words as tools from node_modules/.bin.
		return cmd !== "npm" && (sub === "vitest" || sub === "tsc" || sub === "turbo") && isHeavyCommand(words, j);
	}
	return false;
}

function checkSegment(segment: Segment, insideHeavy: boolean): Finding | undefined {
	const { words, source } = segment;
	let heavy = insideHeavy;
	let i = 0;
	while (i < words.length) {
		const w = words[i].text;
		const cmd = base(w);
		if (KEYWORDS.has(w) || ASSIGNMENT.test(w)) i++;
		else if (cmd === "nohup" || cmd === "exec" || cmd === "time" || cmd === "caffeinate") i = skipOptions(words, i + 1, new Set(["-a"]));
		else if (cmd === "sudo") i = skipOptions(words, i + 1, new Set(["-u", "-g"]));
		else if (cmd === "nice") i = skipOptions(words, i + 1, new Set(["-n"]));
		else if (cmd === "env") {
			i = skipOptions(words, i + 1, new Set(["-u", "-C"]));
			while (i < words.length && ASSIGNMENT.test(words[i].text)) i++;
		} else if (cmd === "xargs") i = skipOptions(words, i + 1, new Set(["-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a"]));
		else if (cmd === "command") {
			if (words[i + 1]?.text === "-v" || words[i + 1]?.text === "-V") return undefined;
			i++;
		} else if (cmd === "heavy") {
			heavy = true;
			i = skipOptions(words, i + 1, new Set(["--slots"]));
			if (words[i]?.text === "--") i++;
		} else break;
	}
	const word = words[i];
	if (!word) return undefined;
	const cmd = base(word.text);
	if (isLinuxOnly(cmd)) return { kind: "linux-only", word: cmd };
	if (cmd === "sed") {
		// /usr/bin/sed is BSD: it reads the word after -i as the backup suffix, so the
		// GNU form `sed -i 's/a/b/' f` fails (128 errors in 121 sessions, 2026-10-01..22).
		const k = words.findIndex((w, j) => j > i && /^-[A-Za-z]*i$/.test(w.text));
		const suffix = words[k + 1]?.text;
		if (k > i && suffix !== undefined && suffix !== "" && !suffix.startsWith(".")) {
			const last = words[words.length - 1];
			return { kind: "bsd-sed", fix: source.slice(words[0].start, words[k].end) + " ''" + source.slice(words[k].end, last.end) };
		}
	}
	if (SHELLS.has(cmd)) {
		// `bash -c 'script'`: check the script with the same heavy context.
		for (let j = i + 1; j < words.length && words[j].text.startsWith("-"); j++) {
			if (/^-[a-z]*c[a-z]*$/.test(words[j].text) && words[j + 1]) return checkCommand(words[j + 1].text, heavy);
		}
		return undefined;
	}
	if (!heavy && isHeavyCommand(words, i)) {
		const last = words[words.length - 1];
		const prefix = source.slice(words[0].start, word.start);
		const rest = source.slice(word.start, last.end);
		return { kind: "needs-heavy", segment: prefix + rest, fix: `${prefix}heavy -- ${rest}` };
	}
	return undefined;
}

export function checkCommand(command: string, insideHeavy = false): Finding | undefined {
	for (const segment of parseSegments(command)) {
		const finding = checkSegment(segment, insideHeavy);
		if (finding) return finding;
	}
	return undefined;
}


// Destructive commands (owner decision 2026-10-23; replaces the pi-hooks
// permission prompts, which stalled unattended agents). Nothing here prompts.
// A delete, overwrite or discard runs when every target is inside the linked
// git worktree the command runs in, or inside a temp dir. Anything else is
// blocked at once with a recoverable alternative. Irreversible commands
// outside the file system are always blocked.
// Limits: the directory after cd is tracked through literal paths and
// subshells only (not through `false && cd x` or a cd inside a pipeline). A
// target with a variable or command substitution counts as unknown; only
// $TMPDIR and $HOME are expanded.

type Dir = string | undefined;

/** The path with symlinks resolved in its existing part; the rest stays lexical. */
function canonical(p: string): string {
	const rest: string[] = [];
	for (let head = p; ; ) {
		try {
			return join(realpathSync(head), ...rest);
		} catch {
			const parent = dirname(head);
			if (parent === head) return p;
			rest.unshift(basename(head));
			head = parent;
		}
	}
}

/** Root of the linked git worktree that contains dir; a main checkout gives undefined. */
export function linkedWorktree(dir: string): string | undefined {
	for (let d = canonical(dir); dirname(d) !== d; d = dirname(d)) {
		const git = join(d, ".git");
		let isFile: boolean;
		try {
			isFile = statSync(git).isFile();
		} catch {
			continue;
		}
		// A linked worktree has a .git file that points into <main>/.git/worktrees/<name>.
		return isFile && /^gitdir: .*\/worktrees\/[^/\n]+\s*$/.test(readFileSync(git, "utf8")) ? d : undefined;
	}
	return undefined;
}

const within = (p: string, root: string) => p.startsWith(root + "/");
const tempRoots = () => [...new Set([tmpdir(), "/tmp"].map(canonical))];
const VARS = /\$(?:\{(TMPDIR|HOME)\}|(TMPDIR|HOME)\b)/g;
const isDynamic = (w: Word) => !!w.dynamic || /[$`]/.test(w.text);

/** Why a delete target is not allowed, or undefined when it is. */
function targetProblem(w: Word, dir: Dir, home: string, temps: string[], underRoot: boolean): string | undefined {
	let t = w.text.replace(VARS, (_m, braced?: string, bare?: string) =>
		(braced ?? bare) === "HOME" ? home : (process.env.TMPDIR ?? tmpdir()),
	);
	if (w.dynamic || /[$`]/.test(t)) return w.text + " (computed)";
	if (t === "~" || t.startsWith("~/")) t = home + t.slice(1);
	else if (t.startsWith("~")) return w.text;
	if (!isAbsolute(t) && dir === undefined) return w.text + " (directory unknown after a computed cd)";
	const glob = t.search(/[*?[]/);
	// A glob cannot leave its literal prefix except through "..", and a dotfile glob can match .git.
	if (glob >= 0 && (t.split("/").includes("..") || basename(t).startsWith("."))) return w.text;
	const from = dir ?? "/";
	let path: string;
	if (glob >= 0) {
		const prefix = t.slice(0, glob);
		path = prefix === "" || prefix.endsWith("/") ? resolve(from, prefix || ".") : dirname(resolve(from, prefix));
	} else path = resolve(from, t);
	path = canonical(path);
	const worktree = dir === undefined ? undefined : linkedWorktree(dir);
	if (worktree && !(path === join(worktree, ".git") || within(path, join(worktree, ".git")))) {
		// A glob or a find start may be the worktree root (rm -rf *, find . -delete); the root itself stays.
		if (within(path, worktree) || ((glob >= 0 || underRoot) && path === worktree)) return undefined;
	}
	if (temps.some((root) => within(path, root))) return undefined;
	return w.text;
}

function optionsEnd(words: Word[], i: number): number {
	while (i < words.length && words[i].text.startsWith("-") && words[i].text.length > 1) {
		if (words[i++].text === "--") break;
	}
	return i;
}

/** Words a path-checked command deletes or overwrites; undefined: not a delete. find deletes below its start dirs. */
function deleteTargets(cmd: string, args: Word[]): Word[] | undefined {
	const texts = args.map((a) => a.text);
	if (cmd === "rm" || cmd === "rmdir" || cmd === "unlink" || cmd === "shred") return args.slice(optionsEnd(args, 0));
	if (cmd === "truncate") return args.filter((a, k) => !a.text.startsWith("-") && texts[k - 1] !== "-s" && texts[k - 1] !== "-r");
	if (cmd === "chmod" || cmd === "chown") {
		if (!texts.some((t) => t === "--recursive" || /^-[A-Za-z]*R/.test(t))) return undefined;
		return args.slice(optionsEnd(args, 0) + 1);
	}
	if (cmd === "find") {
		if (!texts.some((t) => ["-delete", "-exec", "-execdir", "-ok", "-okdir"].includes(t))) return undefined;
		const end = args.findIndex((a) => /^[-(!]/.test(a.text));
		const starts = args.slice(0, end < 0 ? args.length : end);
		return starts.length ? starts : [{ text: ".", start: 0, end: 0 }];
	}
	if (cmd === "rsync") {
		if (!texts.some((t) => t.startsWith("--delete"))) return undefined;
		const dest = args.filter((a) => !a.text.startsWith("-")).at(-1);
		return dest ? [dest] : [];
	}
	return undefined;
}

const destructive = (reason: string): Finding => ({ kind: "destructive", reason });
const never = (what: string) =>
	destructive("`" + what + "` is blocked in agent commands because it cannot be undone. Report it, so the owner can run it.");

function gitFinding(args: Word[], dir: Dir): Finding | undefined {
	let repo = dir;
	let i = 0;
	while (i < args.length && args[i].text.startsWith("-")) {
		const a = args[i].text;
		if (a === "-C") {
			const d = args[i + 1];
			repo = !d || isDynamic(d) || (repo === undefined && !isAbsolute(d.text)) ? undefined : resolve(repo ?? "/", d.text);
			i += 2;
		} else if (a === "-c") i += 2;
		else if (a.startsWith("--git-dir") || a.startsWith("--work-tree")) {
			repo = undefined;
			i += a.includes("=") ? 1 : 2;
		} else i++;
	}
	const sub = args[i]?.text;
	const rest = args.slice(i + 1).map((w) => w.text);
	if (sub === "push" && rest.some((r) => r === "-f" || r.startsWith("--force") || (r.startsWith("+") && r.length > 1))) return never("git push --force");
	let discards = false;
	if (sub === "clean") discards = !rest.some((r) => r === "--dry-run" || /^-[A-Za-z]*n/.test(r));
	else if (sub === "reset") discards = rest.includes("--hard");
	else if (sub === "restore") discards = !(rest.some((r) => r === "--staged" || r === "-S") && !rest.some((r) => r === "--worktree" || r === "-W"));
	else if (sub === "checkout") discards = rest.some((r) => r === "--" || r === "." || r === "-f" || r === "--force");
	if (!discards || (repo !== undefined && linkedWorktree(repo))) return undefined;
	return destructive(
		"`git " + sub + "` discards changes, and " + (repo ?? "this directory") + " is not in a linked worktree. Run `git stash` first, or work in a linked worktree.",
	);
}

const DOCKER_NEVER = new Set(["rm", "container rm", "system prune", "volume prune"]);

function destructiveIn(segments: Segment[], start: Dir, home: string, temps: string[]): Finding | undefined {
	let dir = start;
	let depth = 0;
	const saved: Dir[] = [];
	for (const { words, depth: d } of segments) {
		for (; depth < d; depth++) saved.push(dir);
		for (; depth > d; depth--) dir = saved.pop();
		let i = 0;
		let fromStdin = false;
		while (i < words.length) {
			const cmd = base(words[i].text);
			if (KEYWORDS.has(words[i].text) || ASSIGNMENT.test(words[i].text) || cmd === "builtin") i++;
			else if (cmd === "sudo") return never("sudo");
			else if (cmd === "nohup" || cmd === "exec" || cmd === "time" || cmd === "caffeinate") i = skipOptions(words, i + 1, new Set(["-a"]));
			else if (cmd === "nice") i = skipOptions(words, i + 1, new Set(["-n"]));
			else if (cmd === "env") {
				i = skipOptions(words, i + 1, new Set(["-u", "-C"]));
				while (i < words.length && ASSIGNMENT.test(words[i].text)) i++;
			} else if (cmd === "xargs") {
				fromStdin = true;
				i = skipOptions(words, i + 1, new Set(["-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a"]));
			} else if (cmd === "command") {
				if (words[i + 1]?.text === "-v" || words[i + 1]?.text === "-V") break;
				i++;
			} else if (cmd === "heavy") {
				i = skipOptions(words, i + 1, new Set(["--slots"]));
				if (words[i]?.text === "--") i++;
			} else break;
		}
		const word = words[i];
		if (!word) continue;
		const cmd = base(word.text);
		const args = words.slice(i + 1);
		if (cmd === "cd" || cmd === "pushd") {
			const a = args[optionsEnd(args, 0)];
			if (!a) dir = home;
			else if (a.text === "-" || isDynamic(a)) dir = undefined;
			else {
				const t = a.text === "~" || a.text.startsWith("~/") ? home + a.text.slice(1) : a.text;
				dir = isAbsolute(t) ? t : dir === undefined ? undefined : resolve(dir, t);
			}
			continue;
		}
		if (cmd === "popd") {
			dir = undefined;
			continue;
		}
		if (SHELLS.has(cmd) || cmd === "eval") {
			const flag = args.findIndex((a) => /^-[a-z]*c[a-z]*$/.test(a.text));
			const script = cmd === "eval" ? args.map((a) => a.text).join(" ") : flag >= 0 ? args[flag + 1]?.text : undefined;
			const inner = script === undefined ? undefined : destructiveIn(parseSegments(script), dir, home, temps);
			if (inner) return inner;
			continue;
		}
		const texts = args.map((a) => a.text);
		const sub = texts.filter((t) => !t.startsWith("-"));
		if (cmd === "dd" || cmd === "wipefs" || cmd.startsWith("mkfs")) return never(cmd);
		if (cmd === "kubectl" && sub[0] === "delete") return never("kubectl delete");
		if ((cmd === "terraform" || cmd === "pulumi") && sub[0] === "destroy") return never(cmd + " destroy");
		if (cmd === "docker" && (DOCKER_NEVER.has(sub[0] ?? "") || DOCKER_NEVER.has(sub.slice(0, 2).join(" ")))) {
			return never("docker " + (sub[0] === "rm" ? "rm" : sub.slice(0, 2).join(" ")));
		}
		if (cmd === "git") {
			const g = gitFinding(args, dir);
			if (g) return g;
			continue;
		}
		const targets = deleteTargets(cmd, args);
		if (!targets) continue;
		const remote = cmd === "rsync" ? targets.find((t) => /^[^/]*:/.test(t.text)) : undefined;
		const problem = fromStdin ? "(targets from xargs)" : remote ? remote.text : targets.map((t) => targetProblem(t, dir, home, temps, cmd === "find")).find((p) => p !== undefined);
		if (problem !== undefined) {
			return destructive(
				"`" + cmd + "` with a target outside this linked worktree and temp dirs is blocked: " + problem +
					". Use `trash <path>` instead (recoverable from the Trash), or run it inside your own linked worktree.",
			);
		}
	}
	return undefined;
}

/** A destructive command that would act outside the worktree it runs in. */
export function checkDestructive(command: string, cwd: string, home = homedir(), temps = tempRoots()): Finding | undefined {
	return destructiveIn(parseSegments(command), cwd, home, temps.map(canonical));
}

export function blockReason(finding: Finding): string {
	if (finding.kind === "destructive") return finding.reason;
	if (finding.kind === "bsd-sed") {
		return `macOS sed is BSD sed: it reads the word after \`-i\` as the backup suffix. Use \`${finding.fix}\`, or \`perl -pi -e\`.`;
	}
	if (finding.kind === "linux-only") {
		return `\`${finding.word}\` is blocked in agent commands. ${LINUX_ONLY[finding.word]} Start piped checks with \`set -o pipefail\`.`;
	}
	return `Run typecheck, test and build commands through heavy: \`${finding.fix}\`. Size the bash tool \`timeout\` as the expected runtime plus the heavy wait.`;
}

export default function shellGuard(pi: ExtensionAPI) {
	pi.on("tool_call", (event, ctx) => {
		if (event.toolName !== "bash") return;
		const command = (event.input as { command?: unknown }).command;
		if (typeof command !== "string") return;
		const finding = checkCommand(command) ?? checkDestructive(command, ctx?.cwd ?? process.cwd());
		if (!finding) return;
		return { block: true, reason: blockReason(finding) };
	});
}
