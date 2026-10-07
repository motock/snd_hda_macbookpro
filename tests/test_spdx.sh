#!/usr/bin/env bash
#
# tests/test_spdx.sh -- SPDX licence lines on patch_cirrus/*.h (batch 1).
#
# Requirements checked, one assertion group each:
#   R1 every patch_cirrus/*.h that is NOT in KNOWN_MISSING carries, as its
#      FIRST line, a C comment of exactly the shape
#          /* SPDX-License-Identifier: <expression> */
#   R2 <expression> is the licence derived from the file's origin: the SPDX
#      line of the kernel file it was copied from, or the project's declared
#      licence (repo LICENSE is GPLv2).  Any other expression is an invented
#      licence and is rejected.  Accepted: GPL-2.0, GPL-2.0-or-later.
#   R3 exactly one SPDX line per file, and it is on line 1.
#   R4 a header listed in KNOWN_MISSING must NOT carry an SPDX line yet; an
#      entry whose file already has one is stale and must be deleted from
#      the array by the story that adds the line.
#   R5 the insertion is comment-only: the preprocessed text of a header is
#      identical with and without its first line (cc -E; the whole R5 group
#      is skipped when no C preprocessor is installed).
#
# The fixtures below are the negative controls: they prove each check detects
# bad input instead of passing vacuously.

. "$(dirname "$0")/lib/assert.sh"
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1

# Headers whose SPDX story has not landed yet (batches 2 and 3).  The story
# that adds the SPDX line to one of these files must also remove it from this
# array, otherwise R4 reports it as stale.
KNOWN_MISSING=(
  patch_cirrus/patch_cirrus_hda_generic_copy.h
  patch_cirrus/patch_cirrus_new84.h
  patch_cirrus/patch_cirrus_real84.h
  patch_cirrus/patch_cirrus_real84_i2c.h
)

# ---------------------------------------------------------------------------
# checker
# ---------------------------------------------------------------------------

is_known_missing() {
  _p=$1
  shift
  for _km in "$@"; do
    [ "$_km" = "$_p" ] && return 0
  done
  return 1
}

# line1_expression <file> -- print the licence expression when line 1 is
# exactly `/* SPDX-License-Identifier: X */` (whitespace-tolerant); otherwise
# print nothing and fail.
line1_expression() {
  _sq=$(sed -n '1p' "$1" | tr -s ' \t' ' ' | sed -e 's/^ //' -e 's/ $//')
  case "$_sq" in
    "/* SPDX-License-Identifier:"*" */") ;;
    *) return 1 ;;
  esac
  _e=${_sq#"/* SPDX-License-Identifier:"}
  _e=${_e%" */"}
  printf '%s' "$_e" | sed -e 's/^ //' -e 's/ $//'
}

# spdx_tags <file> [known-missing...] -- print one violation tag per line:
#   missing         no SPDX line anywhere in the file
#   not-line-1      line 1 is not a `/* SPDX-License-Identifier: X */` comment
#   bad-expression  line 1 has the right shape but X is not an accepted licence
#   duplicate       more than one SPDX line in the file
#   stale           a known-missing file that already carries an SPDX line
spdx_tags() {
  _f=$1
  shift
  if is_known_missing "$_f" "$@"; then
    grep -q 'SPDX-License-Identifier' "$_f" 2>/dev/null && printf 'stale\n'
  elif ! grep -q 'SPDX-License-Identifier' "$_f" 2>/dev/null; then
    printf 'missing\n'
  else
    if [ "$(grep -c 'SPDX-License-Identifier' "$_f" 2>/dev/null)" -gt 1 ]; then
      printf 'duplicate\n'
    fi
    if _e=$(line1_expression "$_f"); then
      case "$_e" in
        GPL-2.0|GPL-2.0-or-later) ;;
        *) printf 'bad-expression\n' ;;
      esac
    else
      printf 'not-line-1\n'
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# R1-R4 against the real headers
# ---------------------------------------------------------------------------

for _km in "${KNOWN_MISSING[@]}"; do
  assert_file_exists "$_km" "KNOWN_MISSING entry must name an existing header"
done

for _h in patch_cirrus/*.h; do
  _tags=$(spdx_tags "$_h" "${KNOWN_MISSING[@]}")
  if [ -n "$_tags" ]; then
    assert_eq "" "$_tags" "$_h: SPDX licence line violations"
  fi
done

# ---------------------------------------------------------------------------
# negative fixtures -- the same checker must flag each known-bad input
# ---------------------------------------------------------------------------

FIXROOT=$(make_tmpdir)
FIXDIR=$FIXROOT/fixture/patch_cirrus
mkdir -p "$FIXDIR"
fix() { printf '%b' "$2" > "$FIXDIR/$1"; }

fix good_or_later.h '/* SPDX-License-Identifier: GPL-2.0-or-later */\nstruct good_a { int x; };\n'
fix good_gpl2.h     '/* SPDX-License-Identifier: GPL-2.0 */\nstruct good_b { int x; };\n'
fix no_spdx.h       'struct no_spdx { int x; };\n'
fix empty.h         ''
fix blank_first.h   '\n/* SPDX-License-Identifier: GPL-2.0 */\nstruct blank { int x; };\n'
fix bad_expr.h      '/* SPDX-License-Identifier: MIT */\nstruct bad { int x; };\n'
fix dup_spdx.h      '/* SPDX-License-Identifier: GPL-2.0 */\nstruct dup { int x; };\n/* SPDX-License-Identifier: GPL-2.0 */\n'
fix km_stale.h      '/* SPDX-License-Identifier: GPL-2.0 */\nstruct stale { int x; };\n'
fix km_clean.h      'struct clean { int x; };\n'

FIX_KM="$FIXDIR/km_clean.h $FIXDIR/km_stale.h"

expect_tags() {
  _name=$1
  _want=$2
  _got=$(spdx_tags "$FIXDIR/$_name" $FIX_KM | sort | tr '\n' ' ')
  _got=${_got% }
  assert_eq "$_want" "$_got" "fixture $_name: expected SPDX violations"
}

expect_tags good_or_later.h ''
expect_tags good_gpl2.h     ''
expect_tags no_spdx.h       'missing'
expect_tags empty.h         'missing'
expect_tags blank_first.h   'not-line-1'
expect_tags bad_expr.h      'bad-expression'
expect_tags dup_spdx.h      'duplicate'
expect_tags km_stale.h      'stale'
expect_tags km_clean.h      ''

# ---------------------------------------------------------------------------
# R5 -- comment-only: dropping line 1 must not change the preprocessed text
# ---------------------------------------------------------------------------

HDA_PP=''
for _c in cc gcc clang; do
  if command -v "$_c" >/dev/null 2>&1; then HDA_PP=$_c; break; fi
done

if [ -z "$HDA_PP" ]; then
  printf 'SKIP: no C preprocessor (cc/gcc/clang) found; R5 not run\n' >&2
else
  # Empty stubs for every <...>/"..." include used by the headers, so that
  # preprocessing succeeds without a kernel source tree.
  STUBS=$(make_tmpdir)/stubs
  mkdir -p "$STUBS"
  for _inc in $(grep -h -o '#include[[:space:]]*[<"][^<">]*[>"]' patch_cirrus/*.h \
                  | sed -e 's/^#include[[:space:]]*//' -e 's/^[<"]//' -e 's/[>"]$//' \
                  | sort -u); do
    mkdir -p "$STUBS/$(dirname "$_inc")"
    : > "$STUBS/$_inc"
  done

  # pp_to <outfile> <infile> -- normalised preprocessed text; fails if the
  # preprocessor fails.
  pp_to() {
    "$HDA_PP" -E -P -x c -I patch_cirrus -I "$STUBS" "$2" > "$1" 2>/dev/null || return 1
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
  for _h in patch_cirrus/*.h; do
    line1_expression "$_h" >/dev/null || continue
    first_line_invisible "$_h"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
      _verified=$((_verified + 1))
    elif [ "$_rc" -eq 1 ]; then
      assert_eq "unchanged" "changed" "$_h: removing line 1 changes the preprocessed text, so the SPDX line is not comment-only"
    fi
  done
  if [ "$_verified" -eq 0 ]; then
    assert_eq "at least one" "none" "R5: no header could be compared with cc -E"
  fi
fi

finish