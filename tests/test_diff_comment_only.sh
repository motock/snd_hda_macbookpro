#!/usr/bin/env bash
#
# tests/test_diff_comment_only.sh -- comment-only changes to patched headers.
#
# Provides assert_comment_only_change <old> <new>: strips all C comments from
# two files with the C preprocessor and asserts the remainder is byte-identical,
# which proves no code token changed.  Source this file to reuse the function;
# the checks below only run when it is executed directly.
#
# Checks (HDA-32, patch_cs8409.h.diff):
#   R1 comment edits are detected as comment-only; a code edit is not
#   R2 in the patched cs8409.h, every `// nid 0xNN` / `// reg 0xNN` comment
#      equals the member's position in its enum (both enums start at 0 with no
#      initialiser in the kernel header), so no two members share a value
#   R3 rewriting those comments leaves the patched header's code untouched
#
# Checks (HDA-33, patch_patch_cs8409.h.diff, pinned < 6.17 tree):
#   R4 the hook applies in installer order and its nid/reg comments equal the
#      member's position in the enum
#   R5 no enum member carries two comments
#
# Skips (77) when there is no host cc, or the pinned tarball is not cached
# (R2/R3 need the >= 6.17 one, R4-R5 the < 6.17 one; R1 always runs).

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$TEST_DIR/lib/assert.sh"
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)

# _strip_awk -- portable comment stripper for hosts whose cc lacks
# -fpreprocessed (Apple clang).  Understands "strings", 'chars' and escapes,
# so a "//" inside a literal is kept.  A comment becomes one space, as in cpp.
_strip_awk() {
  awk '
    BEGIN { RS = "\001"; ORS = "" }
    {
      n = length($0); out = ""; i = 1
      while (i <= n) {
        c = substr($0, i, 1); d = substr($0, i, 2)
        if (d == "//") { while (i <= n && substr($0, i, 1) != "\n") i++; out = out " "; continue }
        if (d == "/*") { i += 2; while (i <= n && substr($0, i, 2) != "*/") i++; i += 2; out = out " "; continue }
        if (c == "\"" || c == "\047") {
          q = c; out = out c; i++
          while (i <= n && substr($0, i, 1) != q) {
            if (substr($0, i, 1) == "\\") { out = out substr($0, i, 1); i++ }
            out = out substr($0, i, 1); i++
          }
          out = out q; i++; continue
        }
        out = out c; i++
      }
      printf "%s", out
    }' "$1"
}

# strip_comments <file> -- the file with comments removed, normalised for
# blank lines and trailing space so only code tokens are compared.  Uses
# `cc -fpreprocessed -dD -E -P` (no macro or include expansion, #defines kept)
# when the compiler supports it, else _strip_awk.
strip_comments() {
  if cc -x c -fpreprocessed -E -P /dev/null >/dev/null 2>&1; then
    cc -x c -fpreprocessed -dD -E -P "$1" 2>/dev/null
  else
    _strip_awk "$1"
  fi | sed -E -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//' | grep -v '^$'
}

# assert_comment_only_change <old> <new> [msg]
assert_comment_only_change() {
  local old=$1 new=$2 msg=${3:-"only comments differ between $1 and $2"} a b
  a=$(strip_comments "$old") || { _hda_fail "$msg (cannot strip $old)"; return 1; }
  b=$(strip_comments "$new") || { _hda_fail "$msg (cannot strip $new)"; return 1; }
  if [ -z "$a" ]; then
    _hda_fail "$msg (stripped $old is empty; the check would be vacuous)"
    return 1
  fi
  assert_eq "$a" "$b" "$msg"
}

# comment_only_changed <old> <new> -- 0 when only comments differ (no assert).
comment_only_changed() {
  [ "$(strip_comments "$1")" = "$(strip_comments "$2")" ]
}

# enum_comment_mismatches <header> <enum-name> <nid|reg> -- print each member
# whose `// <kind> 0xNN` comment differs from its position in the enum.
enum_comment_mismatches() {
  awk -v name="$2" -v kind="$3" '
    $0 ~ "^enum " name " \\{" { on = 1; i = 0; next }
    on && /^\};/ { on = 0 }
    on && /^\t[A-Za-z0-9_]+,?[ \t]*(\/\/|\/\*|$)/ {
      want = sprintf("// %s 0x%02x", kind, i)
      if (index($0, want) == 0 || match($0, "// " kind " 0x[0-9a-f]+") == 0 ||
          substr($0, RSTART, RLENGTH) != want) print $1, "expected", want
      i++
    }' "$1"
}

# enum_multi_comment_members <header> <enum-name> -- print each member line
# that carries more than one comment (// or /* */).
enum_multi_comment_members() {
  awk -v name="$2" '
    $0 ~ "^enum " name " \\{" { on = 1; next }
    on && /^\};/ { on = 0 }
    on && /^\t[A-Za-z0-9_]+/ {
      n = gsub(/\/\/|\/\*/, "&")
      if (n > 1) print $1
    }' "$1"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

command -v cc >/dev/null 2>&1 || skip "no host cc"
WORK=$(make_tmpdir)

# --- R1: detector, with its negative control --------------------------------
printf 'enum e {\n\tA,\t// nid 0x05\n\tB,\t/* x */\n};\n' > "$WORK/old.h"
printf 'enum e {\n\tA,                // nid 0x00\n\tB,\t// nid 0x01\n};\n' > "$WORK/comments.h"
printf 'enum e {\n\tA,\t// nid 0x05\n\tC,\t/* x */\n};\n' > "$WORK/code.h"
assert_comment_only_change "$WORK/old.h" "$WORK/comments.h" "R1 comment edits are accepted"
if comment_only_changed "$WORK/old.h" "$WORK/code.h"; then
  _hda_fail "R1 an injected code change (B -> C) was not detected"
fi

# --- R2/R3: the real patched header -----------------------------------------
. "$TEST_DIR/kernel-pins.conf" || { _hda_fail "cannot read kernel-pins.conf"; finish; }
cache=${HDA_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-tests}
tarball="$cache/tarballs/$PIN_NEW_TARBALL"
have_new=1
[ -f "$tarball" ] || have_new=0

if [ "$have_new" = 1 ]; then
  hda="$WORK/hda"
  mkdir -p "$hda/codecs/cirrus"
  tar -xf "$tarball" -C "$WORK" --strip-components=5 \
    "linux-$PIN_NEW_VERSION/sound/hda/codecs/cirrus/cs8409.h" ||
    { _hda_fail "cannot extract cs8409.h from $PIN_NEW_TARBALL"; finish; }
  mv "$WORK/cs8409.h" "$hda/codecs/cirrus/cs8409.h"
  patch --batch --no-backup-if-mismatch -p1 -d "$hda" < "$REPO_ROOT/patch_cs8409.h.diff" >/dev/null 2>&1
  assert_eq 0 "$?" "R2 patch_cs8409.h.diff applies to the pinned $PIN_NEW_VERSION tree"
  patched="$hda/codecs/cirrus/cs8409.h"

  assert_eq "" "$(enum_comment_mismatches "$patched" cs8409_pins nid)" \
    "R2 every cs8409_pins '// nid' comment equals the member's position"
  assert_eq "" "$(enum_comment_mismatches "$patched" cs8409_coefficient_index_registers reg)" \
    "R2 every coefficient '// reg' comment equals the member's position"

  # the checker itself must flag a duplicated comment
  sed 's|// nid 0x03|// nid 0x02|' "$patched" > "$WORK/dup.h"
  assert_contains "$(enum_comment_mismatches "$WORK/dup.h" cs8409_pins nid)" "expected" \
    "R2 control: a duplicated nid comment is reported"

  sed -e 's|// nid 0x[0-9a-f]*|// nid 0xff|' -e 's|// reg 0x[0-9a-f]*|// reg 0xff|' "$patched" > "$WORK/garbled.h"
  assert_comment_only_change "$WORK/garbled.h" "$patched" \
    "R3 the nid/reg comments are the only difference from a garbled copy"
fi

# --- R4-R6: the pre-6.17 hook, applied in installer order ---------------------
old_tarball="$cache/tarballs/$PIN_OLD_TARBALL"
if [ -f "$old_tarball" ]; then
  old="$WORK/old-tree"
  mkdir -p "$old"
  tar -xf "$old_tarball" -C "$old" --strip-components=3 "linux-$PIN_OLD_VERSION/sound/pci/hda"
  # installer: copy patch_cirrus/Makefile and patch_cirrus_* into the tree, then
  # patch_patch_cs8409.c.diff, then patch_patch_cs8409.h.diff (all -p2)
  cp "$REPO_ROOT/patch_cirrus/Makefile" "$REPO_ROOT"/patch_cirrus/patch_cirrus_* "$old/hda"
  patch --batch --no-backup-if-mismatch -p2 -d "$old/hda" < "$REPO_ROOT/patch_patch_cs8409.c.diff" >/dev/null 2>&1
  patch --batch --no-backup-if-mismatch -p2 -d "$old/hda" < "$REPO_ROOT/patch_patch_cs8409.h.diff" >/dev/null 2>&1
  assert_eq 0 "$?" "R4 patch_patch_cs8409.h.diff applies to the pinned $PIN_OLD_VERSION tree"
  oldpatched="$old/hda/patch_cs8409.h"

  assert_eq "" "$(enum_comment_mismatches "$oldpatched" cs8409_pins nid)" \
    "R4 every cs8409_pins '// nid' comment equals the member's position"
  assert_eq "" "$(enum_comment_mismatches "$oldpatched" cs8409_coefficient_index_registers reg)" \
    "R4 every coefficient '// reg' comment equals the member's position"
  assert_eq "" "$(enum_multi_comment_members "$oldpatched" cs8409_coefficient_index_registers)" \
    "R5 no coefficient member carries two comments"
  # control: the checker flags a member with two comments
  sed 's|// reg 0x63|// reg 0x63 /* extra */|' "$oldpatched" > "$WORK/two.h"
  assert_contains "$(enum_multi_comment_members "$WORK/two.h" cs8409_coefficient_index_registers)" "CS8409_PFE_COEF_W1" \
    "R5 control: a member with two comments is reported"
else
  echo "note: pinned $PIN_OLD_VERSION tarball not cached; R4-R5 skipped"
fi

finish
