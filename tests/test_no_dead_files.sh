#!/usr/bin/env bash
#
# tests/test_no_dead_files.sh -- no unreferenced files under patches/, and
# .gitignore covers the build and patch byproducts.
#
#   R1 every file under patches/ is named by at least one other tracked file.
#   R2 each makefiles/ file is referenced by name.  makefiles/ is NOT held to
#      R1's rule: the installer reaches them through a $makefiles_dir variable
#      and Makefile semantics (Makefile_common is deliberately all comments),
#      so the reference is matched as "makefiles_dir/<name>" or
#      "makefiles/<name>" rather than by bare basename.
#   R3 .gitignore ignores generated artefacts and does not ignore real sources.
#
# The R1 negative case runs against a fixture git repo holding an orphan.

. "$(dirname "$0")/lib/assert.sh"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# orphans <repo> <dir>: print each tracked file under <dir> whose basename
# appears in no other tracked file.
orphans() {
  local repo=$1 dir=$2 f base
  while IFS= read -r f; do
    base=$(basename "$f")
    if [ -z "$(git -C "$repo" grep -l -F -e "$base" -- . ":!$f")" ]; then
      printf '%s\n' "$f"
    fi
  done < <(git -C "$repo" ls-files -- "$dir")
}

# --- R1 ---------------------------------------------------------------------
assert_eq "" "$(orphans "$REPO_ROOT" patches)" "R1 every patches/ file is referenced"

# --- R1 negative: fixture with an orphan -------------------------------------
fx=$(make_tmpdir)
git -C "$fx" init -q
mkdir "$fx/patches"
printf 'x\n' > "$fx/patches/orphan.diff"
printf 'x\n' > "$fx/patches/used.diff"
printf 'patch < patches/used.diff\n' > "$fx/install.sh"
git -C "$fx" add -A
assert_eq "patches/orphan.diff" "$(orphans "$fx" patches)" "R1 negative: fixture orphan is reported, referenced file is not"

# --- R2 ---------------------------------------------------------------------
for name in Makefile Makefile_common Makefile_codecs Makefile_cirrus; do
  hits=$(git -C "$REPO_ROOT" grep -l -E "makefiles(_dir\"?)?/$name([^A-Za-z0-9_]|\$)" -- . ":!makefiles")
  assert_ne "" "$hits" "R2 makefiles/$name is referenced by name"
done
assert_file_exists "$REPO_ROOT/makefiles/Makefile_common" "R2 makefiles/Makefile_common survives"

# --- R3 ---------------------------------------------------------------------
cd "$REPO_ROOT" || exit 1
for p in build/x.ko patch_cirrus/x.h.orig patch_cirrus/x.h.rej build/hda/x.o \
         build/hda/x.mod build/hda/x.mod.c build/hda/.x.o.cmd \
         build/hda/Module.symvers build/hda/modules.order; do
  git check-ignore -q "$p"
  assert_eq 0 $? "R3 $p is ignored"
done
git check-ignore -q patch_cirrus/cirrus_apple.h
assert_eq 1 $? "R3 positive control: patch_cirrus/cirrus_apple.h is not ignored"

finish
