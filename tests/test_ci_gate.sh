#!/usr/bin/env bash
#
# tests/test_ci_gate.sh -- behavior of tests/ci/gate.sh against fixture
# run.sh output files.  No network.
#
# Exit codes: 0 = pass, 1 = fail.
#
# Compatible with bash 3.2: no mapfile, no associative arrays.

set -u

HDA_TEST_DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$HDA_TEST_DIR/ci/gate.sh"

. "$HDA_TEST_DIR/lib/assert.sh"

WORK=$(make_tmpdir)

ALLOW="$WORK/allow.list"
printf '# comment\ntest_net.sh  # trailing comment\n\n' > "$ALLOW"

# write_run <name> <line>... -- fixture output file, one line per argument.
write_run() {
  _f="$WORK/$1"
  shift
  : > "$_f"
  for _l in "$@"; do
    printf '%s\n' "$_l" >> "$_f"
  done
}

# gate <file> -- run the gate with the fixture allow-list; sets OUT and RC.
gate() {
  OUT=$(HDA_CI_ALLOWED_SKIPS="$ALLOW" bash "$GATE" "$1" 2>&1)
  RC=$?
}

# --- success ---------------------------------------------------------------
write_run ok PASS\ test_a.sh XFAIL\ test_x.sh "passed=1 failed=0 skipped=0 xfail=1"
gate "$WORK/ok"
assert_eq 0 "$RC" "clean run passes the gate"
assert_contains "$OUT" "passed=1 failed=0 skipped=0 xfail=1" "summary line is printed"

write_run okskip PASS\ test_a.sh SKIP\ test_net.sh "passed=1 failed=0 skipped=1 xfail=0"
gate "$WORK/okskip"
assert_eq 0 "$RC" "allow-listed SKIP passes the gate"
assert_not_contains "$OUT" "warning" "used allow-list entry is not stale"

# --- failures --------------------------------------------------------------
write_run fail PASS\ test_a.sh FAIL\ test_bad.sh "passed=1 failed=1 skipped=0 xfail=0"
gate "$WORK/fail"
assert_eq 1 "$RC" "FAIL fails the gate"
assert_contains "$OUT" "test_bad.sh" "FAIL names the test"

write_run xpass XPASS\ test_old.sh "passed=0 failed=0 skipped=0 xfail=0"
gate "$WORK/xpass"
assert_eq 1 "$RC" "XPASS fails the gate"
assert_contains "$OUT" "test_old.sh" "XPASS names the test"

write_run badskip SKIP\ test_other.sh "passed=0 failed=0 skipped=1 xfail=0"
gate "$WORK/badskip"
assert_eq 1 "$RC" "unlisted SKIP fails the gate"
assert_contains "$OUT" "test_other.sh" "unlisted SKIP names the test"

# --- deny by default -------------------------------------------------------
write_run nosummary PASS\ test_a.sh
gate "$WORK/nosummary"
assert_eq 1 "$RC" "missing summary line fails the gate"

: > "$WORK/empty"
gate "$WORK/empty"
assert_eq 1 "$RC" "empty output file fails the gate"

gate "$WORK/does-not-exist"
assert_eq 1 "$RC" "unreadable output file fails the gate"

# --- stale allow-list entry ------------------------------------------------
gate "$WORK/ok"
assert_eq 0 "$RC" "stale allow-list entry does not fail the gate"
assert_contains "$OUT" "stale allow-list entry test_net.sh" "stale entry is warned about"

# --- usage -----------------------------------------------------------------
OUT=$(bash "$GATE" 2>&1)
RC=$?
assert_eq 2 "$RC" "no arguments is a usage error"
assert_contains "$OUT" "usage:" "usage text is printed"

OUT=$(bash "$GATE" a b 2>&1)
RC=$?
assert_eq 2 "$RC" "extra arguments is a usage error"

# --- step summary ----------------------------------------------------------
STEP="$WORK/step.md"
HDA_CI_ALLOWED_SKIPS="$ALLOW" GITHUB_STEP_SUMMARY="$STEP" bash "$GATE" "$WORK/ok" > /dev/null 2>&1
assert_contains "$(cat "$STEP")" "passed=1 failed=0 skipped=0 xfail=1" "summary appended to GITHUB_STEP_SUMMARY"

finish
