#!/usr/bin/env bash
#
# tests/test_hooks_apply.sh
#
# Every *.diff hook in the repository root must apply cleanly to the pinned
# kernel trees.  A hook that applies with fuzz or offset, or that leaves a
# .rej/.orig behind, has drifted away from the kernel source it patches and
# will eventually stop applying altogether.
#
# The two sequences below mirror, step for step, what the installers do:
#
#   install.cirrus.driver.sh        (new: >= 6.17)   lines 213-299
#   install.cirrus.driver.pre617.sh (old: <  6.17)   lines 228-303
#
# Only the copy steps and the `patch` invocations are reproduced.  The
# download/extract steps are replaced by tests/lib/kernel_cache.sh, which hands
# out the same pinned trees from a checksum-verified cache.
#
# Deliberate deviation from the installers: they pass `patch -b`, which writes
# a .orig backup of every file it touches.  This test omits -b so that any
# .orig or .rej left in the tree is evidence of a bad apply rather than
# expected noise.  The only .orig files tolerated are the Makefile backups the
# installers themselves create with `mv` (see the ALLOWED_* lists below).
#
# Scope: only the repository-root *.diff hooks are graded.  patches/*.diff is a
# separate directory of Ubuntu/mainline variant hooks selected by the
# installers' iscurrent branches and is deliberately out of scope here.
#
# Exit codes: 0 pass, 1 fail, 77 skip (a pinned tree is unavailable offline).
#
# ---------------------------------------------------------------------------
# TDD NOTE
# ---------------------------------------------------------------------------
# The corrupted-diff negative case in the NEGATIVE CASE section was written
# first, before the positive sequences existed, and was run to confirm it goes
# red.  It is the guard that stops this file from becoming a test that passes
# because it checks nothing.
# ---------------------------------------------------------------------------

set -u

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)

. "$TEST_DIR/lib/assert.sh"
. "$TEST_DIR/lib/kernel_cache.sh"

scratch=$(make_tmpdir)

# ---------------------------------------------------------------------------
# root *.diff files that neither installer sequence applies, with the reason.
# Anything not applied and not listed here is an orphan hook and fails the run.
# ---------------------------------------------------------------------------
KNOWN_UNUSED="patch_patch_cirrus.c.diff"
#   patch_patch_cirrus.c.diff
#       Only used by install.cirrus.driver.pre617.sh:270-271, the
#       `major_version -eq 5 -a minor_version -lt 13` branch.  Both pins are
#       6.x, so neither sequence reaches it.  It is kept for the 5.x kernels
#       the pre-6.17 installer still supports.

# .orig files the installers create themselves, relative to the tree root.
ALLOWED_ORIG_NEW="sound/hda/Makefile.orig sound/hda/common/Makefile.orig sound/hda/codecs/Makefile.orig sound/hda/codecs/cirrus/Makefile.orig"
ALLOWED_ORIG_OLD="sound/pci/hda/Makefile.orig"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# fail <msg> -- record a failure with the assertion library's recorder, so one
# run reports every problem in the file instead of stopping at the first.
fail() {
  _hda_fail "$1"
}

# note <msg> -- progress line on stdout, so a run is self-documenting even when
# it fails (the assertion library only prints failures).
note() {
  printf 'note: %s\n' "$1"
}

# grep_ci <text> <extended-regex> -- 0 when <text> matches, case-insensitively.
grep_ci() {
  printf '%s\n' "$1" | grep -qiE "$2"
}

# file_has <path> <needle> <msg> -- assert the file exists and contains needle.
file_has() {
  local path=$1 needle=$2 msg=$3
  assert_file_exists "$path" "$msg"
  if [ -f "$path" ]; then
    assert_contains "$(cat "$path")" "$needle" "$msg"
  fi
}

# tree_copy <which> <dest> -- obtain the pinned tree in <dest>.
# Returns 0 on success, 77 when the tree is unavailable offline.
#
# The first choice is always kernel_tree_copy from tests/lib/kernel_cache.sh.
# As of this writing that helper cannot produce the `new` tree: it insists on
# extracting sound/pci/hda, which does not exist in 6.17 (the HDA code moved to
# sound/hda in that release), so tar fails and the helper returns a hard error
# 1.  Rather than let that defect hide the new-tree hooks, fall back to the
# installer's own extraction line against the same cached tarball:
#
#   install.cirrus.driver.sh:208
#     tar --strip-components=2 -xvf $build_dir/linux-$kernel_version.tar.xz \
#         --directory=build/ linux-$kernel_version/sound/hda
#   install.cirrus.driver.pre617.sh:224
#     tar --strip-components=3 -xvf $build_dir/linux-$kernel_version.tar.xz \
#         --directory=build/ linux-$kernel_version/sound/pci/hda
#
# The fallback is only reached when the helper fails, so it disappears on its
# own once the helper is fixed.
tree_copy() {
  local which=$1 dest=$2 rc root tarball ver strip member tmp
  kernel_tree_copy "$which" "$dest"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 77 ] && return 77

  # shellcheck disable=SC1090
  . "$TEST_DIR/kernel-pins.conf" || return 1
  case "$which" in
    new) ver=$PIN_NEW_VERSION; tarball=$PIN_NEW_TARBALL; strip=2; member="sound/hda" ;;
    old) ver=$PIN_OLD_VERSION; tarball=$PIN_OLD_TARBALL; strip=3; member="sound/pci/hda" ;;
    *) return 1 ;;
  esac
  root=${HDA_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-tests}
  [ -f "$root/tarballs/$tarball" ] || return 77

  printf 'WARNING: kernel_tree_copy %s failed (exit %s); falling back to the installer tar line\n' \
    "$which" "$rc" >&2
  tmp=$(mktemp -d "$scratch/tree.XXXXXX") || return 1
  if ! tar -xf "$root/tarballs/$tarball" -C "$tmp" --strip-components="$strip" "linux-$ver/$member"; then
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$dest/$(dirname "$member")" || { rm -rf "$tmp"; return 1; }
  mv "$tmp/hda" "$dest/$member" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  return 0
}

# obtain <which> <dest> -- tree_copy, but skip the whole file when the tree is
# simply unavailable offline and fail hard on any other error.
obtain() {
  local which=$1 dest=$2 rc
  tree_copy "$which" "$dest"
  rc=$?
  if [ "$rc" -eq 77 ]; then
    skip "$which kernel tree unavailable offline (not cached and not downloadable)"
  fi
  if [ "$rc" -ne 0 ]; then
    fail "cannot obtain the $which kernel tree (exit $rc)"
    finish
  fi
}

# run_patch <hda_dir> <pflag> <diff> [--dry-run]
#   Run patch the way the installer does: same -p argument, and -d for the
#   directory the installer reaches with `pushd $hda_dir`.  Records PATCH_RC
#   and PATCH_OUT.
#
#   Two deliberate deviations from the installers' bare `patch -b`:
#     * no -b, and --no-backup-if-mismatch, so patch never writes a .orig of
#       its own.  Any .orig left in the tree is then evidence of a bad apply
#       rather than expected noise.  (Without this, patch creates a .orig
#       whenever the diff's ---/+++ names differ, which they do for every hook
#       here -- the old hooks rename kernel_sources/ to patch_cirrus/.)
#     * --batch, so a hook that cannot apply fails instead of prompting.
#     * --verbose, because --batch also silences the "Hunk #N succeeded at L
#       (offset N lines)" / "with fuzz N" messages.  Without it the fuzz and
#       offset assertions below would never fire and would be vacuous.
run_patch() {
  local hda=$1 pflag=$2 diff=$3 dry=${4-}
  PATCH_OUT=$(patch --batch --verbose --no-backup-if-mismatch -d "$hda" "$pflag" $dry < "$diff" 2>&1)
  PATCH_RC=$?
}

# diff_target_basename <diff> -- the file the diff patches, as patch will name
# it in its output (the basename of the +++ path).
diff_target_basename() {
  sed -n 's|^+++ [ab]/||p' "$1" | head -1 | awk -F/ '{ print $NF }'
}

# apply_one <tree> <hda_dir> <pflag> <diff> <label>
#   Apply <diff> the way the installer does: a --dry-run pass first, which
#   names the diff when it cannot apply, then the real pass so the next diff is
#   checked against the patched result.  Asserts exit 0, no fuzz, no offset.
apply_one() {
  local tree=$1 hda=$2 pflag=$3 diff=$4 label=$5 report
  run_patch "$hda" "$pflag" "$diff" --dry-run
  assert_eq 0 "$PATCH_RC" "$label: $diff dry-run on $tree (output: $PATCH_OUT)"
  run_patch "$hda" "$pflag" "$diff"
  report="$PATCH_OUT"
  assert_eq 0 "$PATCH_RC" "$label: $diff applies to $tree (output: $report)"
  if [ "$PATCH_RC" -eq 0 ]; then
    APPLIED_COUNT=$((APPLIED_COUNT + 1))
    APPLIED_DIFFS="$APPLIED_DIFFS $(basename "$diff")"
  fi
  assert_eq "absent" "$(grep_ci "$report" 'fuzz' && echo present || echo absent)" \
    "$label: $diff applied with fuzz to $tree -- the hook is drifting (output: $report)"
  assert_eq "absent" "$(grep_ci "$report" 'offset' && echo present || echo absent)" \
    "$label: $diff applied with offset to $tree -- the hook is drifting (output: $report)"
}

# check_no_stray <tree> <label> <allowed .orig paths...>
#   Assert the tree holds no *.rej and no *.orig other than the Makefile
#   backups the installer itself creates.
check_no_stray() {
  local tree=$1 label=$2
  shift 2
  local list="$scratch/stray.$$.txt" f base a allowed rej orig
  find "$tree" \( -name '*.rej' -o -name '*.orig' \) > "$list" 2>/dev/null
  rej=""
  orig=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=${f#"$tree"/}
    case "$base" in
      *.rej) rej="$rej $base" ;;
      *.orig)
        allowed=no
        for a in "$@"; do
          [ "$base" = "$a" ] && allowed=yes
        done
        [ "$allowed" = yes ] || orig="$orig $base"
        ;;
    esac
  done < "$list"
  rm -f "$list"
  assert_eq "" "$rej" "$label: no .rej files left behind (found:$rej)"
  assert_eq "" "$orig" "$label: no unexpected .orig files left behind (found:$orig)"
}

APPLIED_COUNT=0
APPLIED_DIFFS=""

# ---------------------------------------------------------------------------
# pinned trees
# ---------------------------------------------------------------------------

new_tree="$scratch/new-tree"
old_tree="$scratch/old-tree"
obtain new "$new_tree"
obtain old "$old_tree"
note "pinned trees ready: new=$new_tree old=$old_tree"

new_hda="$new_tree/sound/hda"
old_hda="$old_tree/sound/pci/hda"

# ---------------------------------------------------------------------------
# NEGATIVE CASE (written first): a corrupted hook must be rejected, and the
# failure must name the offending file.  The corruption happens on a copy in
# the scratch directory -- the repository is never modified.
# ---------------------------------------------------------------------------

# corrupt_diff <src> <dest> -- copy <src> to <dest> with the first removed line
# (`-`, but not the `---` header) replaced by text that cannot be in the kernel
# tree.  The hunk then has nothing to remove and must be rejected.  The
# `---`/`+++` header is left intact so patch still knows which file it targets.
#
# The caller must pick a diff that actually removes lines: a pure-addition hook
# has no `-` line to corrupt, and the copy would be byte-identical to the
# original.  corrupt_diff reports that case rather than silently doing nothing.
corrupt_diff() {
  awk '
    !done && /^-/ && !/^---/ {
      print "-a line that is definitely not in the kernel tree"
      done = 1
      next
    }
    { print }
  ' "$1" > "$2"
  if cmp -s "$1" "$2"; then
    fail "corrupt_diff: $1 has no removed line to corrupt; the copy is unchanged"
    return 1
  fi
  return 0
}

neg_tree="$scratch/neg-tree"
obtain old "$neg_tree"
neg_hda="$neg_tree/sound/pci/hda"
# patch_patch_cs8409.h.diff is used because it removes lines; a pure-addition
# hook (patch_patch_cs8409.c.diff) has nothing to corrupt.
neg_src="$REPO_ROOT/patch_patch_cs8409.h.diff"
neg_diff="$scratch/$(basename "$neg_src")"
corrupt_diff "$neg_src" "$neg_diff"
assert_file_exists "$neg_diff" "the corrupted diff copy was written to the scratch dir"

run_patch "$neg_hda" -p2 "$neg_diff" --dry-run
assert_ne 0 "$PATCH_RC" "a corrupted diff must not be reported as applying cleanly"
assert_contains "$PATCH_OUT" "$(diff_target_basename "$neg_diff")" \
  "the failure names the file the corrupted diff patches"
assert_contains "$PATCH_OUT" "hunks failed" \
  "the failure says the hunk did not apply"
note "negative case: corrupted $(basename "$neg_src") rejected as expected"

# ---------------------------------------------------------------------------
# NEW sequence -- install.cirrus.driver.sh:213-299 (kernel >= 6.17)
# ---------------------------------------------------------------------------

# 213-216: the installer moves the four Makefiles aside.
mv "$new_hda/Makefile" "$new_hda/Makefile.orig"
mv "$new_hda/common/Makefile" "$new_hda/common/Makefile.orig"
mv "$new_hda/codecs/Makefile" "$new_hda/codecs/Makefile.orig"
mv "$new_hda/codecs/cirrus/Makefile" "$new_hda/codecs/cirrus/Makefile.orig"

# 218-221: and drops its own in.
cp "$REPO_ROOT/makefiles/Makefile" "$new_hda"
cp "$REPO_ROOT/makefiles/Makefile_common" "$new_hda/common/Makefile"
cp "$REPO_ROOT/makefiles/Makefile_codecs" "$new_hda/codecs/Makefile"
cp "$REPO_ROOT/makefiles/Makefile_cirrus" "$new_hda/codecs/cirrus/Makefile"

# 225-230: the explicit file list copied into codecs/cirrus.
cp "$REPO_ROOT/patch_cirrus/cirrus_apple.h" "$new_hda/codecs/cirrus"
cp "$REPO_ROOT/patch_cirrus/patch_cirrus_boot84.h" "$new_hda/codecs/cirrus"
cp "$REPO_ROOT/patch_cirrus/patch_cirrus_new84.h" "$new_hda/codecs/cirrus"
cp "$REPO_ROOT/patch_cirrus/patch_cirrus_real84.h" "$new_hda/codecs/cirrus"
cp "$REPO_ROOT/patch_cirrus/patch_cirrus_hda_generic_copy.h" "$new_hda/codecs/cirrus"
cp "$REPO_ROOT/patch_cirrus/patch_cirrus_real84_i2c.h" "$new_hda/codecs/cirrus"

# 233 `pushd $hda_dir`, then 276/286 and 279/289: the two hooks, both -p1.
# The 6.17.13 pin is `iscurrent >= 0`, so both branches apply both hooks.
apply_one "$new_tree" "$new_hda" -p1 "$REPO_ROOT/patch_cs8409.c.diff" "new"
apply_one "$new_tree" "$new_hda" -p1 "$REPO_ROOT/patch_cs8409.h.diff" "new"

check_no_stray "$new_tree" "new" $ALLOWED_ORIG_NEW

# The spliced hook must be present in the patched cs8409.c.
file_has "$new_hda/codecs/cirrus/cs8409.c" "cs8409_apple(" \
  "new: the patched cs8409.c calls cs8409_apple()"
file_has "$new_hda/codecs/cirrus/cs8409.c" '#include "cirrus_apple.h"' \
  "new: the patched cs8409.c includes cirrus_apple.h"

# ---------------------------------------------------------------------------
# OLD sequence -- install.cirrus.driver.pre617.sh:228-303 (kernel < 6.17)
# ---------------------------------------------------------------------------

# 228: the installer moves the Makefile aside.
mv "$old_hda/Makefile" "$old_hda/Makefile.orig"

# 229: and copies patch_cirrus/Makefile plus every patch_cirrus/patch_cirrus_*
# file into the tree.  The glob is reproduced verbatim.
cp "$REPO_ROOT/patch_cirrus/Makefile" "$REPO_ROOT"/patch_cirrus/patch_cirrus_* "$old_hda"

# 230 `pushd $hda_dir`.  The 5.x<5.13 branch at 270-271 is not taken by a 6.x
# pin, so the sequence starts at 288 (mainline) / 275 (ubuntu): both -p2.
apply_one "$old_tree" "$old_hda" -p2 "$REPO_ROOT/patch_patch_cs8409.c.diff" "old"
apply_one "$old_tree" "$old_hda" -p2 "$REPO_ROOT/patch_patch_cs8409.h.diff" "old"

# 296: the installer re-copies the same files mid-sequence, before the last
# hook -- so the re-copy cannot undo the patch that follows it.
cp "$REPO_ROOT/patch_cirrus/Makefile" "$REPO_ROOT"/patch_cirrus/patch_cirrus_* "$old_hda"

# 299: the last hook.
apply_one "$old_tree" "$old_hda" -p2 "$REPO_ROOT/patch_patch_cirrus_apple.h.diff" "old"

check_no_stray "$old_tree" "old" $ALLOWED_ORIG_OLD

# ---------------------------------------------------------------------------
# coverage: every root *.diff is applied by one of the two sequences, or is
# explicitly listed in KNOWN_UNUSED with a justification.  This is what
# catches an orphan hook that no installer reaches any more.
#
# patches/*.diff is a separate directory of Ubuntu/mainline variant hooks,
# selected by the installers' iscurrent branches; it is deliberately out of
# scope for this test.
# ---------------------------------------------------------------------------

root_diffs=""
for f in "$REPO_ROOT"/*.diff; do
  [ -e "$f" ] || continue
  root_diffs="$root_diffs $(basename "$f")"
done
assert_ne 0 "$(printf '%s\n' $root_diffs | grep -c .)" \
  "the repository root has *.diff hooks to check (an empty inventory would make this test vacuous)"

for d in $KNOWN_UNUSED; do
  assert_file_exists "$REPO_ROOT/$d" "KNOWN_UNUSED entry $d exists in the repository root"
done

expected=0
for d in $root_diffs; do
  case " $KNOWN_UNUSED " in
    *" $d "*) continue ;;
  esac
  expected=$((expected + 1))
  case " $APPLIED_DIFFS " in
    *" $d "*) ;;
    *) fail "orphan hook: $d is applied by neither installer sequence and is not in KNOWN_UNUSED" ;;
  esac
done

# Never silently pass with nothing applied.
assert_ne 0 "$APPLIED_COUNT" \
  "at least one hook was applied (a run that applies nothing is not a pass)"
assert_eq "yes" "$([ "$APPLIED_COUNT" -ge "$expected" ] && echo yes || echo no)" \
  "applied count ($APPLIED_COUNT) is at least the number of root *.diff files in play ($expected)"

printf 'hooks applied: %s of %s in play (root *.diff: %s)\n' \
  "$APPLIED_COUNT" "$expected" "$(printf '%s\n' $root_diffs | grep -c .)"
printf 'applied:%s\n' "$APPLIED_DIFFS"

finish
