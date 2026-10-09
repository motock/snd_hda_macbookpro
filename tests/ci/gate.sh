#!/usr/bin/env bash
#
# tests/ci/gate.sh -- CI gate over captured tests/run.sh output.
#
# Usage: tests/ci/gate.sh <run-output-file>
#
# Reads the PASS/FAIL/SKIP/XFAIL/XPASS lines and the summary line that
# tests/run.sh prints, and fails the build on:
#   * any FAIL or XPASS line,
#   * any SKIP of a test not listed in tests/ci/allowed-skips.list,
#   * a missing summary line, or an empty/unreadable output file
#     (deny by default: no evidence of a run is not a green run).
# A listed test that did not SKIP is only a warning (stale entry).
#
# Environment:
#   HDA_CI_ALLOWED_SKIPS  allow-list path (default: allowed-skips.list beside
#                         this script).  Syntax matches tests/xfail.list.
#   GITHUB_STEP_SUMMARY   when set, the summary line is appended to it.
#
# Exit status: 0 gate passed, 1 gate failed, 2 usage error.
#
# Compatible with bash 3.2: no mapfile, no associative arrays.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ALLOW_FILE=${HDA_CI_ALLOWED_SKIPS:-$SCRIPT_DIR/allowed-skips.list}

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <run-output-file>\n' "$0" >&2
  exit 2
fi
OUTPUT_FILE=$1

if [ ! -f "$OUTPUT_FILE" ] || [ ! -r "$OUTPUT_FILE" ] || [ ! -s "$OUTPUT_FILE" ]; then
  printf 'gate: run output missing, unreadable or empty: %s\n' "$OUTPUT_FILE" >&2
  exit 1
fi

# read_names <file> -- print the test names in an allow-list, one per line.
read_names() {
  [ -f "$1" ] || return 0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line=${_line%%#*}
    while [ "${_line%[[:space:]]}" != "$_line" ]; do
      _line=${_line%[[:space:]]}
    done
    while [ "${_line#[[:space:]]}" != "$_line" ]; do
      _line=${_line#[[:space:]]}
    done
    [ -n "$_line" ] && printf '%s\n' "$_line"
  done < "$1"
}

ALLOWED=$(read_names "$ALLOW_FILE")

is_allowed() {
  printf '%s\n' "$ALLOWED" | grep -Fxq -- "$1"
}

status=0
summary=
skipped_names=

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "FAIL "*)
      printf 'gate: FAIL %s\n' "${line#FAIL }" >&2
      status=1
      ;;
    "XPASS "*)
      printf 'gate: XPASS %s (stale xfail.list entry)\n' "${line#XPASS }" >&2
      status=1
      ;;
    "SKIP "*)
      _name=${line#SKIP }
      skipped_names="$skipped_names$_name
"
      if ! is_allowed "$_name"; then
        printf 'gate: unexpected SKIP %s (not in %s)\n' "$_name" "$ALLOW_FILE" >&2
        status=1
      fi
      ;;
    passed=*" failed="*" skipped="*" xfail="*)
      summary=$line
      ;;
  esac
done < "$OUTPUT_FILE"

if [ -z "$summary" ]; then
  printf 'gate: no summary line (passed=N failed=N skipped=N xfail=N) in %s\n' \
    "$OUTPUT_FILE" >&2
  exit 1
fi

# Warn about allow-list entries that no longer skip.
while IFS= read -r _name; do
  [ -n "$_name" ] || continue
  if ! printf '%s' "$skipped_names" | grep -Fxq -- "$_name"; then
    printf 'gate: warning: stale allow-list entry %s did not SKIP\n' "$_name" >&2
  fi
done <<EOF2
$ALLOWED
EOF2

printf '%s\n' "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"
fi

exit "$status"
