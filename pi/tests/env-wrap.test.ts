import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { type Env, EnvWrap } from "../extensions/env-wrap/core.ts";

// Tests for ~/.pi/agent/extensions/env-wrap: real direnv, bash and heavy on
// fixture worktrees. Each fixture .envrc appends a line to a count file when
// direnv evaluates it, so a cache hit shows as "no new line". No sleeps.
const HEAVY = join(homedir(), ".pi/agent/bin/heavy");

function setup(t: { after(fn: () => void): void }) {
	// realpath: direnv reports /private/var/... for macOS temp dirs.
	const root = realpathSync(mkdtempSync(join(tmpdir(), "env-wrap-test-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const env: Env = {
		...process.env,
		XDG_DATA_HOME: join(root, "data"),
		XDG_CONFIG_HOME: join(root, "config"),
		DIRENV_CONFIG: join(root, "config", "direnv"),
		HEAVY_DIR: join(root, "slots"),
		HEAVY_MAX_LOAD: "1000",
	};
	// The suite runs inside heavy (and maybe a direnv env); fixtures start clean.
	for (const k of ["HEAVY_SLOT", "HEAVY_SLOTS", "DIRENV_DIR", "DIRENV_FILE", "DIRENV_DIFF", "DIRENV_WATCHES", "WT_VALUE"]) delete env[k];
	const direnv = (args: string[], cwd = root) => {
		const r = spawnSync("direnv", args, { cwd, env: env as NodeJS.ProcessEnv, encoding: "utf8" });
		assert.equal(r.status, 0, r.stderr);
		return r.stdout;
	};
	const worktree = (name: string, value: string, opts: { allow?: boolean; extra?: string } = {}) => {
		const dir = join(root, name);
		mkdirSync(join(dir, "bin"), { recursive: true });
		writeFileSync(join(dir, "devenv.nix"), value);
		const rc = ["watch_file devenv.nix", "PATH_add bin", 'export WT_VALUE="$(cat devenv.nix)"', "echo x >> '" + join(root, "count-" + name) + "'"];
		if (opts.extra) rc.push(opts.extra);
		writeFileSync(join(dir, ".envrc"), rc.join("\n") + "\n");
		if (opts.allow !== false) direnv(["allow", dir]);
		return dir;
	};
	const count = (name: string) => {
		const f = join(root, "count-" + name);
		return existsSync(f) ? readFileSync(f, "utf8").split("\n").filter(Boolean).length : 0;
	};
	const plain = join(root, "plain");
	mkdirSync(plain);
	const wrap = () => new EnvWrap({ stateDir: join(root, "state"), home: root });
	const run = async (w: EnvWrap, cwd: string, command: string, base: Env = env, spawnEnv: Env = base) => {
		const p = await w.prepare(cwd, command, base);
		const s = p.spawn(command, spawnEnv);
		const r = spawnSync("/bin/bash", ["-c", s.command], { cwd, env: s.env as NodeJS.ProcessEnv, encoding: "utf8" });
		p.cleanup();
		return { status: r.status, stdout: r.stdout, stderr: r.stderr };
	};
	return { root, env, direnv, worktree, count, plain, wrap, run };
}

const VALUE = 'printf %s "${WT_VALUE-unset}"';

test("a worktree with an env: the command sees it, also from a subdirectory", async (t) => {
	const s = setup(t);
	const a = s.worktree("a", "A");
	const w = s.wrap();
	const r = await s.run(w, a, VALUE);
	assert.deepEqual(r, { status: 0, stdout: "A", stderr: "" });
	mkdirSync(join(a, "sub"));
	assert.equal((await s.run(w, join(a, "sub"), VALUE)).stdout, "A");
	assert.equal(s.count("a"), 1);
});

test("a worktree without an env runs with the base env and no direnv state", async (t) => {
	const s = setup(t);
	const r = await s.run(s.wrap(), s.plain, VALUE + '; printf " %s" "${DIRENV_FILE-none}"');
	assert.deepEqual(r, { status: 0, stdout: "unset none", stderr: "" });
});

test("cache hit: a second call and a new pi process reuse the export", async (t) => {
	const s = setup(t);
	const a = s.worktree("a", "A");
	assert.equal((await s.run(s.wrap(), a, VALUE)).stdout, "A");
	const w = s.wrap();
	assert.equal((await s.run(w, a, VALUE)).stdout, "A");
	assert.equal((await s.run(w, a, VALUE)).stdout, "A");
	assert.equal(s.count("a"), 1);
});

test("a devenv.nix edit refreshes the cached env once", async (t) => {
	const s = setup(t);
	const a = s.worktree("a", "A");
	const w = s.wrap();
	assert.equal((await s.run(w, a, VALUE)).stdout, "A");
	writeFileSync(join(a, "devenv.nix"), "A2");
	assert.equal((await s.run(w, a, VALUE)).stdout, "A2");
	assert.equal((await s.run(s.wrap(), a, VALUE)).stdout, "A2");
	assert.equal(s.count("a"), 2);
});

test("cd into another worktree in the same call switches the env", async (t) => {
	const s = setup(t);
	const a = s.worktree("a", "A");
	const b = s.worktree("b", "B");
	const literal = "printf '%s,' \"$WT_VALUE\"; cd " + b + " && printf '%s,' \"$WT_VALUE\"; cd " + s.plain + " && " + VALUE;
	const w = s.wrap();
	const r = await s.run(w, a, literal);
	assert.equal(r.stderr, "");
	assert.equal(r.stdout, "A,B,unset");
	await s.run(w, a, literal);
	// Literal targets load from the cache: each .envrc ran once in total.
	assert.deepEqual([s.count("a"), s.count("b")], [1, 1]);
	// A computed target loads through direnv in the shell (uncached, still correct).
	const c = s.worktree("c", "C");
	const dynamic = await s.run(w, a, 'd="' + c + '"; cd "$d" && ' + VALUE + "; cd .. && cd " + a + " && printf ',%s' \"$WT_VALUE\"");
	assert.equal(dynamic.stdout, "C,A");
	assert.equal(s.count("c"), 1);
});

test("heavy caps stay in force inside heavy when the env sets them", async (t) => {
	const s = setup(t);
	const caps = s.worktree("caps", "x", { extra: "export VITEST_MAX_WORKERS=99 CARGO_BUILD_JOBS=99 HEAVY_CPUS=99" });
	const cmd = "printf '%s ' \"$VITEST_MAX_WORKERS\"; " + HEAVY + " -- sh -c 'printf \"%s %s %s\" \"$VITEST_MAX_WORKERS\" \"$CARGO_BUILD_JOBS\" \"$HEAVY_CPUS\"'";
	const r = await s.run(s.wrap(), caps, cmd);
	assert.equal(r.status, 0, r.stderr);
	const [outside, vitest, cargo, cpus] = r.stdout.split(" ");
	assert.equal(outside, "99", "the env is applied outside heavy");
	assert.notEqual(vitest, "99");
	assert.ok(Number(vitest) > 0, r.stdout);
	assert.deepEqual([cargo, cpus], [vitest, vitest]);
});

test("a blocked .envrc outside git: the command runs without its env and says why; allow takes effect", async (t) => {
	const s = setup(t);
	const d = s.worktree("blocked", "X", { allow: false });
	const w = s.wrap();
	const note = "env-wrap: " + join(d, ".envrc") + " is not allowed (it is not in a git checkout), so this command runs without its env. Report this: the owner approves a repo's .envrc.\n";
	for (let call = 0; call < 2; call++) assert.deepEqual(await s.run(w, d, VALUE), { status: 0, stdout: "unset", stderr: note });
	s.direnv(["allow", d]);
	assert.deepEqual(await s.run(w, d, VALUE), { status: 0, stdout: "X", stderr: "" });
});

test("a linked worktree inherits the main checkout's approval of the same .envrc", async (t) => {
	const s = setup(t);
	const main = s.worktree("repo", "R");
	const git = (cwd: string, ...args: string[]) => {
		const flags = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"];
		const r = spawnSync("git", [...flags, ...args], { cwd, env: s.env as NodeJS.ProcessEnv, encoding: "utf8" });
		assert.equal(r.status, 0, r.stderr);
	};
	git(main, "init", "-q");
	git(main, "add", "-A");
	git(main, "commit", "-qm", "init");
	const w = s.wrap();
	const same = join(s.root, "repo-same");
	git(main, "worktree", "add", "-q", "-b", "same", same);
	const allowed = "env-wrap: allowed " + same + ": its .envrc matches the allowed main checkout.\n";
	assert.deepEqual(await s.run(w, same, VALUE), { status: 0, stdout: "R", stderr: allowed });
	assert.deepEqual(await s.run(s.wrap(), same, VALUE), { status: 0, stdout: "R", stderr: "" });
	// A worktree whose .envrc differs from the main checkout stays blocked.
	const changed = join(s.root, "repo-changed");
	git(main, "worktree", "add", "-q", "-b", "changed", changed);
	writeFileSync(join(changed, ".envrc"), readFileSync(join(changed, ".envrc"), "utf8") + "export EXTRA=1\n");
	const differs = await s.run(w, changed, VALUE);
	assert.equal(differs.stdout, "unset");
	assert.match(differs.stderr, /is not allowed \(it differs from .*\/repo\/\.envrc\)/);
	// The main checkout loses its approval: a new worktree stays blocked.
	s.direnv(["deny", main]);
	const later = join(s.root, "repo-later");
	git(main, "worktree", "add", "-q", "-b", "later", later);
	const denied = await s.run(w, later, VALUE);
	assert.equal(denied.stdout, "unset");
	assert.match(denied.stderr, /is not allowed \(.*\/repo\/\.envrc is not allowed either\)/);
});

test("a failing .envrc: full error once, then a cached reminder without re-running it", async (t) => {
	const s = setup(t);
	const d = s.worktree("broken", "X", { extra: "exit 3" });
	const w = s.wrap();
	const first = await s.run(w, d, VALUE);
	assert.equal(first.stdout, "unset");
	assert.match(first.stderr, /^env-wrap: .*\.envrc did not load; this command runs without its env:\n.*exit status 3/);
	const second = await s.run(w, d, VALUE);
	assert.equal(second.stdout, "unset");
	assert.match(second.stderr, /did not load \(cached result\).*direnv exec /);
	assert.equal(s.count("broken"), 1);
});

test("pi started inside a direnv env: the inherited env is undone first", async (t) => {
	const s = setup(t);
	const a = s.worktree("a", "A");
	const b = s.worktree("b", "B");
	const loaded = JSON.parse(s.direnv(["export", "json"], a)) as Record<string, string | null>;
	const inherited: Env = { ...s.env };
	for (const [k, v] of Object.entries(loaded)) {
		if (v === null) delete inherited[k];
		else inherited[k] = v;
	}
	const w = s.wrap();
	assert.equal((await s.run(w, s.plain, VALUE, inherited)).stdout, "unset");
	assert.equal((await s.run(w, b, VALUE, inherited)).stdout, "B");
	const same = await s.run(w, a, VALUE + '; printf " %s" "$PATH"', inherited);
	assert.equal(same.stdout, "A " + join(a, "bin") + ":" + s.env.PATH);
});

test("a cached env is not reused for another base env", async (t) => {
	const s = setup(t);
	const a = s.worktree("a", "A");
	const path = 'printf %s "$PATH"';
	assert.equal((await s.run(s.wrap(), a, path)).stdout, join(a, "bin") + ":" + s.env.PATH);
	const other: Env = { ...s.env, PATH: "/other/bin:" + s.env.PATH };
	assert.equal((await s.run(s.wrap(), a, path, other)).stdout, join(a, "bin") + ":" + other.PATH);
	assert.equal(s.count("a"), 2);
	// prepare() and the spawn disagree on the base: load through direnv, say so.
	const w = s.wrap();
	const drift = await s.run(w, a, path, s.env, other);
	assert.equal(drift.stdout, join(a, "bin") + ":" + other.PATH);
	assert.match(drift.stderr, /spawn env differs from the cached base/);
});
