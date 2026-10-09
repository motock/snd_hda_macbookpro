#!/usr/bin/env bash
#
# tests/test_driver_coef_mask.sh
#
# HDA-21: pin the behaviour of cs_8409_vendor_coef_set_mask().
#
# The helper (patch_cirrus/patch_cirrus_new84.h) computes
#
#     mask_coef = (retval & ~mask) | coef;
#
# i.e. coef is OR-ed in WITHOUT being masked.  The textbook form would be
# `| (coef & mask)`, but six live calls in patch_cirrus_real84.h pass coef
# bits outside mask (three with mask 0x0000, where the OR is the only thing
# that writes the value).  Changing the expression would silently change
# codec register writes that cannot be verified without an Apple CS8409, so
# the expression is intentionally left as is and this test pins it.
#
# Three checks:
#
#   1. static: the helper contains `(retval & ~mask) | coef` and does not
#      contain `(coef & mask)`;
#   2. semantic: the expression extracted from the source, compiled with the
#      host cc, yields the expected results for a table of inputs (skipped
#      when there is no host cc);
#   3. the explanatory comment above the helper is present.
#
# If you are here because check 1 or 2 failed: read the comment above the
# helper in patch_cirrus_new84.h, and validate any change on an iMac first.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/lib/assert.sh"

SRC="$REPO_ROOT/patch_cirrus/patch_cirrus_new84.h"

FN_SIG='cs_8409_vendor_coef_set_mask(struct hda_codec *codec'
EXPECTED_EXPR='(retval & ~mask) | coef'
FORBIDDEN_EXPR='(coef & mask)'
COMMENT_PHRASE='OR-ed in WITHOUT being masked'
WHY='see the comment above cs_8409_vendor_coef_set_mask() in patch_cirrus_new84.h; validate any change on an iMac first'

assert_file_exists "$SRC" "the driver header patch_cirrus/patch_cirrus_new84.h exists"

# helper_body -- print the helper from its signature to the first closing
# brace at column 0.
helper_body() {
  awk -v sig="$FN_SIG" '
    !in_fn && index($0, sig) { in_fn = 1 }
    in_fn { print }
    in_fn && /^}/ { exit }
  ' "$SRC"
}

BODY=$(helper_body)
assert_ne "" "$BODY" "the helper cs_8409_vendor_coef_set_mask() is found in new84.h"

# --- 1. static ---------------------------------------------------------------

assert_contains "$BODY" "mask_coef = $EXPECTED_EXPR;" \
  "the helper computes '$EXPECTED_EXPR' ($WHY)"
assert_not_contains "$BODY" "$FORBIDDEN_EXPR" \
  "the helper must not mask coef with '$FORBIDDEN_EXPR' ($WHY)"

# --- 3. comment (before the semantic check, which may skip) --------------------------------------------------------------

assert_contains "$(grep -B12 -F 'cs_8409_vendor_coef_set_mask(struct hda_codec' "$SRC" | head -n 12)" \
  "$COMMENT_PHRASE" "the explanatory comment sits above the helper"

# --- 2. semantic -------------------------------------------------------------

# The expression under test: right-hand side of the mask_coef assignment.
EXPR=$(printf '%s\n' "$BODY" | sed -n 's/^[[:space:]]*mask_coef = \(.*\);[[:space:]]*$/\1/p' | head -n 1)
assert_ne "" "$EXPR" "the mask_coef right-hand side can be extracted from the helper"

# check_expr <retval> <mask> <coef> <expected> <msg>
check_expr() {
  local out
  out=$("$HARNESS" "$1" "$2" "$3")
  assert_eq "$4" "$out" "$5"
}

if command -v cc >/dev/null 2>&1; then
  WORK=$(make_tmpdir)
  cat > "$WORK/harness.c" <<'C'
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	unsigned int retval, mask, coef, mask_coef;

	if (argc != 4)
		return 2;
	retval = (unsigned int)strtoul(argv[1], NULL, 0);
	mask = (unsigned int)strtoul(argv[2], NULL, 0);
	coef = (unsigned int)strtoul(argv[3], NULL, 0);
	mask_coef = EXPR;
	printf("0x%04x\n", mask_coef);
	return 0;
}
C
  HARNESS="$WORK/harness"
  if cc -DEXPR="$EXPR" -o "$HARNESS" "$WORK/harness.c" 2>"$WORK/cc.err"; then
    # 0xFF00 & ~0x00F0 = 0xFF00; | 0x12F5 = 0xFFF5 (coef bits outside mask are kept)
    check_expr 0xFF00 0x00F0 0x12F5 0xfff5 "coef bits outside mask are OR-ed in"
    # 0x0001 & ~0 = 0x0001; | 0x5400 = 0x5401 (mask 0: the OR is the only write)
    check_expr 0x0001 0x0000 0x5400 0x5401 "with mask 0x0000 coef is still OR-ed in"
    # 0xABCD & ~0xFFFF = 0; | 0x1234 = 0x1234
    check_expr 0xABCD 0xFFFF 0x1234 0x1234 "with a full mask the result is coef"
    # 0xABCD & ~0x00FF = 0xAB00; | 0 = 0xAB00
    check_expr 0xABCD 0x00FF 0x0000 0xab00 "with coef 0 the result is retval & ~mask"
  else
    assert_eq "compiled" "failed: $(cat "$WORK/cc.err")" "the extracted expression compiles in the harness"
  fi
else
  printf 'SKIP (semantic check): no host cc\n' >&2
  skip "no host cc"
fi

finish
