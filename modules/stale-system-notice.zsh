# Stale-system notice (owner 2026-11-24): an interactive zsh start prints one
# line on stderr when the active system was built from another revision than
# HEAD of the main checkout. Silent when they are equal, and when the
# repository, git or the version file is missing.
# A system built from a dirty tree (flake.nix: self.dirtyRev, "<rev>-dirty")
# always counts as different: it holds changes that no commit has, so the line
# shows "<short>-dirty" until a switch from a clean checkout.
# HEAD is read from .git without a fork (a git call doubled the cost, about
# 19 ms per shell start on 2026-11-24); git rev-parse is the fallback for a
# layout the direct read does not know.
# Placeholders are filled by modules/darwin.nix and by the check in flake.nix.
() {
  emulate -L zsh
  setopt extended_glob
  local json="@darwinVersionJson@" repo="@platformRepo@" active head line ref
  [[ -r $json && -d $repo ]] || return 0
  while IFS= read -r line; do
    [[ $line =~ '"configurationRevision": *"([^"]+)"' ]] && { active=$match[1]; break; }
  done < $json
  [[ -n $active ]] || return 0
  if [[ -r $repo/.git/HEAD ]] && read -r ref < $repo/.git/HEAD; then
    if [[ $ref == 'ref: '* ]]; then
      ref=${ref#ref: }
      if [[ -r $repo/.git/$ref ]]; then read -r head < $repo/.git/$ref
      elif [[ -r $repo/.git/packed-refs ]]; then
        while read -r line; do [[ $line == *" $ref" ]] && { head=${line%% *}; break; }; done < $repo/.git/packed-refs
      fi
    else head=$ref
    fi
  fi
  [[ $head == [0-9a-f](#c40) ]] || head=
  if [[ -z $head ]]; then
    (( $+commands[git] )) || return 0
    head=$(command git -C $repo rev-parse -q --verify HEAD 2>/dev/null) || return 0
  fi
  [[ $active == $head ]] && return 0
  local shown=${active[1,7]}
  [[ $active == *-dirty ]] && shown+=-dirty
  print -u2 "nix-platform: active system is $shown, ${repo/#$HOME/~} HEAD is ${head[1,7]}; apply with: cd ${repo/#$HOME/~} && sudo darwin-rebuild switch --flake .#MacBook-Pro-2"
}
