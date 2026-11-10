# wt-clonefile SRC DST: one clonefile(2) call that clones a whole directory
# (see wt-clonefile.c). Used by `wt new` to clone dependency folders into a
# worktree under WT_ROOT (modules/darwin.nix).
{ stdenv }:

stdenv.mkDerivation {
  pname = "wt-clonefile";
  version = "1";
  src = ./wt-clonefile.c;
  dontUnpack = true;
  buildPhase = ''
    $CC -std=c11 -O2 -Wall -Wextra -Werror -o wt-clonefile $src
  '';
  installPhase = ''
    install -Dm755 wt-clonefile $out/bin/wt-clonefile
  '';
  meta.mainProgram = "wt-clonefile";
}
