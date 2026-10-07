#!/usr/bin/env bash
#
# tests/test_spdx_batch2.sh -- SPDX licence lines on the batch-2 cirrus headers.
#
# Story: add /* SPDX-License-Identifier: <expression> */ as the FIRST line of
#   patch_cirrus/patch_cirrus_hda_generic_copy.h
#   patch_cirrus/patch_cirrus_new84.h            (the large header, 2000+ lines)
# and remove both from KNOWN_MISSING in tests/test_spdx.sh.
#
# Requirements checked, one assertion group each:
#   B1 both deliverable headers exist.
#   B2 line 1 of each deliverable is exactly a C comment of the shape
#      /* SPDX-License-Identifier: <expression> */ with <expression> an
#      accepted licence (same licence rules as batch 1: GPL-2.0 or
#      GPL-2.0-or-later; anything else is an invented licence and rejected).
#   B3 exactly one SPDX line per deliverable, and it is on line 1.
#   B4 neither deliverable is listed in the KNOWN_MISSING array of
#      tests/test_spdx.sh any more: the story that adds the line must delete
#      the entry, otherwise batch 1's R4 reports it as stale.
#   B5 the insertion is comment-only: the preprocessed text of a header is
#      identical with and without its first line (cc -E; the whole B5 group
#      is skipped when no C preprocessor is installed).
#   B6 the edit is still just line 1, even for the large header: relative to
#      the pre-story tree, each deliverable gains exactly one line and loses
#      or modifies none.
#
# The fixtures below are the negative controls: they prove each check detects
# bad input instead of passing vacuously.

. "$(dirname "$0")/lib/assert.sh"
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1

DELIVERABLES=(
  patch_cirrus/patch_cirrus_hda_generic_copy.h
  patch_cirrus/patch_cirrus_new84.h
)

# ---------------------------------------------------------------------------
# checker (same shape rules as batch 1's tests/test_spdx.sh)
# ---------------------------------------------------------------------------

# line1_expr <file> -- print the licence expression when line 1 is exactly
# `/* SPDX-License-Identifier: X */` (whitespace-tolerant); otherwise fail.
line1_expr() {
  _sq=$(sed -n '1p' "$1" | tr -s ' \t' ' ' | sed -e 's/^ //' -e 's/ $//')
  case "$_sq" in
    "/* SPDX-License-Identifier:"*" */") ;;
    *) return 1 ;;
  esac
  _e=${_sq#"/* SPDX-License-Identifier:"}
  _e=${_e%" */"}
  printf '%s' "$_e" | sed -e 's/^ //' -e 's/ $//'
}

# tags <file> [known-missing...] -- print one violation tag per line:
#   missing         no SPDX line anywhere in the file
#   not-line-1      line 1 is not a `/* SPDX-License-Identifier: X */` comment
#   bad-expression  line 1 has the right shape but X is not an accepted licence
#   duplicate       more than one SPDX line in the file
#   stale           a known-missing file that already carries an SPDX line
tags() {
  _f=$1
  shift
  for _km in "$@"; do
    if [ "$_km" = "$_f" ]; then
      grep -q 'SPDX-License-Identifier' "$_f" 2>/dev/null && printf 'stale\n'
      return 0
    fi
  done
  if ! grep -q 'SPDX-License-Identifier' "$_f" 2>/dev/null; then
    printf 'missing\n'
    return 0
  fi
  if [ "$(grep -c 'SPDX-License-Identifier' "$_f" 2>/dev/null)" -gt 1 ]; then
    printf 'duplicate\n'
  fi
  if _e=$(line1_expr "$_f"); then
    case "$_e" in
      GPL-2.0|GPL-2.0-or-later) ;;
      *) printf 'bad-expression\n' ;;
    esac
  else
    printf 'not-line-1\n'
  fi
  return 0
}

# km_region <test_spdx.sh> -- print the KNOWN_MISSING array of a test_spdx.sh
# (from the `KNOWN_MISSING=(` line through the first line containing `)`).
km_region() {
  awk '/^KNOWN_MISSING=\(/{f=1} f{print} f&&/\)/{exit}' "$1"
}

# ---------------------------------------------------------------------------
# B1-B3 against the real deliverables.  No KNOWN_MISSING exemption is passed:
# these two files are this story's deliverables and must carry the line
# outright, so that listing them in KNOWN_MISSING cannot make them pass.
# ---------------------------------------------------------------------------

for _h in "${DELIVERABLES[@]}"; do
  assert_file_exists "$_h" "B1: deliverable header must exist"
  _tags=$(tags "$_h")
  if [ -n "$_tags" ]; then
    assert_eq "" "$_tags" "$_h: B2/B3: SPDX licence line violations"
  fi
done

# ---------------------------------------------------------------------------
# B4 -- both names must be gone from KNOWN_MISSING in tests/test_spdx.sh
# ---------------------------------------------------------------------------

assert_file_exists tests/test_spdx.sh "B4: tests/test_spdx.sh must exist"
_km=$(km_region tests/test_spdx.sh)
for _h in "${DELIVERABLES[@]}"; do
  assert_not_contains "$_km" "$_h" "B4: $_h must be removed from KNOWN_MISSING in tests/test_spdx.sh"
done

# ---------------------------------------------------------------------------
# negative fixtures -- the same checkers must flag each known-bad input
# ---------------------------------------------------------------------------

FIXROOT=$(make_tmpdir)
FIXDIR=$FIXROOT/fixture
mkdir -p "$FIXDIR"
fix() { printf '%b' "$2" > "$FIXDIR/$1"; }

fix good.h        '/* SPDX-License-Identifier: GPL-2.0-or-later */\nstruct good { int x; };\n'
fix good_gpl2.h   '/* SPDX-License-Identifier: GPL-2.0 */\nstruct good2 { int x; };\n'
fix no_spdx.h     'struct no_spdx { int x; };\n'
fix empty.h       ''
fix second_line.h 'struct second { int x; };\n/* SPDX-License-Identifier: GPL-2.0 */\n'
fix bad_expr.h    '/* SPDX-License-Identifier: MIT */\nstruct bad { int x; };\n'
fix dup_spdx.h    '/* SPDX-License-Identifier: GPL-2.0 */\nstruct dup { int x; };\n/* SPDX-License-Identifier: GPL-2.0 */\n'
fix km_stale.h    '/* SPDX-License-Identifier: GPL-2.0 */\nstruct stale { int x; };\n'
fix km_clean.h    'struct clean { int x; };\n'

FIX_KM="$FIXDIR/km_clean.h $FIXDIR/km_stale.h"

expect_tags() {
  _name=$1
  _want=$2
  _got=$(tags "$FIXDIR/$_name" $FIX_KM | sort | tr '\n' ' ')
  _got=${_got% }
  assert_eq "$_want" "$_got" "fixture $_name: expected SPDX violations"
}

expect_tags good.h        ''
expect_tags good_gpl2.h   ''
expect_tags no_spdx.h     'missing'
expect_tags empty.h       'missing'
expect_tags second_line.h 'not-line-1'
expect_tags bad_expr.h    'bad-expression'
expect_tags dup_spdx.h    'duplicate'
expect_tags km_stale.h    'stale'
expect_tags km_clean.h    ''

# B4's extraction must detect a listed entry, otherwise the absence check
# above could pass vacuously.
fix test_spdx.sh 'KNOWN_MISSING=(\n  patch_cirrus/patch_cirrus_hda_generic_copy.h\n)\n'
assert_contains "$(km_region "$FIXDIR/test_spdx.sh")" \
  "patch_cirrus/patch_cirrus_hda_generic_copy.h" \
  "fixture: km_region must find an entry that is listed in KNOWN_MISSING"

# ---------------------------------------------------------------------------
# B5 -- comment-only: dropping line 1 must not change the preprocessed text
# ---------------------------------------------------------------------------

HDA_PP=''
for _c in cc gcc clang; do
  if command -v "$_c" >/dev/null 2>&1; then HDA_PP=$_c; break; fi
done

if [ -z "$HDA_PP" ]; then
  printf 'SKIP: no C preprocessor (cc/gcc/clang) found; B5 not run\n' >&2
else
  # Empty stubs for every <...>/"..." include used by the headers, so that
  # preprocessing succeeds without a kernel source tree.  The forced include
  # supplies the LINUX_VERSION_CODE / KERNEL_VERSION macros that some headers
  # use without including linux/version.h themselves.
  STUBS=$(make_tmpdir)/stubs
  mkdir -p "$STUBS"
  for _inc in $(grep -h -o '#include[[:space:]]*[<"][^<">]*[>"]' patch_cirrus/*.h \
                | sed -e 's/^#include[[:space:]]*//' -e 's/^[<"]//' -e 's/[>"]$//' \
                | sort -u); do
    mkdir -p "$STUBS/$(dirname "$_inc")"
    : > "$STUBS/$_inc"
  done
  printf '#define LINUX_VERSION_CODE 332032\n' > "$STUBS/force.h"
  printf '#define KERNEL_VERSION(a,b,c) (((a) << 16) + ((b) << 8) + (c))\n' >> "$STUBS/force.h"

  # pp_to <outfile> <infile> -- normalised preprocessed text; fails if the
  # preprocessor fails.
  pp_to() {
    "$HDA_PP" -E -P -x c -I patch_cirrus -I "$STUBS" -include "$STUBS/force.h" \
      "$2" > "$1" 2>/dev/null || return 1
    sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$1" > "$1.n"
    mv "$1.n" "$1"
  }

  # first_line_invisible <file> -- 0 when the preprocessed text is the same
  # with and without line 1, 1 when it differs, 77 when it cannot be checked.
  first_line_invisible() {
    _f=$1
    _d=$(make_tmpdir)
    if ! pp_to "$_d/with" "$_f"; then
      printf 'SKIP: cannot preprocess %s\n' "$_f" >&2
      return 77
    fi
    sed '1d' "$_f" > "$_d/without"
    pp_to "$_d/without_pp" "$_d/without" || return 77
    cmp -s "$_d/with" "$_d/without_pp"
  }

  # Negative controls for the comparison itself: a comment first line must be
  # invisible, a code first line must be detected.
  CCFIX=$FIXROOT/cc
  mkdir -p "$CCFIX"
  printf '/* SPDX-License-Identifier: GPL-2.0 */\nint cc_comment_first;\n' > "$CCFIX/comment_first.h"
  printf 'int cc_code_first;\nint cc_code_second;\n' > "$CCFIX/code_first.h"
  assert_exit_code 0 first_line_invisible "$CCFIX/comment_first.h"
  assert_exit_code 1 first_line_invisible "$CCFIX/code_first.h"

  _verified=0
  for _h in "${DELIVERABLES[@]}"; do
    line1_expr "$_h" >/dev/null || continue
    first_line_invisible "$_h"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      _verified=$((_verified + 1))
    elif [ "$_rc" -eq 1 ]; then
      assert_eq "unchanged" "changed" "$_h: B5: removing line 1 changes the preprocessed text, so the SPDX line is not comment-only"
    fi
  done
  assert_eq "${#DELIVERABLES[@]}" "$_verified" "B5: every deliverable must be comparable with $HDA_PP -E"
fi

# ---------------------------------------------------------------------------
# B6 -- the edit is still just line 1, even for the large header: relative to
# the pre-story tree (the commit that introduced this test file), each
# deliverable gains exactly one line and loses or modifies none.
# ---------------------------------------------------------------------------

BASE=$(git log --format=%H -1 -- tests/test_spdx_batch2.sh)
if [ -z "$BASE" ]; then
  assert_eq "found" "not found" "B6: cannot locate the pre-story base commit (tests/test_spdx_batch2.sh must be committed)"
else
  for _h in "${DELIVERABLES[@]}"; do
    _d=$(git diff "$BASE" -- "$_h")
    _adds=$(printf '%s\n' "$_d" | grep -c '^+[^+]')
    _dels=$(printf '%s\n' "$_d" | grep -c '^-[^-]')
    assert_eq "1" "$_adds" "$_h: B6: the story edit must add exactly one line"
    assert_eq "0" "$_dels" "$_h: B6: the story edit must not remove or modify any line"
    _added=$(printf '%s\n' "$_d" | grep '^+[^+]' | sed 's/^+//')
    assert_contains "$_added" "SPDX-License-Identifier" "$_h: B6: the single added line must be the SPDX comment"
  done
fi

finish
