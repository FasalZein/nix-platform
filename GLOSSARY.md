# nix-platform

Machine configuration for the owner's Mac and the shared Nix pins and devenv module that every repository imports.

## Language

### Secrets

**Agent vault**:
The 1Password vault that holds every secret unattended agents may use, readable by the service account without a prompt.
_Avoid_: automation vault, service-accounts vault, shared vault

**Service account**:
The 1Password machine identity that reads the agent vault with no human approval.
_Avoid_: bot account, token user

**Shell secret**:
A secret that tools and skills read from an environment variable in every shell.
_Avoid_: shell key, zshrc key, API env

**Env template**:
A file that lists the variables of one rendered env file as 1Password references, never as values.
_Avoid_: .env.tpl (when meaning the concept), secret file

**App env**:
The environment one project needs for one stage (dev, staging or production).
_Avoid_: runtime env, project secrets

**Rendered env file**:
A plain-text file made from one env template, outside every repository and the Nix store, readable only by the owner.
_Avoid_: resolved .env, secrets file, decrypted file

**Secrets refresh**:
Rendering every env template again on demand, with no prompt.
_Avoid_: re-sync, reload

**Production credential**:
A secret that can change production systems; it stays behind the 1Password desktop approval.
_Avoid_: prod key

### Versions and repos

**Platform**:
This repository: the host configuration, the shared overlay and the shared devenv module.
_Avoid_: nix config, dotfiles

**Pin**:
The exact tool version a repository or the platform requires.
_Avoid_: lock, version constraint

**Security pin**:
A pin that a repository needs for a security fix and that is newer than the platform's nixpkgs.
_Avoid_: hotfix version

**Parity**:
CI and local shells run the same tool versions from the same platform pins.
_Avoid_: consistency, reproducibility (when meaning only versions)

**Phase-2 repo**:
A repository on the approved list that gets a tools-first devenv in phase 2.
_Avoid_: active repo (when meaning the approved list)

**Attended step**:
A step that needs the owner at the Mac, such as a sudo switch, a direnv approval or a 1Password approval.
_Avoid_: manual step
