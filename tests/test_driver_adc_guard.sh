#!/usr/bin/env bash
#
# tests/test_driver_adc_guard.sh
#
# HDA-23: the ADC shrink loop in patch_cirrus/cirrus_apple.h is a copy of
# hda_generic_check_dyn_adc_switch() from the kernel's sound/hda/codecs/
# generic.c.  Upstream wraps the path invalidation in `if (n != nums) { ... }`
# so that the path being kept is not invalidated before it is reassigned.
#
# The copy had dropped that guard, so it memsets input_paths[i][nums] -- which
# is input_paths[i][n] itself whenever n == nums -- before reassigning it,
# destroying the very path it is about to keep.
#
# Two checks:
#
#   1. static: inside the body of cs_8409_apple_create_input_ctls() in
#      patch_cirrus/cirrus_apple.h, an `if (n != nums)` must appear before the
#      first memset.  The function body is delimited with awk by its start and
#      end lines so that a guard anywhere else in the file cannot satisfy it.
#
#   2. cross-check: the same guard text must exist in the pinned upstream
#      generic.c (tests/kernel-pins.conf, >= 6.17 pin).  This guards against
#      drift on the next kernel pin bump.  When the pinned tree is unavailable
#      this check is skipped with a note; the static check above still runs.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/lib/assert.sh"
# shellcheck source=tests/lib/kernel_cache.sh
. "$SCRIPT_DIR/lib/kernel_cache.sh"

SRC="$REPO_ROOT/patch_cirrus/cirrus_apple.h"

# The function under test.  Matched with index() rather than a regex so that
# the C punctuation needs no escaping and behaves the same under every awk.
# The trailing `;` test rejects the forward declaration.
FN_SIG='static int cs_8409_apple_create_input_ctls(struct hda_codec *codec)'

# scan_fn <file> -- print "<found> <guard-line> <memset-line>".
#
# found is 1 when the definition (not the forward declaration) was seen; the
# line numbers are absolute and 0 when the construct is absent.  The body runs
# from the definition line to the first closing brace at column 0, so a guard
# or memset elsewhere in the file cannot satisfy the check.
scan_fn() {
  awk -v sig="$FN_SIG" '
    !in_fn && index($0, sig) == 1 && $0 !~ /;[[:space:]]*$/ { in_fn = 1; found = 1 }
    in_fn {
      if (!g && index($0, "if (n != nums)")) g = NR
      if (!m && index($0, "memset")) m = NR
    }
    in_fn && /^}/ { exit }
    END { printf "%d %d %d\n", found, g, m }
  ' "$1"
}

assert_file_exists "$SRC" "the driver header patch_cirrus/cirrus_apple.h exists"

read -r FN_FOUND GUARD_LINE MEMSET_LINE <<EOF
$(scan_fn "$SRC")
EOF

assert_eq 1 "$FN_FOUND" \
  "cs_8409_apple_create_input_ctls() is defined in $SRC"
assert_ne 0 "$GUARD_LINE" \
  "cs_8409_apple_create_input_ctls() has an 'if (n != nums)' guard"
assert_ne 0 "$MEMSET_LINE" \
  "cs_8409_apple_create_input_ctls() still invalidates a path with memset"

if [ "$GUARD_LINE" -gt 0 ] && [ "$MEMSET_LINE" -gt 0 ]; then
  if [ "$GUARD_LINE" -lt "$MEMSET_LINE" ]; then
    assert_eq "before" "before" \
      "the 'if (n != nums)' guard precedes the first memset (guard line $GUARD_LINE, memset line $MEMSET_LINE)"
  else
    assert_eq "before" "after" \
      "the 'if (n != nums)' guard must precede the first memset (guard line $GUARD_LINE, memset line $MEMSET_LINE)"
  fi
fi

# ---------------------------------------------------------------------------
# 2. cross-check against the pinned upstream generic.c
# ---------------------------------------------------------------------------

UPSTREAM_RC=0
UPSTREAM_TREE=$(kernel_tree_for new) || UPSTREAM_RC=$?

if [ "$UPSTREAM_RC" -ne 0 ]; then
  # 77 is the documented "tree unavailable, skip" status.  Any other failure
  # means the cache helper itself could not produce the tree; that is not this
  # test's subject, so note it and carry on with the static check's verdict.
  printf 'note: pinned kernel tree unavailable (kernel_tree_for new -> %s); skipping the upstream cross-check\n' \
    "$UPSTREAM_RC" >&2
else
  UPSTREAM_C="$UPSTREAM_TREE/sound/hda/codecs/generic.c"
  assert_file_exists "$UPSTREAM_C" "the pinned upstream generic.c is present"

  if [ -f "$UPSTREAM_C" ]; then
    if grep -q 'if (n != nums)' "$UPSTREAM_C"; then
      assert_eq "present" "present" \
        "the pinned upstream generic.c carries the same 'if (n != nums)' guard"
    else
      assert_eq "present" "absent" \
        "the pinned upstream generic.c has no 'if (n != nums)' guard; the copy has drifted from upstream"
    fi
  fi
fi

finish
