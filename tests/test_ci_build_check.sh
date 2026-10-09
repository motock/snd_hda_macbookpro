#!/usr/bin/env bash
#
# tests/test_ci_build_check.sh -- usage, negative paths and the verdict logic
# of lib/ci_build_check.sh.  Fully offline: no kernel is fetched or built.
# The real compile runs in CI (and by hand, see the script header), including
# the deliberate-error check (CI_BUILD_CHECK_INJECT_ERROR=1), which takes
# a full kernel configure and is far over the 60s this suite allows a test.

set -u

HDA_TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HDA_TEST_DIR/.." && pwd)
SCRIPT="$REPO_ROOT/lib/ci_build_check.sh"

. "$HDA_TEST_DIR/lib/assert.sh"
. "$HDA_TEST_DIR/kernel-pins.conf"
# shellcheck disable=SC1090
. "$SCRIPT"

SCRATCH=$(make_tmpdir)
export TMPDIR="$SCRATCH/tmp"
export HDA_TEST_CACHE="$SCRATCH/cache"
mkdir -p "$TMPDIR"

run() { bash "$SCRIPT" "$@" >"$SCRATCH/out" 2>&1; echo $?; }

# --- usage ------------------------------------------------------------------

assert_eq 0 "$(run -h)" "-h exits 0"
assert_contains "$(cat "$SCRATCH/out")" "usage:" "-h prints the usage text"

# --- bad invocations: exit 2, usage shown, no scratch dir left ---------------

assert_eq 2 "$(run)" "no arguments exits 2"
assert_contains "$(cat "$SCRATCH/out")" "usage:" "no arguments prints usage"

assert_eq 2 "$(run nonsense)" "an unknown pin exits 2"
assert_contains "$(cat "$SCRATCH/out")" "unknown pin or no such tarball" "unknown pin is named in the error"

assert_eq 2 "$(run "$SCRATCH/does-not-exist.tar.xz")" "a nonexistent tarball path exits 2"
assert_contains "$(cat "$SCRATCH/out")" "usage:" "a nonexistent tarball prints usage"

assert_eq 2 "$(run new extra)" "two arguments exit 2"

mkdir -p "$SCRATCH/unpinned"
echo junk > "$SCRATCH/unpinned/linux-0.0.tar.xz"
assert_eq 2 "$(run "$SCRATCH/unpinned/linux-0.0.tar.xz")" "a tarball with no pin to verify against exits 2"

# --- bad SHA ----------------------------------------------------------------

mkdir -p "$SCRATCH/badsha"
echo "not a kernel" > "$SCRATCH/badsha/$PIN_NEW_TARBALL"
assert_eq 1 "$(run "$SCRATCH/badsha/$PIN_NEW_TARBALL")" "a pinned tarball with the wrong SHA-256 exits 1"
assert_contains "$(cat "$SCRATCH/out")" "checksum mismatch" "the bad SHA is reported"

assert_eq "" "$(ls "$TMPDIR")" "no scratch dir is left behind by any failed invocation"

# --- injected syntax error: a real compiler diagnostic must fail the verdict --

if command -v cc >/dev/null 2>&1; then
  cp "$REPO_ROOT/patch_cirrus/patch_cirrus_boot84.h" "$SCRATCH/scratch_copy.h"
  echo 'int ci_injected_error = ;' >>"$SCRATCH/scratch_copy.h"
  echo obj >"$SCRATCH/inj.o"
  cc -fsyntax-only -x c "$SCRATCH/scratch_copy.h" >"$SCRATCH/inj.log" 2>&1
  ci_build_verdict "$SCRATCH/inj.log" 0 "$SCRATCH/inj.o" >/dev/null 2>&1
  assert_eq 1 "$?" "a syntax error injected into a scratch header copy fails the verdict"
fi

# --- verdict (fixture logs) ---------------------------------------------------

OBJ="$SCRATCH/cs8409.o"
echo obj > "$OBJ"
MODPOST='ERROR: modpost: "snd_hda_codec_probe" [/x/cs8409.ko] undefined!'

verdict() { # <log text> <make rc> <obj>
  printf '%s\n' "$1" > "$SCRATCH/log"
  ci_build_verdict "$SCRATCH/log" "$2" "$3" >/dev/null 2>&1
  echo $?
}

assert_eq 0 "$(verdict "  CC [M]  cs8409.o
$MODPOST
make[2]: *** [scripts/Makefile.modpost:145: __modpost] Error 1" 2 "$OBJ")" \
  "clean compile with only the expected modpost undefined symbols passes"
assert_eq 0 "$(verdict "  CC [M]  cs8409.o" 0 "$OBJ")" "clean compile and make exit 0 passes"
assert_eq 0 "$(verdict "cs8409.c:10:5: warning: unused variable 'x' [-Wunused-variable]
$MODPOST" 2 "$OBJ")" "a compiler warning is reported but does not fail the build"
assert_contains "$(ci_build_verdict "$SCRATCH/log" 2 "$OBJ" 2>&1)" "warnings=1" "the warning count is printed"
assert_eq 1 "$(verdict "cs8409.c:10:5: error: 'x' undeclared
$MODPOST" 2 "$OBJ")" "a compiler error fails"
assert_eq 1 "$(verdict "$MODPOST" 2 "$SCRATCH/missing.o")" "a missing cs8409.o fails"
assert_eq 1 "$(verdict "  CC [M]  cs8409.o
make[2]: *** Error 1" 2 "$OBJ")" "a non-zero make status without modpost output fails"
assert_eq 1 "$(verdict "ERROR: modpost: something else is wrong
$MODPOST" 2 "$OBJ")" "an unexpected modpost error fails"
: > "$SCRATCH/empty.o"
assert_eq 1 "$(verdict "  CC [M]  cs8409.o" 0 "$SCRATCH/empty.o")" "an empty cs8409.o fails"

SYMVERS_MISSING='WARNING: /tmp/ci-build-check.AbC123/linux/Module.symvers is missing.'
SUPPRESSED='WARNING: modpost: suppressed 67 unresolved symbol warnings because there were too many)'
assert_eq 0 "$(verdict "$SYMVERS_MISSING
$MODPOST
$SUPPRESSED
make[2]: *** [Makefile:1961: modpost] Error 2" 2 "$OBJ")" \
  "the Module.symvers-missing and suppressed-N modpost lines pass"
assert_eq 1 "$(verdict "$SYMVERS_MISSING
$MODPOST
$SUPPRESSED
ERROR: something else" 2 "$OBJ")" "an unrelated ERROR beside the accepted modpost lines fails"
assert_eq 1 "$(verdict "$SYMVERS_MISSING
$MODPOST
$SUPPRESSED
WARNING: something else" 2 "$OBJ")" "an unrelated WARNING beside the accepted modpost lines fails"
printf '%s\n%s\nWARNING: something else\n' "$MODPOST" "$SUPPRESSED" > "$SCRATCH/log"
assert_contains "$(ci_build_verdict "$SCRATCH/log" 2 "$OBJ" 2>&1)" "1 unexpected ERROR/WARNING" \
  "the unexpected line count is named"

finish
