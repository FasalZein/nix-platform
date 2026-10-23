# Pi configuration ownership

`settings.nix` declares the `packages` and `extensions` arrays in
`~/.pi/agent/settings.json`. Home Manager replaces only these keys at activation.
All other settings remain owned by pi. Relative package paths resolve from
`~/.pi/agent`, so keep that base when editing the list.

The activation uses pinned jq, writes a temporary file in the settings directory,
and renames it into place. The result is a writable regular file with mode 0600,
not a Nix store symlink. A missing file starts as `{}`. Invalid JSON, an empty
file, or a value other than one JSON object stops activation without replacing
the file. Home Manager dry runs do not write settings.

Pi installs missing npm/git packages during normal online startup. Offline mode
skips missing packages. Activation does not run pi, install packages, or delete
unlisted installations. These upstream sources retain their current unpinned
versions; this configuration does not make their contents reproducible.

## Local sources and first switch

`modules/pi.nix` links the selected extension and package files to
`~/Dev/nix-platform/pi/`, always in the **main checkout**. Land the change there
before switching, even if the flake is built from a worktree. Otherwise these
links point at missing sources. Runtime edits through the links change the main
checkout; Nix generations do not freeze these out-of-store sources.

Home Manager backs up existing regular files with `.before-hm` before linking
them. An existing conflicting backup can block activation. Files inside
`env-wrap/` and `request-telemetry/` are linked individually, leaving the
directories in place. In particular, `env-wrap.before-hm/index.ts` would be
auto-discovered as another extension; `index.ts.before-hm` is not.

The existing `~/.pi/agent` extension paths stay unchanged, including paths used
by agent frontmatter. The herdr and moshi generated files, other local
extensions, the AI/pi repositories, and pi-shared-config are not managed here.

Stop pi sessions before switching: the atomic rename prevents a partial JSON
file, but does not serialize concurrent pi settings writes. A later switch
restores the declared lists if pi changes them at runtime.

Roll back the system with:

```sh
sudo /run/current-system/sw/bin/darwin-rebuild switch --rollback
```

Rollback does not undo arbitrary activation writes to settings, restore
`.before-hm` files automatically, or rewind the main checkout. To undo the first
migration completely, restore the local file backups after rollback and restore
only the two managed settings keys from a pre-switch copy. Preserve newer
runtime settings.

## Relocated checks

The associated tests were copied from `~/.pi/agent/tests/` with their fixtures.
Relative extension imports still work. The skill-gate check now resolves its
source and fixtures relative to the test, rather than testing the live source.
The original tests remain runnable through the unchanged live extension paths.

Run from this repository on the configured Mac:

```sh
heavy -- bun test pi/tests/env-wrap.test.ts pi/tests/pi-tps.test.ts pi/tests/shell-guard.test.ts pi/tests/sys1-launch-risk.test.ts
heavy -- bun pi/tests/skill-gate-check.ts
```

The env-wrap tests need the installed direnv, git, bash, and
`~/.pi/agent/bin/heavy`. The skill-gate integration check needs installed pi,
its live skills, pi-subagents and pi-better-skills. Its provider probes use a
closed local port or a fake provider, not a paid remote model.

Known baseline failure on 2026-10-23: the skill-gate integration check expects
`before_agent_start` counts `[1, 1, 1]` across its triggerTurn probe; installed pi
reports `[1, 2, 2]`. Both the original and relocated check fail identically.
This migration preserves that assertion and does not change extension behavior.

`sys1-launch-risk-live-check.ts` also remains runnable from this directory. It
needs the existing retrospective artifacts under `~/.pi/artifacts/` and calls
the remote classifier. It is not part of the offline migration checks.
