#!/usr/bin/env bash
#
# tests/test_runner_selfcheck.sh
#
# Self-test for the HDA test harness.  Two sections:
#
#   1. tests/lib/assert.sh -- every assertion gets a positive and a negative
#      case, plus the skip (77) contract and make_tmpdir cleanup.
#   2. tests/run.sh        -- PASS / FAIL / SKIP / XFAIL / XPASS reporting and
#      the runner's exit status.
#
# Exit codes: 0 = pass, 1 = fail, 77 = skip.
#
# Written to run under bash 3.2 (macOS /bin/bash) as well as bash 5:
# no associative arrays, no mapfile, no ${var,,}.

set -u

HDA_TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HDA_TEST_DIR/.." && pwd)
RUNNER="$HDA_TEST_DIR/run.sh"
ASSERT_LIB="$HDA_TEST_DIR/lib/assert.sh"

. "$ASSERT_LIB"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Run a snippet of bash in a fresh subshell with the assertion library sourced.
# The snippet's exit status becomes the subshell's exit status, so callers can
# assert on it with assert_exit_code / assert_exit_nonzero.
run_snippet() {
  bash -c '
    set -u
    . "$1" || exit 99
    eval "$2"
  ' _ "$ASSERT_LIB" "$1"
}

# Same as run_snippet but captures combined stdout+stderr into SNIPPET_OUT and
# the status into SNIPPET_RC.  A command substitution runs in a subshell, so a
# snippet can never leak state into this file.
run_snippet_capture() {
  SNIPPET_OUT=$(run_snippet "$1" 2>&1)
  SNIPPET_RC=$?
}

# Run the real runner against a scratch suite directory.  HDA_TESTS_DIR and
# HDA_XFAIL_FILE are the runner's documented testing seams.
run_runner() {
  _suite=$1
  HDA_TESTS_DIR="$_suite" HDA_XFAIL_FILE="$_suite/xfail.list" bash "$RUNNER" 2>&1
}

run_runner_capture() {
  RUNNER_OUT=$(run_runner "$1")
  RUNNER_RC=$?
}

# Create a scratch suite directory (auto-removed by the library's EXIT trap).
new_suite() {
  make_tmpdir
}

# Write a test file into a suite directory.  Usage: write_test <dir> <name> <body>
write_test() {
  printf '%s\n' "$3" > "$1/$2"
}

# ===========================================================================
# Section 1: tests/lib/assert.sh
# ===========================================================================

# --- assert_eq -------------------------------------------------------------

assert_exit_code 0 run_snippet 'assert_eq 1 1 "eq equal"; finish' \
  "assert_eq passes when values are equal"
run_snippet_capture 'assert_eq 1 2 "eq unequal"; finish'
assert_eq 1 "$SNIPPET_RC" "assert_eq fails when values differ"

run_snippet_capture 'assert_eq 1 2 "eq message"; finish'
assert_eq 1 "$SNIPPET_RC" "assert_eq failure exits 1"
assert_contains "$SNIPPET_OUT" "FAIL: eq message" \
  "assert_eq failure prints the caller's message"
assert_contains "$SNIPPET_OUT" "expected '1'" \
  "assert_eq failure prints the expected value"
assert_contains "$SNIPPET_OUT" "got '2'" \
  "assert_eq failure prints the actual value"

# --- assert_ne -------------------------------------------------------------

assert_exit_code 0 run_snippet 'assert_ne 1 2 "ne different"; finish' \
  "assert_ne passes when values differ"
run_snippet_capture 'assert_ne 1 1 "ne same"; finish'
assert_eq 1 "$SNIPPET_RC" "assert_ne fails when values are equal"

run_snippet_capture 'assert_ne 1 1 "ne message"; finish'
assert_contains "$SNIPPET_OUT" "FAIL: ne message" \
  "assert_ne failure prints the caller's message"

# --- assert_contains -------------------------------------------------------

assert_exit_code 0 run_snippet 'assert_contains "hello world" "lo wo" "contains hit"; finish' \
  "assert_contains passes when the needle is present"
run_snippet_capture 'assert_contains "hello world" "zzz" "contains miss"; finish'
assert_eq 1 "$SNIPPET_RC" "assert_contains fails when the needle is absent"

run_snippet_capture 'assert_contains "hello" "zzz" "contains message"; finish'
assert_contains "$SNIPPET_OUT" "FAIL: contains message" \
  "assert_contains failure prints the caller's message"

# --- assert_not_contains ---------------------------------------------------

assert_exit_code 0 run_snippet 'assert_not_contains "hello" "zzz" "notcontains hit"; finish' \
  "assert_not_contains passes when the needle is absent"
run_snippet_capture 'assert_not_contains "hello" "ell" "notcontains miss"; finish'
assert_eq 1 "$SNIPPET_RC" "assert_not_contains fails when the needle is present"

run_snippet_capture 'assert_not_contains "hello" "ell" "notcontains message"; finish'
assert_contains "$SNIPPET_OUT" "FAIL: notcontains message" \
  "assert_not_contains failure prints the caller's message"

# --- assert_file_exists ----------------------------------------------------

_existing_file=$(make_tmpdir)/present.txt
printf 'x\n' > "$_existing_file"
assert_exit_code 0 run_snippet "assert_file_exists '$_existing_file' 'file present'; finish" \
  "assert_file_exists passes for an existing file"
run_snippet_capture "assert_file_exists '$_existing_file.nope' 'file absent'; finish"
assert_eq 1 "$SNIPPET_RC" "assert_file_exists fails for a missing file"

run_snippet_capture "assert_file_exists '$_existing_file.nope' 'file message'; finish"
assert_contains "$SNIPPET_OUT" "FAIL: file message" \
  "assert_file_exists failure prints the caller's message"

# --- assert_exit_code ------------------------------------------------------

assert_exit_code 0 run_snippet 'assert_exit_code 0 true "exit code match"; finish' \
  "assert_exit_code passes when the status matches"
run_snippet_capture 'assert_exit_code 0 false "exit code mismatch"; finish'
assert_eq 1 "$SNIPPET_RC" "assert_exit_code fails when the status differs"

run_snippet_capture 'assert_exit_code 0 false; finish'
assert_contains "$SNIPPET_OUT" "FAIL: command 'false'" \
  "assert_exit_code failure names the command that ran"
assert_contains "$SNIPPET_OUT" "expected exit code 0, got 1" \
  "assert_exit_code failure prints the expected and actual status"

# --- assert_exit_nonzero ---------------------------------------------------

assert_exit_code 0 run_snippet 'assert_exit_nonzero false; finish' \
  "assert_exit_nonzero passes for a failing command"
run_snippet_capture 'assert_exit_nonzero true; finish'
assert_eq 1 "$SNIPPET_RC" "assert_exit_nonzero fails for a succeeding command"

run_snippet_capture 'assert_exit_nonzero true; finish'
assert_contains "$SNIPPET_OUT" "FAIL: command 'true'" \
  "assert_exit_nonzero failure names the command that ran"
assert_contains "$SNIPPET_OUT" "expected a non-zero exit code, got 0" \
  "assert_exit_nonzero failure prints the actual status"

# --- skip ------------------------------------------------------------------

run_snippet_capture 'skip "not applicable here"'
assert_eq 77 "$SNIPPET_RC" "skip exits with status 77"
assert_contains "$SNIPPET_OUT" "SKIP: not applicable here" \
  "skip prints a SKIP line naming the reason"

# --- make_tmpdir -----------------------------------------------------------

_tmp_record=$(make_tmpdir)/recorded-path
run_snippet_capture "d=\$(make_tmpdir); printf '%s\n' \"\$d\" > '$_tmp_record'; [ -d \"\$d\" ] || exit 9; finish"
assert_eq 0 "$SNIPPET_RC" "make_tmpdir returns a directory that exists while the test runs"
_recorded_dir=$(cat "$_tmp_record")
assert_contains "$_recorded_dir" "hda-test." \
  "make_tmpdir creates a recognisably named scratch directory"
assert_exit_nonzero test -d "$_recorded_dir"
assert_not_contains "$_recorded_dir" "nonexistent" \
  "make_tmpdir returned a real path (sanity check on the recorded path)"

# --- finish ----------------------------------------------------------------

assert_exit_code 0 run_snippet 'finish' \
  "finish exits 0 when no assertion failed"
assert_exit_code 0 run_snippet 'assert_eq 1 1 "ok"; assert_ne 1 2 "ok"; finish' \
  "finish exits 0 after several passing assertions"

run_snippet_capture 'assert_eq 1 2 "first failure"; assert_eq 3 4 "second failure"; finish'
assert_eq 1 "$SNIPPET_RC" "finish exits 1 when any assertion failed"
assert_contains "$SNIPPET_OUT" "FAIL: first failure" \
  "finish reports the first failed assertion"
assert_contains "$SNIPPET_OUT" "FAIL: second failure" \
  "finish reports every failed assertion, not just the first"

# ===========================================================================
# Section 2: tests/run.sh
# ===========================================================================

# --- a clean suite passes --------------------------------------------------

_suite=$(new_suite)
write_test "$_suite" test_alpha.sh 'exit 0'
write_test "$_suite" test_beta.sh 'exit 0'
run_runner_capture "$_suite"
assert_eq 0 "$RUNNER_RC" "runner exits 0 when every test passes"
assert_contains "$RUNNER_OUT" "PASS test_alpha.sh" "runner reports PASS for a passing test"
assert_contains "$RUNNER_OUT" "PASS test_beta.sh" "runner reports PASS for each passing test"
assert_contains "$RUNNER_OUT" "passed=2 failed=0 skipped=0 xfail=0" \
  "runner prints a summary line with counts"

# --- a failing test fails the run ------------------------------------------

_suite=$(new_suite)
write_test "$_suite" test_good.sh 'exit 0'
write_test "$_suite" test_bad.sh 'exit 1'
run_runner_capture "$_suite"
assert_exit_nonzero test "$RUNNER_RC" -eq 0
assert_contains "$RUNNER_OUT" "FAIL test_bad.sh" "runner reports FAIL for a failing test"
assert_contains "$RUNNER_OUT" "passed=1 failed=1 skipped=0 xfail=0" \
  "runner counts the failing test in the summary"

# --- exit 77 is a skip, not a failure --------------------------------------

_suite=$(new_suite)
write_test "$_suite" test_skipped.sh 'exit 77'
run_runner_capture "$_suite"
assert_eq 0 "$RUNNER_RC" "runner exits 0 when the only test skips"
assert_contains "$RUNNER_OUT" "SKIP test_skipped.sh" "runner reports SKIP for exit 77"
assert_contains "$RUNNER_OUT" "passed=0 failed=0 skipped=1 xfail=0" \
  "runner counts the skipped test in the summary"

# --- xfail: a listed test that fails is expected ---------------------------

_suite=$(new_suite)
write_test "$_suite" test_known_bug.sh 'exit 1'
printf '# comment line\n\ntest_known_bug.sh\n' > "$_suite/xfail.list"
run_runner_capture "$_suite"
assert_eq 0 "$RUNNER_RC" "runner exits 0 when a listed test fails as expected"
assert_contains "$RUNNER_OUT" "XFAIL test_known_bug.sh" \
  "runner reports XFAIL for a listed test that fails"
assert_contains "$RUNNER_OUT" "passed=0 failed=0 skipped=0 xfail=1" \
  "runner counts the expected failure in the summary"

# --- xpass: a listed test that passes fails the run ------------------------

_suite=$(new_suite)
write_test "$_suite" test_known_bug.sh 'exit 0'
printf 'test_known_bug.sh\n' > "$_suite/xfail.list"
run_runner_capture "$_suite"
assert_exit_nonzero test "$RUNNER_RC" -eq 0
assert_contains "$RUNNER_OUT" "XPASS test_known_bug.sh" \
  "runner reports XPASS for a listed test that unexpectedly passes"

# --- an unlisted failure is still a failure --------------------------------

_suite=$(new_suite)
write_test "$_suite" test_known_bug.sh 'exit 1'
write_test "$_suite" test_other.sh 'exit 1'
printf 'test_known_bug.sh\n' > "$_suite/xfail.list"
run_runner_capture "$_suite"
assert_exit_nonzero test "$RUNNER_RC" -eq 0
assert_contains "$RUNNER_OUT" "XFAIL test_known_bug.sh" \
  "runner still reports XFAIL for the listed test"
assert_contains "$RUNNER_OUT" "FAIL test_other.sh" \
  "runner reports FAIL for an unlisted failing test"

# --- the real suite is discoverable ----------------------------------------

assert_file_exists "$RUNNER" "tests/run.sh exists"
assert_file_exists "$ASSERT_LIB" "tests/lib/assert.sh exists"
assert_file_exists "$HDA_TEST_DIR/xfail.list" "tests/xfail.list exists"
assert_file_exists "$REPO_ROOT/Makefile" "the root Makefile exists"

finish
