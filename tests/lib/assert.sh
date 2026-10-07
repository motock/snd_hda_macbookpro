#!/usr/bin/env bash
#
# tests/lib/assert.sh -- assertion helpers for the HDA test suite.
#
# Source it from a test file:
#
#     . "$(dirname "$0")/lib/assert.sh"
#
#     assert_eq 1 1 "one equals one"
#     assert_contains "$output" "hello" "greeting is present"
#     finish
#
# Design notes
# ------------
# * Assertions never abort the test.  A failing assertion prints
#       FAIL: <msg> (expected <...>, got <...>)
#   to stderr and records the failure, so a single run reports every problem.
# * `finish` must be the last statement of the test file.  It exits 1 if any
#   assertion failed and 0 otherwise.
# * Test-file exit-code contract: 0 = pass, 1 = fail, 77 = skip.
# * `make_tmpdir` creates a scratch directory that is removed when the test
#   process exits.  Directories are tracked in a registry *file* rather than a
#   shell variable so that `d=$(make_tmpdir)` -- which runs in a subshell --
#   is still cleaned up by the parent process.
# * Sourcing this file installs an EXIT trap.  A test file that needs its own
#   EXIT trap must chain to `_hda_cleanup_tmpdirs`.
# * Compatible with bash 3.2 (macOS /bin/bash) and bash 5: no associative
#   arrays, no `mapfile`, no `${var,,}`, no `local -n`.

# ---------------------------------------------------------------------------
# internal state
# ---------------------------------------------------------------------------

if [ "${_HDA_ASSERT_LOADED:-0}" != "1" ]; then
  _HDA_ASSERT_LOADED=1
  HDA_ASSERT_FAILURES=0
  _HDA_TMPDIRS=""
  _HDA_TMPDIR_REGISTRY="${TMPDIR:-/tmp}/hda-test-tmpdirs.$$"
  if ! : > "$_HDA_TMPDIR_REGISTRY" 2>/dev/null; then
    _HDA_TMPDIR_REGISTRY=""
  fi
fi

# ---------------------------------------------------------------------------
# internals
# ---------------------------------------------------------------------------

# Record a failure and print it.  Never exits: the test keeps running so that
# every problem in the file is reported in one pass.
_hda_fail() {
  HDA_ASSERT_FAILURES=$((HDA_ASSERT_FAILURES + 1))
  printf 'FAIL: %s\n' "$1" >&2
  return 1
}

_hda_register_tmpdir() {
  if [ -n "${_HDA_TMPDIR_REGISTRY:-}" ]; then
    printf '%s\n' "$1" >> "$_HDA_TMPDIR_REGISTRY"
  else
    _HDA_TMPDIRS="${_HDA_TMPDIRS:-} $1"
  fi
}

# EXIT trap: remove every scratch directory make_tmpdir handed out, then
# preserve the status the test process was already exiting with.
_hda_cleanup_tmpdirs() {
  _hda_rc=$?
  if [ -n "${_HDA_TMPDIR_REGISTRY:-}" ] && [ -f "$_HDA_TMPDIR_REGISTRY" ]; then
    while IFS= read -r _hda_dir || [ -n "$_hda_dir" ]; do
      if [ -n "$_hda_dir" ]; then
        rm -rf -- "$_hda_dir"
      fi
    done < "$_HDA_TMPDIR_REGISTRY"
    rm -f -- "$_HDA_TMPDIR_REGISTRY"
  fi
  if [ -n "${_HDA_TMPDIRS:-}" ]; then
    for _hda_dir in $_HDA_TMPDIRS; do
      rm -rf -- "$_hda_dir"
    done
  fi
  return "$_hda_rc"
}

if [ "${_HDA_TMPDIR_TRAP:-0}" != "1" ]; then
  _HDA_TMPDIR_TRAP=1
  trap '_hda_cleanup_tmpdirs' EXIT
fi

# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------

# assert_eq <expected> <actual> <msg>
assert_eq() {
  if [ "$#" -lt 3 ]; then
    _hda_fail "assert_eq: usage: assert_eq <expected> <actual> <msg> (got $# argument(s))"
    return 1
  fi
  if [ "$1" = "$2" ]; then
    return 0
  fi
  _hda_fail "$3 (expected '$1', got '$2')"
  return 1
}

# assert_ne <unexpected> <actual> <msg>
assert_ne() {
  if [ "$#" -lt 3 ]; then
    _hda_fail "assert_ne: usage: assert_ne <unexpected> <actual> <msg> (got $# argument(s))"
    return 1
  fi
  if [ "$1" != "$2" ]; then
    return 0
  fi
  _hda_fail "$3 (expected a value different from '$1', got '$2')"
  return 1
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  if [ "$#" -lt 3 ]; then
    _hda_fail "assert_contains: usage: assert_contains <haystack> <needle> <msg> (got $# argument(s))"
    return 1
  fi
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  _hda_fail "$3 (expected to contain '$2', got '$1')"
  return 1
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  if [ "$#" -lt 3 ]; then
    _hda_fail "assert_not_contains: usage: assert_not_contains <haystack> <needle> <msg> (got $# argument(s))"
    return 1
  fi
  case "$1" in
    *"$2"*) ;;
    *) return 0 ;;
  esac
  _hda_fail "$3 (expected not to contain '$2', got '$1')"
  return 1
}

# assert_file_exists <path> <msg>
assert_file_exists() {
  if [ "$#" -lt 2 ]; then
    _hda_fail "assert_file_exists: usage: assert_file_exists <path> <msg> (got $# argument(s))"
    return 1
  fi
  if [ -e "$1" ]; then
    return 0
  fi
  _hda_fail "$2 (expected file '$1' to exist, got 'no such file')"
  return 1
}

# assert_exit_code <expected> <cmd> [args...]
assert_exit_code() {
  if [ "$#" -lt 2 ]; then
    _hda_fail "assert_exit_code: usage: assert_exit_code <expected> <cmd> [args...] (got $# argument(s))"
    return 1
  fi
  _hda_expected=$1
  shift
  "$@"
  _hda_actual=$?
  if [ "$_hda_actual" -eq "$_hda_expected" ]; then
    return 0
  fi
  _hda_fail "command '$*' (expected exit code $_hda_expected, got $_hda_actual)"
  return 1
}

# assert_exit_nonzero <cmd> [args...]
assert_exit_nonzero() {
  if [ "$#" -lt 1 ]; then
    _hda_fail "assert_exit_nonzero: usage: assert_exit_nonzero <cmd> [args...] (got 0 arguments)"
    return 1
  fi
  "$@"
  _hda_actual=$?
  if [ "$_hda_actual" -ne 0 ]; then
    return 0
  fi
  _hda_fail "command '$*' (expected a non-zero exit code, got 0)"
  return 1
}

# ---------------------------------------------------------------------------
# control
# ---------------------------------------------------------------------------

# skip <msg> -- abandon the test file with the runner's skip exit code.
skip() {
  printf 'SKIP: %s\n' "${1:-no reason given}" >&2
  exit 77
}

# make_tmpdir -- print the path of a fresh scratch directory.  It is removed
# when the test process exits, including when make_tmpdir is called inside a
# command substitution.
make_tmpdir() {
  local _hda_dir
  _hda_dir=$(mktemp -d "${TMPDIR:-/tmp}/hda-test.XXXXXX")
  if [ -z "$_hda_dir" ] || [ ! -d "$_hda_dir" ]; then
    _hda_fail "make_tmpdir: mktemp -d failed"
    return 1
  fi
  _hda_register_tmpdir "$_hda_dir"
  printf '%s\n' "$_hda_dir"
}

# finish -- last statement of a test file.  Exits 1 if any assertion failed.
finish() {
  if [ "${HDA_ASSERT_FAILURES:-0}" -gt 0 ]; then
    printf 'FAIL: %s assertion(s) failed\n' "$HDA_ASSERT_FAILURES" >&2
    exit 1
  fi
  exit 0
}
