# Nix phase 2: secrets, devenv in active repos, Homebrew under nix-darwin, Nix in CI

Status: approved by the owner on 2026-10-23 (decisions from grilling rounds 1 to 6). Delivery tickets: GitHub issues labelled ready-for-agent, titled S1-S6, D1-D9, H1-H7 and C1-C3. Vocabulary: `GLOSSARY.md`. Decisions with lasting weight: `docs/adr/0001-1password-is-the-secrets-source.md`, `docs/adr/0002-public-platform-repository.md`.

## Problem Statement

The owner runs many AI agents on one Mac. Phase 1 put the Mac under nix-darwin and home-manager, pinned bun, node, uv and Postgres in the platform overlay, and gave one repo (Bayland portfolio) a devenv for its test Postgres. Four problems remain.

1. **Secrets in plain text.** Eight API key variables are exported as plain text from the owner's zsh startup file. Three backups of that file hold the same values. A ninth key comes from the macOS Keychain. 9router (the local AI gateway, a launchd agent) reads four secrets from a plain `.env` file. The pi provider configuration holds one literal provider key. Every agent shell sees these values, and any agent that prints the startup file copies them into its session.
2. **1Password prompts stop unattended work.** Some projects load their dev environment through `op run` with an app env template. The 1Password desktop app approves the CLI per terminal session, and that approval expires after 10 idle minutes (12 hours at most). Unattended agents in new panes and worktrees stop at the prompt, or fail with "authorization timeout" or "account is not signed in".
3. **Tool versions differ between local shells, repos and CI.** Only Bayland portfolio has devenv, and no repo has an `.envrc`. Node pins differ from the platform (22.23.4, 22.22.0, 24.18.0, 24.19.0 and 26, against 24.21.0 in the platform). CI installs its tools with setup actions at its own versions, so a green CI run does not prove the local toolchain.
4. **Homebrew is unmanaged.** There are 57 leaf formulae, 30 casks and 33 npm globals under Homebrew's own Node, plus stopped database formulae and an untrusted third-party tap that blocks `brew list --cask`. Many tools exist twice (Homebrew and Nix), and PATH order decides which one runs.

## Solution

Four tracks, delivered in this order: secrets, devenv in active repos, Homebrew under nix-darwin, Nix in CI.

1. **Secrets.** 1Password is the only source of truth. Every secret that unattended agents may use lives in the agent vault. The saved 2password service account reads that vault with no prompt. At every login, a login agent renders each env template (shell secrets, 9router, and the dev and staging app env of Bayland and ymcq) into a rendered env file. That file is outside the repositories and outside the Nix store, and only the owner can read it. Every zsh loads the shell secrets file. 9router reads its own file. Repo commands load their project file instead of calling 1Password. After a value changes, a secrets refresh renders all files again with no prompt. Production credentials keep the desktop approval prompt.
2. **devenv in active repos.** The platform repository becomes public, so repos and CI import it with no credentials. The platform exposes one Node per major version from its nixpkgs. When a repo has a security pin that is ahead of nixpkgs, the platform adds an official-binary override, as it already does for bun. Seven phase-2 repos get a tools-first devenv and an `.envrc`. Their pin files follow the platform versions.
3. **Homebrew under nix-darwin.** nix-darwin declares Homebrew. The cleanup mode starts at `check` and moves to `uninstall`. CLI tools that nixpkgs builds move to home-manager. Unused tools, stopped database formulae, Homebrew's own Node and the untrusted tap go away. Data folders stay.
4. **Nix in CI.** Three workflows run their work through the repo's devenv shell. A version-assertion step compares the versions in CI with the pin files. The goal is version parity, not speed. There is no own binary cache unless the measured setup cost grows by more than 60 s per job.

## User Stories

### Secrets

1. As the owner, I want no API key value in any shell startup file, so that showing or syncing my dotfiles cannot leak a key.
2. As the owner, I want one master copy of each agent secret in 1Password, so that I change a value in one place.
3. As the owner, I want unattended agent sessions to never trigger a 1Password prompt, so that loops and background workers do not stall.
4. As an agent, I want the shell secrets in my environment when my shell starts, so that the firecrawl, exa, context7, tinyfish and imagegen skills work with no change.
5. As an agent in a non-interactive zsh, I want the same shell secrets as an interactive shell, so that scripts behave the same everywhere.
6. As the owner, I want the rendered env files readable only by me (mode 0400), so that other local accounts cannot read them.
7. As the owner, I want no secret value in the Nix store or in any home-manager session variable, so that store paths stay safe to share and to cache.
8. As the owner, I want rendering to happen at every login with no prompt, so that a reboot needs no action from me.
9. As the owner, I want a secrets refresh command, so that a changed value reaches new shells without a logout.
10. As the owner, I want a failed render to keep the last good file and log the error without values, so that a 1Password outage does not remove my keys.
11. As the owner, I want 9router to read its secrets from its rendered env file, so that the plain `.env` in its repo can go.
12. As the owner, I want 9router to wait for its rendered env file at login for a bounded time, so that a start before the first render does not crash it.
13. As the owner, I want the pi provider key referenced by variable name instead of literal value, so that the pi configuration file holds no secret.
14. As an agent in a Bayland or ymcq worktree, I want the dev app env from a rendered env file, so that dev servers and scripts start without any 1Password call.
15. As the owner, I want the staging app env of Bayland rendered the same way, so that staging checks run unattended.
16. As the owner, I want production templates and the AWS, Coolify, Cloudflare and npm-publish loaders to keep the desktop approval, so that no agent can read production credentials silently.
17. As the owner, I want 1Password requests per day to stay far below the account's daily cap, so that a busy day of agents cannot lock out every secret.
18. As the owner, I want values moved into 1Password through a pipe or the clipboard, never through command arguments, chat or temporary files, so that the move itself leaks nothing.
19. As the owner, I want item titles in the agent vault to carry the project name, so that I can find them in the app.
20. As the owner, I want the plain-text zsh backups and artifact copies that hold values in the Trash after the cut-over, so that the old copies are gone from the disk.
21. As the Bayland session, I want a hand-off note with the new item references, the rendered env file location and the command change, so that I can switch Bayland without guessing.

### devenv

22. As the owner, I want the platform repository public, so that every repo, collaborator and CI job can import it with no token.
23. As the owner, I want a full-history secret scan before the platform becomes public, so that no past commit leaks anything.
24. As the owner, I want env templates in the public repository to use opaque 1Password IDs, so that the public files reveal no vault or item names.
25. As a repo maintainer, I want one Node per major version from the platform, so that every repo and CI job on that major runs the same patch version.
26. As the Bayland maintainer, I want Node 22.23.4 from the platform while nixpkgs is behind, so that the security pin holds in devenv and CI.
27. As the owner, I want the platform's pin-drift check to cover every exposed Node major, so that a nixpkgs update cannot change a version silently.
28. As an agent in a phase-2 repo, I want `cd` into the repo to activate its devenv, so that the right node, bun and package manager are on PATH with no extra command.
29. As an agent in a fresh worktree, I want the worktree's devenv to load the same as the main checkout, so that worktree checks match landing checks.
30. As a repo maintainer, I want the repo's pin files updated to the platform versions, so that the pin files, devenv and CI agree.
31. As the bwf-astro maintainer, I want php in the devenv, so that the WordPress fixture tests stop failing with "command not found".
32. As the owner, I want paused repos to get the same template when work resumes, so that phase 2 does not touch repos nobody works in.

### Homebrew

33. As the owner, I want Homebrew declared in nix-darwin, so that a new install or a rebuild gives the same casks and formulae.
34. As the owner, I want the first declared switch to fail on anything undeclared (cleanup `check`), so that nothing is removed before I see the list.
35. As the owner, I want cleanup to move to `uninstall` once the list matches, so that manual installs do not pile up again.
36. As the owner, I want no `zap`, so that app data and settings survive any cleanup.
37. As the owner, I want CLI tools that nixpkgs builds to come from home-manager, so that only one package manager provides each tool.
38. As the owner, I want to mark each unused tool keep or remove in one pass before removal, so that rarely used tools survive when I want them.
39. As the owner, I want stopped database formulae uninstalled while their data folders stay, so that no data is lost.
40. As an agent, I want agent-browser and the other npm globals I use available under the Nix Node, so that removing Homebrew's Node does not break my tools.
41. As the owner, I want git's GitHub credential helper to call the Nix gh, so that Homebrew gh can go.
42. As the owner, I want the untrusted antigravity tap and its cask removed, so that Homebrew commands stop refusing to run.
43. As the owner, I want Homebrew node@24 removed now and node@22 removed after Bayland runs Node 22.23.4 from devenv, so that no pinned consumer loses its Node.

### CI

44. As a maintainer of bwf-astro, ymcq or gii-atlas, I want CI to run its checks inside the repo's devenv shell, so that CI uses the same versions as my shell.
45. As a maintainer, I want CI to print node, bun and package-manager versions (and Postgres where used) and fail when they differ from the pin files, so that drift is visible.
46. As the owner, I want each CI ticket to record the Nix setup time, so that a cache is added only when the cost is measured.
47. As the owner, I want the gii-atlas deploy workflow verified without a production deploy, so that the change cannot ship to production by accident.

## Implementation Decisions

### Track order and blocking

- The tracks start in this order: secrets, devenv, Homebrew, CI. The entry tickets of each track are blocked by the exit tickets of the track before, so that a Ralph lane working the frontier keeps the owner's order. Inside a track, blocking edges show only real dependencies.
- Some steps need the owner at the Mac (attended steps): `darwin-rebuild switch` (sudo), `direnv allow` once per main checkout, 1Password desktop approvals while items move between vaults, the final go for the public flip, approval of the zsh startup-file edit, and approval of every Trash list. Tickets name their attended steps.

### Track 1: Secrets

**Source of truth and access**
- 1Password holds the master copy. There is no sops-nix and no agenix (ADR 0001).
- Agent vault: the existing vault that the saved 2password service account already reaches. A service account's vault access cannot change after creation, so reusing this vault avoids a new service account. Item titles carry the project name.
- The service account token stays where 2password keeps it (macOS Keychain).

**Inventory in scope**
- Shell secrets: `FIRECRAWL_API_KEY`, `EXA_API_KEY`, `CONTEXT7_API_KEY`, `TINYFISH_API_KEY`, `MC_API`, `TG_BOT_TOKEN`, `TWELVE_DATA_API_KEY`, `PI_IMAGEGEN_API_KEY`, and `SUPERMEMORY_API_KEY` (today read from the Keychain). Some variables hold a comma-separated pool of keys, and the item stores the value unchanged. `PI_IMAGEGEN_API_KEY` holds a 5-character value today. The migration ticket asks the owner whether it is a real secret. If it is not, it stays a plain setting.
- 9router secrets: the four values in its repo `.env` (JWT secret, initial password, API key secret, machine ID salt).
- pi provider key: the one literal key in the pi provider configuration. It becomes a `$NAME` reference to a shell secret. pi resolves `$NAME` from its process environment, so running pi sessions pick it up after a restart.
- App env: Bayland dev and Bayland staging (3 items), and ymcq dev (1 item). No dev or staging item is also used by a production template (checked 2026-10-23), so moving them does not touch production.

**Migration of values**
- Shell, 9router and pi values go into new agent-vault items through 2password create with stdin or clipboard input. Values never appear in command arguments, chat, logs or temporary files.
- Bayland and ymcq dev and staging items move from their project vault to the agent vault (attended: desktop approval). Production items stay where they are.
- No rotation (owner decision).

**Templates and rendering**
- The platform repository holds one template per rendered env file: shell secrets, 9router, Bayland dev, Bayland staging and ymcq dev. Templates hold only `op://` references by opaque vault and item IDs, because the repository becomes public.
- The login agent is a launchd user agent that runs at login. It renders every template through the service account, writes each rendered env file atomically with mode 0400 into a per-user state folder outside every repository and outside the Nix store, and logs names and counts only.
- When a render fails, the last good file stays in place and the log records the error. The folder is excluded from Time Machine and from any backrest plan that covers it.
- 2password is packaged by the platform at a pinned version, as 9router is, so the login agent does not depend on a mutable global install. `op` stays the Homebrew 1password-cli cask, because nixpkgs marks it unfree and unavailable on this host.
- Secrets refresh: one command restarts the login agent on demand. It shows no prompt.
- Request budget: one render per login covers every template. The first secrets ticket measures how many service-account requests one render costs and records it. Repo commands make no 1Password calls.

**Delivery to consumers**
- Every zsh, interactive and non-interactive, exports the shell secrets from the rendered env file at start, when the file exists. No secret value is placed in any Nix expression, store path or home-manager session variable.
- The cut-over removes the plain-text export lines and the Keychain lookup from the owner's zsh startup file. Any backup made before that edit must have its values removed.
- 9router's launchd agent loads its rendered env file instead of the repo `.env`. It waits a bounded time for the file at start. After a verified restart, the repo `.env` goes to the Trash (owner approval).
- Repo commands load their project's rendered env file (for example `bun --env-file` or `node --env-file`) instead of `op run`. ymcq changes its scripts in a phase-2 ticket. Bayland gets a hand-off note and changes its own repository.
- Production templates and the on-demand AWS, Coolify, Cloudflare and npm-publish loaders do not change.

**Cleanup**
- After the shell cut-over passes, the 3 zsh startup-file backups and the artifact files that hold values go to the Trash. The ticket lists them for owner approval. Session history stays unchanged.

### Track 2: devenv in active repos

**Public platform repository (ADR 0002)**
- Before the flip: a secret scan of every commit on every ref, a check that all templates use opaque IDs, and a refresh of the stale "Not verified yet" README section. The owner gives the final go at execution time, because the flip cannot be undone.
- After the flip, repos import the platform through its public GitHub reference with no credentials. Bayland's existing import keeps working; switching it is the Bayland session's choice.
- The spec, ADRs, glossary and issues of this repository become public with it.

**Node versions**
- The overlay exposes the nixpkgs Node of each major that a phase-2 repo needs (22 and 24), and the default Node stays 24. A major is added when a repo needs it.
- Security pin: the Node 22 line is 22.23.4, built from official release binaries for aarch64-darwin, x86_64-linux and aarch64-linux, the same way as the bun override. It is removed when nixpkgs reaches 22.23.4.
- The pin-drift check covers every exposed major, and the expected versions are listed in one place.
- Repo pin files (`.node-version`, `.nvmrc`, `engines`, CI version inputs) change to the platform version of their major. Package managers stay pinned through `packageManager` and corepack (phase-1 decision).

**Repo template (tools first)**
- The devenv configuration imports the platform overlay and devenv module and follows the platform's nixpkgs.
- The devenv declares the repo runtime (the Node major it needs, bun where used, the package manager through corepack) and the repo-specific tools (php for bwf-astro).
- No services in phase 2. Services come later, and Bayland portfolio and trading-platform own theirs.
- An `.envrc` activates devenv. The owner runs `direnv allow` once per main checkout. env-wrap allows linked worktrees whose `.envrc` matches the main checkout.
- Each repo's existing worktree setup and land check must keep passing inside devenv.

**Phase-2 repos and targets (facts from 2026-10-23)**

| Repo | Today | Target in devenv |
|---|---|---|
| runbook | bun 1.4.4, no Node pin, no CI | bun 1.4.4, Node 24 |
| bwf-astro | bun 1.4.4, Node 22.22.0, php missing | bun 1.4.4, Node 22 line (22.23.4), php |
| gii-atlas | pnpm 11.17.0 (PATH has 11.1.3), CI Node 24.19.0 | pnpm 11.17.0 via corepack, Node 24.21.0 |
| costwise | bun 1.4.4 | bun 1.4.4 |
| bayland-elliott-suite | pnpm 10.24.0 | pnpm via corepack, Node major per repo engines |
| bayland-platform | pnpm 10.33.1, CI Node 22, Python 3.12 | pnpm via corepack, Node 22 line, Python as needed |
| ymcq | pnpm 10.33.0, Node 24 | pnpm via corepack, Node 24.21.0 |

Repos not in phase 2 (loom, rea, gii-monitor, travelicious-sop, pi-shared-config, design-skills and paused repos) get the same template when work resumes there.

### Track 3: Homebrew under nix-darwin

- The nix-darwin homebrew module declares taps, formulae and casks. nix-darwin does not install Homebrew itself, and nix-homebrew is not used. Auto-update, upgrade on activation and greedy cask upgrades stay off.
- Cleanup mode: `check` until the declared list matches what is installed, then `uninstall`. Never `zap`.
- Casks: declare the 22 installed casks and 8 fonts, except the 6 Caskroom entries whose app is missing (hiddenbar, legcord, pearcleaner, rectangle, stats, drawio) and antigravity-tools. Apps installed outside Homebrew are not adopted.
- nixpkgs first: kept CLI tools with a nixpkgs build move to home-manager (for example shellcheck, go, git-lfs, mosh, zoxide, restic, rclone, backrest). backrest's Homebrew service becomes a nix-darwin launchd agent with the same schedule and configuration.
- Homebrew keeps the casks, the 1password-cli cask, and formulae that nixpkgs lacks (moshi-hook, powerlevel10k, mole, ta-lib), with their taps.
- git's credential helper for github.com and gist.github.com calls the Nix gh instead of a hard-coded Homebrew path. The global Git Credential Manager helper does not change.
- Unused leaves (about 35, evidence "not found"): the ticket lists them, and the owner marks each one keep or remove. Kept tools follow nixpkgs first. opencode (Homebrew 1.18.9, nixpkgs 2.0.32) is on this list.
- Stopped database formulae (mysql, mariadb, mariadb@10.6, redis, postgresql@15) are uninstalled. Their data folders under the Homebrew prefix stay untouched until the owner deletes them.
- npm globals: packages that are still used (agent-browser first) are reinstalled under the Nix Node in the existing user npm prefix, and stale ones (for example the old 9router copy) are dropped. Then Homebrew's Node goes.
- node@24 goes in this track. node@22 goes after Bayland's devenv runs Node 22.23.4 (external dependency on the Bayland session).
- The untrusted tap lbjlaq/antigravity-manager and its cask are removed.

### Track 4: Nix in CI

- Workflows: bwf-astro `check`, ymcq `ci`, gii-atlas `deploy` (build steps only in verification; no production deploy).
- Setup: install upstream Nix with the action that the devenv documentation names, install devenv at the version used locally, then run each work step through the devenv shell. Parity comes from the shared lock and nixpkgs pin, not from using Lix in CI.
- No credentials are needed, because the platform repository is public.
- A version-assertion step prints node, bun and package-manager versions (and the Postgres major where the job uses a Postgres service) and fails on a difference from the pin files.
- Service containers (for example ymcq's Postgres 17) stay containers. Services in devenv are out of scope.
- No own binary cache. Each CI ticket records the Nix setup time against today's setup time. If the difference is more than 60 s per job, a follow-up ticket adds a cache.
- Windows and macOS jobs keep their setup actions.

## Testing Decisions

A good test checks behavior that someone can observe at the outer boundary of a track. It never prints a secret value. Secret checks compare variable names, lengths and file modes, or count matches in a subshell that prints numbers only.

- **Secrets seam (approved).** After the owner's switch and a new login: a fresh login shell, a fresh non-interactive zsh and a fresh agent shell each have every shell secret (name and non-zero length). The rendered env files exist with mode 0400. No value appears in the Nix store closure of the system or in any tracked file of the platform repository. No 1Password prompt appears during the test. Run the same checks after a secrets refresh, and after a render while the network is down (the last good file stays). 9router serves its model list after a restart with the new env source; prior art is the 9router proof of 14 of 14 model IDs. The skills that read shell secrets run one request each.
- **Platform seam.** `nix flake check` passes, including pin-drift for every exposed Node major. Prior art: the existing pin-drift check. The Node 22.23.4 override builds for aarch64-darwin and aarch64-linux locally (linux builder). x86_64-linux is proven by the first CI run that uses it, because there is no local x86_64 builder.
- **devenv seam.** In a fresh worktree of each phase-2 repo, the devenv shell reports node, bun and package-manager versions equal to the repo's pin files, and the repo's land check (or its verify command, where it has no land check) passes inside devenv. Prior art: the landCheck runs in the 2026-10-23 landcheck-apply report.
- **Homebrew seam.** `darwin-rebuild switch` passes with cleanup `check`, and nothing undeclared remains. After cleanup moves to `uninstall`, a second switch is a no-op. Each moved tool resolves to the Nix profile, and its smoke command runs.
- **CI seam.** The workflow is green, the version-assertion step passes, and the ticket records the setup time.
- Every heavy command (flake check, builds, test suites) runs through `heavy`.

## Out of Scope

- Rotation of the exposed shell keys (owner decision).
- Production credentials and the on-demand AWS, Coolify, Cloudflare and npm-publish loaders.
- pi's own credential store (OAuth tokens and keys that pi writes itself).
- Repo `.env` files other than the Bayland dev and staging and ymcq dev templates.
- Bayland portfolio and trading-platform devenv, Postgres and services (their own sessions). Bayland's template switch is a hand-off.
- Services in devenv for phase-2 repos.
- devenv for loom, rea, gii-monitor, travelicious-sop, pi-shared-config, design-skills and paused repos.
- The costwise CI bun pin, and CI for gii-monitor, rea, Bayland and trading-platform.
- CI speed work (sharding, turbo cache) and Windows or macOS CI jobs.
- Gotenberg (stays on Docker), heavy (stays outside Nix), Docker volumes, and deletion of any database data folder.
- nix-homebrew, and adoption of apps installed outside Homebrew.

## Further Notes

**External dependencies**
- Bayland session: switch Bayland's dev and staging commands to the rendered env files (from the hand-off note), and run Node 22.23.4 from devenv. The node@22 removal waits for the second change.

**Risks**
- Daily request cap: the account is probably Teams (5,000 requests per day for the whole account). Render-at-login keeps the use small. The first secrets ticket measures the cost of one render.
- 2password reads its token from the login keychain. A no-prompt read from a launchd agent at login is likely but not yet tested. The login agent ticket tests it first.
- Login race: a shell that starts before the first render ever completes has no shell secrets. After the first render the file persists, so later logins keep the previous values until the new render ends.
- The Node 22.23.4 override on x86_64-linux is proven only in CI.
- The public flip exposes host layout and the names of the phase-2 repos in the spec and issues.

**Assumptions recorded during shaping (reversible)**
- 2password is packaged by the platform at a pinned version. Revisit if packaging costs more than the gain.
- Rendered env files persist on disk across reboots, owner-only, excluded from backups.
- CI installs upstream Nix, not Lix.

**Record**
- The owner decisions and their evidence are in the private decision log of the Nix migration plan (entries from 2026-10-23, "nix-phase2-architect"). Research briefs: secrets tools, 1Password service accounts, Nix in CI. Recon: repos, CI and Homebrew inventory (2026-10-23).
