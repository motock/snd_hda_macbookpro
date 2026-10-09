#!/usr/bin/env bash
#
# tests/test_driver_switch_break.sh
#
# HDA-34 (N20): static guards on patch_cirrus/cirrus_apple.h.
#
#  1. In cs8409_cs42l83_macbook_exec_verb()'s `switch (nid)`, every case block
#     must end in break/return/goto, or carry a "fall through" comment.  The
#     HP_MIC case used to fall into the LINEIN case (compilers flag this with
#     -Wimplicit-fallthrough; this test needs no kernel build, but a real
#     check of the compiler warning does).
#  2. In cs8409_cs42l83_exec_verb(), `nid == spec->linein_nid` must not be the
#     only discriminator: the hook is installed before linein_nid is assigned,
#     and the zeroed spec makes linein_nid == 0 match nid 0 until then.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/lib/assert.sh"

SRC="$REPO_ROOT/patch_cirrus/cirrus_apple.h"
assert_file_exists "$SRC" "patch_cirrus/cirrus_apple.h exists"

# fn_body SIG -- print the function from its signature to the first `}` at column 0.
fn_body() {
  awk -v sig="$1" '
    !in_fn && index($0, sig) { in_fn = 1 }
    in_fn { print }
    in_fn && /^}/ { exit }
  ' "$SRC"
}

# unterminated_cases -- read a function body on stdin and print each `case`
# label inside `switch (nid)` whose block neither ends in break/return/goto
# nor carries a "fall through" comment.  The last statement of a block is
# the last non-blank line before the next label / closing brace of the
# switch; a `}` closing an `if` does not terminate the block.
unterminated_cases() {
  awk '
    /switch \(nid\)/ { in_sw = 1; next }
    !in_sw { next }
    /^[ \t]*(case .*|default):/ {
      if (label != "" && !ok) print label
      label = $0; ok = 0; next
    }
    /^        }[ \t]*$/ { if (label != "" && !ok) print label; label = ""; in_sw = 0; next }
    # only a terminator at case-body nesting level (16 spaces) counts
    /^                (break|return|goto)[ \t;]/ { ok = 1 }
    /[Ff]all[ -]?through/ { ok = 1 }
  '
}

MACBOOK=$(fn_body 'static int cs8409_cs42l83_macbook_exec_verb(')
assert_ne "" "$MACBOOK" "cs8409_cs42l83_macbook_exec_verb() is found"

BAD=$(printf '%s\n' "$MACBOOK" | unterminated_cases)
assert_eq "" "$BAD" "every case block in the macbook switch ends in break/return/goto"

# positive control: the checker flags a block that falls through
SAMPLE='        switch (nid) {
        case A:
                if (x) {
                        return 0;
                }
        case B:
                break;
        }'
assert_eq "        case A:" "$(printf '%s\n' "$SAMPLE" | unterminated_cases)" \
  "the checker flags a case that falls through"

LIVE=$(fn_body 'static int cs8409_cs42l83_exec_verb(')
assert_ne "" "$LIVE" "cs8409_cs42l83_exec_verb() is found"

assert_contains "$LIVE" 'nid == spec->linein_nid' \
  "the linein_nid comparison is still present"
LINEIN_LINE=$(printf '%s\n' "$LIVE" | grep 'nid == spec->linein_nid')
assert_contains "$LINEIN_LINE" 'spec->linein_nid != 0' \
  "the linein_nid comparison is guarded against the unset (0) value"

finish
