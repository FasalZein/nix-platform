# 1Password is the secrets source; rendered at login through a service account

Status: accepted (2026-10-23)

The platform keeps no encrypted secrets in git: 1Password holds the only master copy, and a login agent renders env templates into owner-only files outside the Nix store through the saved 2password service account. We first chose sops-nix or agenix, then reversed: on one Mac, 1Password already held the values, and sops-nix would add a second copy, an age key to protect and a second place to update on every rotation, while the real pain was the desktop approval prompt that stops unattended agents (approval is per terminal session and expires after 10 idle minutes). App env is also rendered at login rather than resolved per command, because service accounts share an account-wide daily request cap (5,000 on Teams) and agents run hundreds of commands a day.

## Considered Options

- sops-nix with an age key (decrypts at login with no prompt; best for several machines or CI decryption; rejected for one Mac).
- agenix (no templates, so one file per key; no advantage here).
- Live resolution per command with `2password env run` (always fresh; rejected because a busy day can hit the daily cap and then every agent fails at once).

## Consequences

- Rendered env files are plain text on disk, owner-only and excluded from backups. Any process of the owner can read them, as with the old shell exports.
- The login agent depends on the 1Password service and the service-account token in the login keychain. A failed render keeps the last good file.
- Production credentials stay behind the desktop approval by design.
