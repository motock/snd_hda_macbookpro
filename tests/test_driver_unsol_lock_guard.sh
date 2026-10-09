#!/usr/bin/env bash
#
# tests/test_driver_unsol_lock_guard.sh
#
# Controls for guard (d) of tests/test_driver_unsol_lock.sh, which decides
# whether the output of tests/test_hooks_apply.sh is "only the known hooks
# drift".  The guard must recognise the drift by its stable `FAIL: <assertion>`
# lines and ignore patch's own wording (BSD patch prints "hunks failed", GNU
# patch prints "N out of M hunks FAILED"), yet still fail on any other FAIL.
#
# Each case runs a scratch copy of the guard against a stubbed
# tests/test_hooks_apply.sh that replays canned output, so the repository's
# real hook-apply test is never involved.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/lib/assert.sh"

OFFSET_FAIL='FAIL: old: /w/patch_patch_cirrus_apple.h.diff applied with offset to /t/old-tree -- the hook is drifting (output: Hmm...  Looks like a unified diff to me...
Hunk #1 succeeded at 158 (offset 1 line).
done) (expected '"'absent', got 'present'"')'
HUNK_FAIL='FAIL: the failure says the hunk did not apply (expected to contain '"'hunks failed'"', got '"'checking file codecs/cirrus/cs8409.h
Hunk #1 FAILED at 19.
1 out of 4 hunks FAILED
done'"')'
TRAILER='hooks applied: 5 of 5 in play (root *.diff: 6)
FAIL: 2 assertion(s) failed'

# run_guard <stub-output> <stub-rc> -- run the guard in a scratch copy of the
# repository whose test_hooks_apply.sh replays <stub-output> and exits
# <stub-rc>.  Records GUARD_OUT and GUARD_RC.
run_guard() {
  local out=$1 stub_rc=$2 root
  root=$(make_tmpdir)
  mkdir -p "$root/tests" "$root/patches"
  cp "$REPO_ROOT"/patch_*.diff "$root"
  cp -R "$REPO_ROOT/patch_cirrus" "$root"
  cp "$REPO_ROOT"/patches/*.diff "$root/patches"
  cp "$REPO_ROOT/tests/test_driver_unsol_lock.sh" "$root/tests"
  printf '%s\n' "$out" > "$root/tests/stub_output.txt"
  printf '#!/usr/bin/env bash\ncat "$(dirname "$0")/stub_output.txt"\nexit %s\n' "$stub_rc" \
    > "$root/tests/test_hooks_apply.sh"
  GUARD_OUT=$(bash "$root/tests/test_driver_unsol_lock.sh" 2>&1)
  GUARD_RC=$?
}

run_guard "$OFFSET_FAIL
$HUNK_FAIL
$TRAILER" 1
assert_eq 0 "$GUARD_RC" "known drift plus GNU patch chatter passes guard (d) (output: $GUARD_OUT)"

run_guard "$OFFSET_FAIL
$TRAILER" 1
assert_eq 0 "$GUARD_RC" "known drift plus BSD patch chatter passes guard (d) (output: $GUARD_OUT)"

run_guard "$OFFSET_FAIL
FAIL: new: /w/patch_cs8409.h.diff applies to /t/new-tree (output: 1 out of 4 hunks FAILED)
$TRAILER" 1
assert_ne 0 "$GUARD_RC" "a new failing hook assertion fails guard (d)"
assert_contains "$GUARD_OUT" "patch_cs8409.h.diff applies to" \
  "guard (d) names the unexpected FAIL line"

run_guard "$OFFSET_FAIL
$TRAILER" 1
assert_contains "$GUARD_OUT" "only the xfail-listed offset drift remains" \
  "the known-drift pass is reported as such"

run_guard "$OFFSET_FAIL
FAIL: new: /w/patch_cs8409.h.diff applied with offset to /t/new-tree -- the hook is drifting
$TRAILER" 1
assert_ne 0 "$GUARD_RC" "offset drift on the new tree is not known drift"

run_guard "$OFFSET_FAIL
$HUNK_FAIL
hooks applied: 4 of 5 in play (root *.diff: 6)
FAIL: 2 assertion(s) failed" 1
assert_ne 0 "$GUARD_RC" "fewer than 5 of 5 hooks applied fails guard (d)"

run_guard "" 1
assert_ne 0 "$GUARD_RC" "empty output with a failing exit status fails guard (d)"

run_guard "" 0
assert_eq 0 "$GUARD_RC" "empty output with exit 0 passes guard (d), as the exit status alone decides"

finish
