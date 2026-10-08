#!/usr/bin/env bash
#
# test_driver_unsol_lock.sh -- HDA-20: static regression guard for the
# unsolicited-event queue lock in patch_cirrus/patch_cirrus_new84.h.
#
# The queue (spec->unsol_list plus the spec->unsol_items_prealloc_used[]
# bookkeeping) is shared between the unsolicited-event work item (enqueue) and
# the drain paths.  This test is a *structural* guard.  It proves:
#
#   (a) both codec-spec header diffs declare `spinlock_t unsol_lock;`
#   (b) every line in new84.h that touches unsol_list or
#       unsol_items_prealloc_used is lexically inside a spin_lock/spin_unlock
#       pair (the local-list iteration touches only the private `pending` head)
#   (c) no memset()/handler call sits between a lock and its unlock
#   (d) the hook-apply test still passes for both pinned trees
#
# It does NOT prove the absence of races -- only a lockdep/KCSAN kernel run can
# do that.  See tests/README for the manual validation recipe.
#
# Exit status: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT" || exit 2

NEW84="patch_cirrus/patch_cirrus_new84.h"
DIFF_NEW="patch_cs8409.h.diff"
DIFF_OLD="patch_patch_cs8409.h.diff"

fail=0
ok()  { printf 'ok   - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*"; fail=1; }

# ---------------------------------------------------------------------------
# prerequisites
# ---------------------------------------------------------------------------
for f in "$NEW84" "$DIFF_NEW" "$DIFF_OLD"; do
  if [ -f "$f" ]; then
    ok "found $f"
  else
    bad "missing $f"
  fi
done
[ "$fail" -eq 0 ] || exit 1

# ---------------------------------------------------------------------------
# (a) the codec spec declares the lock in both header diffs
# ---------------------------------------------------------------------------
for f in "$DIFF_NEW" "$DIFF_OLD"; do
  if grep -qE '^\+[[:space:]]*spinlock_t[[:space:]]+unsol_lock;' "$f"; then
    ok "$f declares spinlock_t unsol_lock"
  else
    bad "$f does not declare spinlock_t unsol_lock"
  fi
done

# ---------------------------------------------------------------------------
# (b) every queue access is inside a lock pair
# ---------------------------------------------------------------------------
# The awk scan tracks the lock depth.  A line that mentions unsol_list or
# unsol_items_prealloc_used while the depth is 0 is an offending line.
offenders=$(
  awk '
    /spin_lock_irqsave\(&spec->unsol_lock/ { depth++; next }
    /spin_unlock_irqrestore\(&spec->unsol_lock/ { if (depth > 0) depth--; next }
    /unsol_list|unsol_items_prealloc_used/ {
      if (depth == 0) printf "%d: %s\n", NR, $0
    }
  ' "$NEW84"
)
if [ -n "$offenders" ]; then
  bad "unlocked queue access in $NEW84:"
  printf '%s\n' "$offenders"
else
  ok "every unsol_list/unsol_items_prealloc_used access in $NEW84 is inside a lock pair"
fi

# Structural sanity: the lock depth must return to zero and never go negative.
depth_report=$(
  awk '
    /spin_lock_irqsave\(&spec->unsol_lock/ { depth++ }
    /spin_unlock_irqrestore\(&spec->unsol_lock/ {
      depth--
      if (depth < 0) printf "negative lock depth at line %d\n", NR
    }
    END { if (depth != 0) printf "unbalanced lock depth %d at EOF\n", depth }
  ' "$NEW84"
)
if [ -n "$depth_report" ]; then
  bad "unbalanced spin_lock/spin_unlock in $NEW84:"
  printf '%s\n' "$depth_report"
else
  ok "spin_lock/spin_unlock pairs are balanced in $NEW84"
fi

# ---------------------------------------------------------------------------
# (c) no memset()/handler call between a lock and its unlock
# ---------------------------------------------------------------------------
# The drain handlers do codec/I2C I/O and sleep, so they must never run with
# the lock held; the same goes for the per-entry memset, which is deliberately
# done outside the critical section.
between=$(
  awk '
    /spin_lock_irqsave\(&spec->unsol_lock/ { depth++; next }
    /spin_unlock_irqrestore\(&spec->unsol_lock/ { if (depth > 0) depth--; next }
    depth > 0 && (/memset[[:space:]]*\(/ || /cs_8409_cs42l83_unsolicited_response_finalize[[:space:]]*\(/) {
      printf "%d: %s\n", NR, $0
    }
  ' "$NEW84"
)
if [ -n "$between" ]; then
  bad "memset()/handler call between a lock and its unlock in $NEW84:"
  printf '%s\n' "$between"
else
  ok "no memset()/handler call between a lock and its unlock in $NEW84"
fi

# ---------------------------------------------------------------------------
# (d) the hook-apply test still passes for both pinned trees
# ---------------------------------------------------------------------------
if [ -f tests/test_hooks_apply.sh ]; then
  hooks_log=$(mktemp 2>/dev/null || printf '/tmp/hda20_hooks.%s' "$$")
  bash tests/test_hooks_apply.sh >"$hooks_log" 2>&1
  hooks_rc=$?
  if [ "$hooks_rc" -eq 0 ]; then
    ok "tests/test_hooks_apply.sh passes (both pinned trees)"
  elif [ "$hooks_rc" -eq 77 ]; then
    printf 'skip - tests/test_hooks_apply.sh skipped (rc=77)\n'
  else
    bad "tests/test_hooks_apply.sh failed (rc=$hooks_rc); tail:"
    tail -20 "$hooks_log"
  fi
  rm -f "$hooks_log"
else
  bad "missing tests/test_hooks_apply.sh"
fi

if [ "$fail" -eq 0 ]; then
  printf 'PASS test_driver_unsol_lock.sh\n'
  exit 0
fi
printf 'FAIL test_driver_unsol_lock.sh\n'
exit 1
