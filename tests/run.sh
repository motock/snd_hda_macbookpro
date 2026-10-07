#!/usr/bin/env bash
#
# tests/run.sh -- the HDA test runner.
#
# Discovers tests/test_*.sh, runs each one in its own subshell and reports a
# single line per file:
#
#     PASS <name>    test exited 0
#     FAIL <name>    test exited 1 (or any unexpected status)
#     SKIP <name>    test exited 77
#     XFAIL <name>   test is listed in xfail.list and failed, as expected
#     XPASS <name>   test is listed in xfail.list but passed -- the entry is
#                    stale and must be deleted
#
# followed by a summary line:
#
#     passed=N failed=N skipped=N xfail=N
#
# Exit status: 0 when nothing failed, 1 when any test FAILed or XPASSed.
#
# Environment:
#   HDA_TESTS_DIR   directory to discover tests in (default: this directory).
#                   Used by tests/test_runner_selfcheck.sh.
#   HDA_XFAIL_FILE  path to the expected-failure list (default:
#                   $HDA_TESTS_DIR/xfail.list).
#   HDA_TEST_CACHE  reserved for the kernel cache story; passed through to
#                   test files untouched.
#
# Compatible with bash 3.2 (macOS /bin/bash) and bash 5: no associative
# arrays, no `mapfile`, no `${var,,}`.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

TESTS_DIR=${HDA_TESTS_DIR:-$SCRIPT_DIR}
if [ ! -d "$TESTS_DIR" ]; then
  printf 'run.sh: test directory not found: %s\n' "$TESTS_DIR" >&2
  exit 2
fi
TESTS_DIR=$(cd "$TESTS_DIR" && pwd)

XFAIL_FILE=${HDA_XFAIL_FILE:-$TESTS_DIR/xfail.list}

# Run every test from the repository root so that test files can use paths
# relative to the checkout regardless of where the runner was invoked from.
cd "$REPO_ROOT" || exit 2

# ---------------------------------------------------------------------------
# xfail.list handling
# ---------------------------------------------------------------------------

# is_xfail <basename> -- 0 when the name is listed in xfail.list.
# Blank lines and `#` comments (whole-line or trailing) are ignored.
is_xfail() {
  [ -f "$XFAIL_FILE" ] || return 1
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line=${_line%%#*}
    while [ "${_line%[[:space:]]}" != "$_line" ]; do
      _line=${_line%[[:space:]]}
    done
    while [ "${_line#[[:space:]]}" != "$_line" ]; do
      _line=${_line#[[:space:]]}
    done
    [ -n "$_line" ] || continue
    if [ "$_line" = "$1" ]; then
      return 0
    fi
  done < "$XFAIL_FILE"
  return 1
}

# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------

passed=0
failed=0
skipped=0
xfail=0
xpass=0
found=0

# LC_ALL=C keeps the glob order stable across machines and locales.
LC_ALL=C
export LC_ALL

for _file in "$TESTS_DIR"/test_*.sh; do
  [ -e "$_file" ] || continue
  found=$((found + 1))
  _name=$(basename "$_file")

  bash "$_file"
  _rc=$?

  if [ "$_rc" -eq 0 ]; then
    if is_xfail "$_name"; then
      printf 'XPASS %s\n' "$_name"
      xpass=$((xpass + 1))
    else
      printf 'PASS %s\n' "$_name"
      passed=$((passed + 1))
    fi
  elif [ "$_rc" -eq 77 ]; then
    printf 'SKIP %s\n' "$_name"
    skipped=$((skipped + 1))
  elif [ "$_rc" -eq 1 ]; then
    if is_xfail "$_name"; then
      printf 'XFAIL %s\n' "$_name"
      xfail=$((xfail + 1))
    else
      printf 'FAIL %s\n' "$_name"
      failed=$((failed + 1))
    fi
  else
    # Any other status (including death by signal) is an unexpected failure.
    printf 'FAIL %s\n' "$_name"
    printf 'run.sh: %s exited with unexpected status %s\n' "$_name" "$_rc" >&2
    failed=$((failed + 1))
  fi
done

if [ "$found" -eq 0 ]; then
  printf 'run.sh: no tests/test_*.sh files found in %s\n' "$TESTS_DIR" >&2
fi

printf 'passed=%s failed=%s skipped=%s xfail=%s\n' \
  "$passed" "$failed" "$skipped" "$xfail"

if [ "$xpass" -gt 0 ]; then
  printf 'run.sh: %s test(s) unexpectedly passed; delete them from %s\n' \
    "$xpass" "$XFAIL_FILE" >&2
fi

if [ "$failed" -gt 0 ] || [ "$xpass" -gt 0 ]; then
  exit 1
fi
exit 0
