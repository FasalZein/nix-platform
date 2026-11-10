// wt-clonefile SRC DST: clones the directory SRC to DST with one
// clonefile(2) call. No macOS CLI does that: cp -c -R and ditto --clone clone
// file by file (31.8 s against 2.9 s for one directory clone, Spike A,
// 2026-11-10). clonefile(2) creates DST in one step, so a failed call leaves
// no partial DST. SRC and DST must be on the same APFS volume.
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>

#define EX_USAGE 64

int main(int argc, char **argv) {
  if (argc != 3) {
    fputs("usage: wt-clonefile SRC DST\n", stderr);
    return EX_USAGE;
  }
  char *src = argv[1];
  const char *dst = argv[2];
  struct stat st;
  int rc;
  // lstat("link/") follows the link, so trailing slashes go first ("/" stays).
  for (size_t n = strlen(src); n > 1 && src[n - 1] == '/'; n--) src[n - 1] = '\0';
  // A top-level symlink is not followed: lstat SRC, and SRC itself must be a
  // directory. clonefile keeps its default flags (0).
  if (lstat(src, &st) != 0) rc = -1;
  else if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; rc = -1; }
  else rc = clonefile(src, dst, 0);
  if (rc != 0) {
    fprintf(stderr, "wt-clonefile: clonefile %s -> %s: %s\n", src, dst, strerror(errno));
    return 1;
  }
  return 0;
}
