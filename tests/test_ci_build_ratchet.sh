#!/usr/bin/env bash
#
# tests/test_ci_build_ratchet.sh -- warning ratchet of lib/ci_build_warnings.sh
# against canned logs.  Offline: no kernel is fetched or built.

set -u

HDA_TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HDA_TEST_DIR/.." && pwd)

. "$HDA_TEST_DIR/lib/assert.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/ci_build_warnings.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/ci_build_check.sh"

SCRATCH=$(make_tmpdir)
export TMPDIR="$SCRATCH"
unset CI_BUILD_WARNINGS_UPDATE

W1="codecs/cirrus/a.h:10:5: warning: unused variable 'x' [-Wunused-variable]"
W2="codecs/cirrus/a.h:20:5: warning: unused variable 'y' [-Wunused-variable]"
WF="codecs/cirrus/b.h:7:1: warning: 'f' defined but not used [-Wunused-function]"

BASE="$SCRATCH/base.txt"
printf 'codecs/cirrus/a.h unused-variable 2\ncodecs/cirrus/b.h unused-function 1\n' >"$BASE"

# check <log text> [baseline] -- run the ratchet; output to $SCRATCH/out, echo status
check() {
  printf '%s\n' "$1" >"$SCRATCH/log"
  cbw_check "$SCRATCH/log" "${2:-$BASE}" >"$SCRATCH/out" 2>&1
  echo $?
}
out() { cat "$SCRATCH/out"; }

# --- counting ---------------------------------------------------------------

printf '%s\n%s\n%s\n' "$W1" "$W2" "$WF" >"$SCRATCH/log"
assert_eq "codecs/cirrus/a.h unused-variable 2
codecs/cirrus/b.h unused-function 1" "$(cbw_counts "$SCRATCH/log")" "counts are grouped per file and kind, sorted"
printf '%s\n' "x.c:1:1: warning: odd" >"$SCRATCH/log"
assert_eq "x.c untagged 1" "$(cbw_counts "$SCRATCH/log")" "a warning with no -W tag is counted as untagged"

# --- ratchet ----------------------------------------------------------------

assert_eq 0 "$(check "$W1
$W2
$WF")" "equal counts pass"
assert_contains "$(out)" "measured=3 baseline=3" "measured and baseline totals are printed"

assert_eq 1 "$(check "$W1
$W2
$WF
src/new.c:3:3: warning: unused variable 'z' [-Wunused-variable]")" "a warning in a new file fails"
assert_contains "$(out)" "src/new.c: unused-variable" "the new file and kind are named"

assert_eq 1 "$(check "$W1
$W2
codecs/cirrus/a.h:30:1: warning: unused variable 'q' [-Wunused-variable]
$WF")" "an increased count fails"
assert_contains "$(out)" "more warnings in codecs/cirrus/a.h: unused-variable (count 3, baseline 2)" "the increase is reported"

assert_eq 1 "$(check "$W1
$WF")" "a decreased count fails"
assert_contains "$(out)" "lower the baseline" "a decrease tells the developer to lower the baseline"

assert_eq 1 "$(check "$W1
$W2")" "a vanished (file, kind) fails"
assert_contains "$(out)" "fewer warnings in codecs/cirrus/b.h: unused-function" "the vanished entry is named"

assert_eq 1 "$(check "$W1
$W2
$WF
codecs/cirrus/a.h:5:1: warning: comparison always true [-Wtype-limits]")" "an unknown warning kind fails"
assert_contains "$(out)" "new warning kind not in the baseline: type-limits" "the unknown kind is named"

# --- real errors still fail (the verdict runs alongside the ratchet) --------

printf '%s\n%s\n%s\ncodecs/cirrus/a.h:5:1: error: %s\n' "$W1" "$W2" "$WF" "'x' undeclared" >"$SCRATCH/log"
echo obj >"$SCRATCH/cs8409.o"
ci_build_verdict "$SCRATCH/log" 0 "$SCRATCH/cs8409.o" >/dev/null 2>&1
assert_eq 1 "$?" "a log with an error: line fails the verdict even when warning counts match"
assert_contains "$(ci_build_verdict "$SCRATCH/log" 0 "$SCRATCH/cs8409.o" 2>&1)" "compiler reported 1 error" "the error is reported"

# --- baseline validation: deny by default -----------------------------------

assert_eq 1 "$(check "$W1" "$SCRATCH/missing.txt")" "a missing baseline fails"
assert_contains "$(out)" "missing or empty" "the missing baseline is explained"

: >"$SCRATCH/empty.txt"
assert_eq 1 "$(check "$W1" "$SCRATCH/empty.txt")" "an empty baseline fails"
assert_contains "$(out)" "missing or empty" "the empty baseline is explained"

printf 'codecs/cirrus/a.h unused-variable\n' >"$SCRATCH/two.txt"
assert_eq 1 "$(check "$W1" "$SCRATCH/two.txt")" "a baseline line with two fields fails"
assert_contains "$(out)" "malformed warning baseline" "the malformed line is called out"
assert_contains "$(out)" "line 1: codecs/cirrus/a.h unused-variable" "the offending line is shown"

printf 'codecs/cirrus/a.h unused-variable many\n' >"$SCRATCH/nan.txt"
assert_eq 1 "$(check "$W1" "$SCRATCH/nan.txt")" "a non-numeric count fails"

printf 'codecs/cirrus/a.h unused-variable 0\n' >"$SCRATCH/zero.txt"
assert_eq 1 "$(check "$W1" "$SCRATCH/zero.txt")" "a zero count fails"

printf 'codecs/cirrus/a.h unused-variable 1\ncodecs/cirrus/a.h unused-variable 1\n' >"$SCRATCH/dup.txt"
assert_eq 1 "$(check "$W1" "$SCRATCH/dup.txt")" "a duplicated (file, kind) fails"
assert_contains "$(out)" "duplicate" "the duplicate is named"

# --- update flag ------------------------------------------------------------

cp "$BASE" "$SCRATCH/upd.txt"
printf '%s\n%s\n' "$W1" "$W2" >"$SCRATCH/log"
CI_BUILD_WARNINGS_UPDATE=1 cbw_check "$SCRATCH/log" "$SCRATCH/upd.txt" >/dev/null 2>&1
assert_eq "codecs/cirrus/a.h unused-variable 2" "$(cat "$SCRATCH/upd.txt")" "CI_BUILD_WARNINGS_UPDATE=1 rewrites the baseline from the log"

cp "$BASE" "$SCRATCH/upd.txt"
: >"$SCRATCH/log"
CI_BUILD_WARNINGS_UPDATE=1 cbw_check "$SCRATCH/log" "$SCRATCH/upd.txt" >/dev/null 2>&1
assert_eq 1 "$?" "update refuses to write an empty baseline"
assert_eq "$(cat "$BASE")" "$(cat "$SCRATCH/upd.txt")" "the baseline is untouched after a refused update"

# --- the committed baselines are themselves well formed ---------------------

cbw_validate_baseline "$REPO_ROOT/tests/ci/build-warning-baseline.new.txt" 2>/dev/null
assert_eq 0 "$?" "the committed baseline for the new pin is well formed"
cbw_validate_baseline "$REPO_ROOT/tests/ci/build-warning-baseline.7x.txt" 2>/dev/null
assert_eq 0 "$?" "the committed baseline for the 7x pin is well formed"

finish
