import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import shellGuard, { blockReason, checkCommand, checkDestructive } from "../extensions/shell-guard.ts";

const linuxOnly = (command: string) => {
	const f = checkCommand(command);
	return f?.kind === "linux-only" ? f.word : undefined;
};
const heavyFix = (command: string) => {
	const f = checkCommand(command);
	return f?.kind === "needs-heavy" ? f.fix : undefined;
};

test("blocks Linux-only words as the command word, after any wrapper", () => {
	const cases: [string, string][] = [
		["timeout 300 vitest run | tail", "timeout"],
		["gtimeout 5 cmd", "gtimeout"],
		["setsid cmd", "setsid"],
		["nproc", "nproc"],
		["make -j$(nproc)", "nproc"],
		["make -j`nproc`", "nproc"],
		["cd x && timeout 5 cmd", "timeout"],
		["heavy -- timeout 300 vitest run", "timeout"],
		["heavy --slots 4 -- timeout 300 x", "timeout"],
		["env timeout 5 cmd", "timeout"],
		["env -i FOO=1 timeout 5 cmd", "timeout"],
		["FOO=1 BAR=2 timeout 5 cmd", "timeout"],
		["nohup timeout 5 cmd > log 2>&1 &", "timeout"],
		["sudo timeout 5 cmd", "timeout"],
		["time timeout 5 cmd", "timeout"],
		["exec timeout 5 cmd", "timeout"],
		["nice -n 10 timeout 5 cmd", "timeout"],
		["xargs -n 1 timeout 5", "timeout"],
		["sh -c 'timeout 5 cmd'", "timeout"],
		['bash -lc "cd x; timeout 5 cmd"', "timeout"],
		["for f in a b; do timeout 5 $f; done", "timeout"],
		["if true; then setsid x; fi", "setsid"],
		["/usr/local/bin/timeout 5 x", "timeout"],
		['echo "$(nproc)"', "nproc"],
	];
	for (const [command, word] of cases) assert.equal(linuxOnly(command), word, command);
});

test("leaves the words alone in quotes, heredoc bodies, comments and arguments", () => {
	const cases = [
		'git commit -m "fix retry; timeout handling"',
		"gh pr comment --body 'use x; setsid y'",
		"echo timeout",
		"rg -n 'timeout|nproc' src",
		"rg timeout src",
		"command -v timeout",
		"ls # timeout here",
		"cat > notes.md <<'EOF'\ntimeout 5 x\nsetsid y\nEOF\necho done",
		"cat <<-EOF\n\ttimeout 5\n\tEOF",
		"sysctl -n hw.ncpu",
		"grep -r nproc .",
		"toString",
	];
	for (const command of cases) assert.equal(checkCommand(command), undefined, command);
});

test("blocks bare test, typecheck and build runs and names the heavy form", () => {
	const cases: [string, string][] = [
		["vitest run", "heavy -- vitest run"],
		["vitest", "heavy -- vitest"],
		["npx vitest run src/a.test.ts", "heavy -- npx vitest run src/a.test.ts"],
		["bunx vitest run", "heavy -- bunx vitest run"],
		["pnpm exec vitest run", "heavy -- pnpm exec vitest run"],
		["pnpm vitest run", "heavy -- pnpm vitest run"],
		["./node_modules/.bin/vitest run", "heavy -- ./node_modules/.bin/vitest run"],
		["tsc --noEmit", "heavy -- tsc --noEmit"],
		["npx tsc -p .", "heavy -- npx tsc -p ."],
		["bun test", "heavy -- bun test"],
		["bun run test", "heavy -- bun run test"],
		["bun run typecheck", "heavy -- bun run typecheck"],
		["bun run build", "heavy -- bun run build"],
		["npm run verify", "heavy -- npm run verify"],
		["npm test", "heavy -- npm test"],
		["npm t", "heavy -- npm t"],
		["npm run test:unit -- --reporter dot", "heavy -- npm run test:unit -- --reporter dot"],
		["pnpm test", "heavy -- pnpm test"],
		["pnpm --filter web run typecheck", "heavy -- pnpm --filter web run typecheck"],
		["pnpm -r build", "heavy -- pnpm -r build"],
		["yarn test:e2e", "heavy -- yarn test:e2e"],
		["yarn build", "heavy -- yarn build"],
		["turbo run test", "heavy -- turbo run test"],
		["turbo run lint typecheck", "heavy -- turbo run lint typecheck"],
		["turbo build --filter web", "heavy -- turbo build --filter web"],
		["cargo test -p core", "heavy -- cargo test -p core"],
		["cargo build --release", "heavy -- cargo build --release"],
		["cargo check", "heavy -- cargo check"],
		["cargo clippy --all-targets", "heavy -- cargo clippy --all-targets"],
		["cargo nextest run", "heavy -- cargo nextest run"],
		["cargo +nightly test", "heavy -- cargo +nightly test"],
		["pytest tests/a.py", "heavy -- pytest tests/a.py"],
		["uv run pytest -q", "heavy -- uv run pytest -q"],
		["python -m pytest", "heavy -- python -m pytest"],
		["go test ./...", "heavy -- go test ./..."],
		["FOO=1 vitest run", "FOO=1 heavy -- vitest run"],
		["cd app && bun run test 2>&1 | tail -20", "heavy -- bun run test"],
		["set -o pipefail; vitest run | tail", "heavy -- vitest run"],
		["heavy -- bun run lint && bun run build", "heavy -- bun run build"],
		["(cd app; cargo test)", "heavy -- cargo test"],
		["sh -c 'vitest run'", "heavy -- vitest run"],
		["nohup vitest run > log 2>&1 &", "nohup heavy -- vitest run"],
		["nix build .#bun", "heavy -- nix build .#bun"],
		["nix flake check", "heavy -- nix flake check"],
		["cd ~/Dev/nix-platform && nix flake check --all-systems", "heavy -- nix flake check --all-systems"],
		["nix --extra-experimental-features 'nix-command flakes' build .#x", "heavy -- nix --extra-experimental-features 'nix-command flakes' build .#x"],
		["nix --option cores 2 flake check", "heavy -- nix --option cores 2 flake check"],
	];
	for (const [command, fix] of cases) assert.equal(heavyFix(command), fix, command);
});

test("allows heavy-wrapped runs, lint, format and text that only mentions the tools", () => {
	const cases = [
		"heavy -- vitest run",
		"heavy -- bun run test",
		"heavy --slots 4 -- turbo run test",
		"set -o pipefail; heavy -- tsc --noEmit 2>&1 | tail -30",
		"cd app && heavy -- cargo test -p core",
		"FOO=1 heavy -- pytest",
		"heavy -- bash -c 'cd app && vitest run'",
		"bun run lint",
		"npm run format",
		"pnpm lint",
		"turbo run lint",
		"cargo fmt",
		"cargo run --bin x",
		"go vet ./...",
		"bun install",
		"npm run dev",
		'echo "vitest run"',
		"echo tsc --noEmit",
		"rg -n 'vitest run|cargo test' .",
		"rg vitest src",
		'git commit -m "run tsc and bun test"',
		"cat <<'EOF' > ci.sh\nvitest run\ncargo test\nEOF",
		"tsc --version",
		"vitest --help",
		"heavy --status",
		"heavy -- nix flake check",
		"nix run nixpkgs#hello",
		"nix shell nixpkgs#jq -c jq --version",
		"nix eval .#packages.aarch64-darwin.bun.version",
		"nix flake show",
		"nix flake update",
		"nix build --help",
	];
	for (const command of cases) assert.equal(checkCommand(command), undefined, command);
});

test("tool_call handler blocks with the fix and ignores other tools", () => {
	type ToolCall = { toolName: string; input: { command: string } };
	let handler: ((event: ToolCall) => { block: boolean; reason: string } | undefined) | undefined;
	shellGuard({ on: (_name: string, h: never) => (handler = h) } as never);
	assert.deepEqual(handler!({ toolName: "bash", input: { command: "vitest run" } }), {
		block: true,
		reason: blockReason({ kind: "needs-heavy", segment: "vitest run", fix: "heavy -- vitest run" }),
	});
	const reason = handler!({ toolName: "bash", input: { command: "timeout 5 x" } })?.reason ?? "";
	assert.match(reason, /bash tool `timeout` parameter/);
	assert.equal(handler!({ toolName: "read", input: { command: "vitest run" } }), undefined);
	assert.equal(handler!({ toolName: "bash", input: { command: "heavy -- vitest run" } }), undefined);
});


test("destructive commands run inside a linked worktree or temp dir and are blocked elsewhere", (t) => {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "shell-guard-test-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const main = join(root, "main");
	const wt = join(root, "wt");
	const plain = join(root, "plain");
	const temp = join(root, "temp");
	const home = join(root, "home");
	for (const d of [main, plain, temp, home]) mkdirSync(d);
	const git = (cwd: string, ...args: string[]) => {
		const flags = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"];
		const r = spawnSync("git", [...flags, ...args], { cwd, encoding: "utf8" });
		assert.equal(r.status, 0, r.stderr);
	};
	git(main, "init", "-q");
	writeFileSync(join(main, "a.txt"), "a\n");
	git(main, "add", "-A");
	git(main, "commit", "-qm", "init");
	git(main, "worktree", "add", "-q", "-b", "wt", wt);
	mkdirSync(join(wt, "sub"));
	symlinkSync(main, join(wt, "link"));
	const check = (cwd: string, command: string) => checkDestructive(command, cwd, home, [temp]);
	const allowed: [string, string][] = [
		[wt, "rm -rf node_modules"],
		[wt, "rm -rf dist/*"],
		[wt, "rm -f a.txt sub/b.txt"],
		[wt, "rm -rf *"],
		[wt, "cd sub && rm -rf build"],
		[wt, "(cd " + main + " && git status); rm -rf node_modules"],
		[wt, "find . -name '*.log' -delete"],
		[wt, "chmod -R u+w sub"],
		[wt, "git clean -fdx"],
		[wt, "git reset --hard HEAD~1"],
		[wt, "git checkout -- ."],
		[wt, "git restore a.txt"],
		[wt, "rm -rf " + temp + "/run-1"],
		[wt, "heavy -- rm -rf coverage"],
		[root, "cd wt && git reset --hard"],
		[main, "cd ../wt && rm -rf node_modules"],
		[main, "git clean -n"],
		[main, "git restore --staged a.txt"],
		[main, "git checkout feature"],
		[main, "git push origin main"],
		[main, "rm -rf " + temp + "/x"],
		[plain, "trash old.log"],
		[plain, "chmod 644 a.txt"],
	];
	for (const [cwd, command] of allowed) assert.equal(check(cwd, command), undefined, cwd + ": " + command);
	const blocked: [string, string, RegExp][] = [
		[wt, "rm -rf .git", /`rm` with a target outside .*: \.git\. Use `trash <path>`/],
		[wt, "rm -rf .", /target outside/],
		[wt, "rm -rf .*", /target outside/],
		[wt, "rm -rf ../*", /target outside/],
		[wt, "rm -rf ../main/a.txt", /target outside/],
		[wt, "rm -rf link/a.txt", /target outside/],
		[wt, "rm -rf ~/notes", /target outside/],
		[wt, "rm -rf $(cat list)", /\(computed\)/],
		[wt, 'rm -rf "$d"', /\(computed\)/],
		[wt, "ls | xargs rm -f", /targets from xargs/],
		[wt, "cd ../main; rm -rf node_modules", /target outside/],
		[wt, 'cd "$X" && rm -rf build', /directory unknown/],
		[wt, "bash -c 'cd ../main && rm -rf build'", /target outside/],
		[wt, "eval 'rm -rf ../main/a.txt'", /target outside/],
		[wt, "find .. -delete", /target outside/],
		[wt, "rm -rf " + temp, /target outside/],
		[wt, "rsync -a --delete src/ host:/srv/app", /host:\/srv\/app/],
		[wt, "git -C ../main reset --hard", /`git reset` discards changes, and .*main is not in a linked worktree\. Run `git stash` first/],
		[main, "rm -rf node_modules", /target outside/],
		[main, "git reset --hard", /discards changes/],
		[main, "git clean -fd", /discards changes/],
		[main, "git checkout -- a.txt", /discards changes/],
		[main, "git restore a.txt", /discards changes/],
		[plain, "rm old.log", /target outside/],
		[wt, "git push --force origin wt", /`git push --force` is blocked .* cannot be undone/],
		[wt, "git push origin +wt", /git push --force/],
		[wt, "sudo ls", /`sudo` is blocked/],
		[wt, "dd if=/dev/zero of=disk.img", /`dd` is blocked/],
		[wt, "mkfs.ext4 /dev/disk9", /`mkfs.ext4` is blocked/],
		[wt, "kubectl delete pod web", /kubectl delete/],
		[wt, "terraform destroy -auto-approve", /terraform destroy/],
		[wt, "docker rm -f web", /`docker rm`/],
		[wt, "docker system prune -af", /docker system prune/],
	];
	for (const [cwd, command, reason] of blocked) {
		const finding = check(cwd, command);
		assert.equal(finding?.kind, "destructive", cwd + ": " + command);
		assert.match(blockReason(finding!), reason, command);
	}
});


test("blocks GNU-style sed -i and names the BSD form", () => {
	const fix = (command: string) => {
		const f = checkCommand(command);
		return f?.kind === "bsd-sed" ? f.fix : undefined;
	};
	const cases: [string, string][] = [
		["sed -i 's/a/b/' f.txt", "sed -i '' 's/a/b/' f.txt"],
		["sed -i -e 's/a/b/' f.txt", "sed -i '' -e 's/a/b/' f.txt"],
		["sed -Ei 's/a+/b/' f.txt", "sed -Ei '' 's/a+/b/' f.txt"],
		["cd src && sed -i \"s/x/y/g\" a.ts b.ts", "sed -i '' \"s/x/y/g\" a.ts b.ts"],
		["rg -l foo | xargs sed -i 's/foo/bar/'", "xargs sed -i '' 's/foo/bar/'"],
	];
	for (const [command, expected] of cases) assert.equal(fix(command), expected, command);
	const finding = checkCommand("sed -i 's/a/b/' f.txt");
	assert.match(blockReason(finding!), /BSD sed: it reads the word after `-i` as the backup suffix\. Use `sed -i '' 's\/a\/b\/' f\.txt`, or `perl -pi -e`\./);
	const allowed = [
		"sed -i '' 's/a/b/' f.txt",
		"sed -i.bak 's/a/b/' f.txt",
		"sed -E -i '' 's/a+/b/' f.txt",
		"sed -n '1,20p' f.txt",
		"sed 's/a/b/' f.txt > g.txt",
		"gsed -i 's/a/b/' f.txt",
		"perl -pi -e 's/a/b/' f.txt",
		'echo "sed -i s/a/b/ f"',
	];
	for (const command of allowed) assert.equal(checkCommand(command), undefined, command);
});
