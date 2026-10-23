# The platform repository is public

Status: accepted (2026-10-23)

Every repository's devenv and every CI job imports this flake, across four GitHub owners. A private platform would need a GitHub App or a personal token in each consumer repository, and collaborators on client repositories could not load devenv. Since secrets moved to 1Password (ADR 0001), the repository holds no secret values: env templates use opaque 1Password IDs. So we decided to make it public, after a full-history secret scan, and accepted that the host layout (user name, home paths, launchd agents) and the spec and issue text become public.

## Considered Options

- Split into a public shared flake (overlay, pins, devenv module) and a private host repository (no public host details, but two repositories and one more update step for every overlay change).
- Keep it private with a GitHub App token per consumer repository.
