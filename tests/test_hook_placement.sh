#!/usr/bin/env bash
#
# tests/test_hook_placement.sh
#
# HDA-39: the Apple include must be the LAST #include of the patched
# cs8409.c, and the cs8409_apple() call spliced into the probe path must be
# preceded by a forward declaration (the definition now arrives from the
# include at the end of the file).  Checked on both pinned trees.
#
# Scope limit: cs8409.c is not compiled here (no kernel build dependency), so
# "compiles in scope" is NOT verified by this test -- see NOTES.md.

set -u

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)

. "$TEST_DIR/lib/assert.sh"
. "$TEST_DIR/lib/kernel_cache.sh"

scratch=$(make_tmpdir)

# check_placement <which> <hda_subdir> <pflag> <label> <c-hook> <h-hook> <include> <fn> <target .c rel to hda>
check_placement() {
  local which=$1 sub=$2 pflag=$3 label=$4 chook=$5 hhook=$6 inc=$7 fn=$8 target=$9
  local tree="$scratch/$label-tree" rc out hda c last_inc inc_line decl_line call_line

  kernel_tree_copy "$which" "$tree"
  rc=$?
  if [ "$rc" -eq 77 ]; then
    skip "$which kernel tree unavailable offline"
  fi
  if [ "$rc" -ne 0 ]; then
    # kernel_cache cannot extract the >= 6.17 layout; use the installer's tar line.
    # shellcheck disable=SC1090
    . "$TEST_DIR/kernel-pins.conf"
    local ver tarball strip member root
    case "$which" in
      new) ver=$PIN_NEW_VERSION; tarball=$PIN_NEW_TARBALL; strip=2; member=sound/hda ;;
      old) ver=$PIN_OLD_VERSION; tarball=$PIN_OLD_TARBALL; strip=3; member=sound/pci/hda ;;
    esac
    root=${HDA_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-tests}
    [ -f "$root/tarballs/$tarball" ] || skip "$which kernel tarball not cached (offline)"
    mkdir -p "$scratch/$label-x" "$tree/$(dirname "$member")"
    tar -xf "$root/tarballs/$tarball" -C "$scratch/$label-x" --strip-components="$strip" \
      "linux-$ver/$member" || { _hda_fail "$label: cannot extract $member"; return; }
    mv "$scratch/$label-x/hda" "$tree/$member"
  fi
  hda="$tree/$sub"

  for hook in "$chook" "$hhook"; do
    out=$(patch --batch --verbose --no-backup-if-mismatch -d "$hda" "$pflag" < "$REPO_ROOT/$hook" 2>&1)
    rc=$?
    assert_eq 0 "$rc" "$label: $hook applies (output: $out)"
    assert_eq "absent" "$(printf '%s\n' "$out" | grep -qiE 'fuzz|offset' && echo present || echo absent)" \
      "$label: $hook applies with no fuzz or offset (output: $out)"
  done

  c="$hda/$target"
  assert_file_exists "$c" "$label: patched $target exists"
  [ -f "$c" ] || return

  last_inc=$(grep -E '^[[:space:]]*#[[:space:]]*include' "$c" | tail -1)
  assert_eq "#include \"$inc\"" "$last_inc" \
    "$label: the $inc include is the last #include in $target"

  inc_line=$(grep -n "^#include \"$inc\"" "$c" | cut -d: -f1)
  decl_line=$(grep -n "^static int $fn(struct hda_codec \*codec);" "$c" | head -1 | cut -d: -f1)
  call_line=$(grep -n "= $fn(codec);" "$c" | head -1 | cut -d: -f1)
  assert_ne "" "$decl_line" "$label: forward declaration of $fn exists"
  assert_ne "" "$call_line" "$label: call to $fn exists"
  if [ -n "$decl_line" ] && [ -n "$call_line" ]; then
    assert_eq "before" "$([ "$decl_line" -lt "$call_line" ] && echo before || echo after)" \
      "$label: $fn is declared before its first call"
  fi

  # The module registration (driver table and ops) must precede the include.
  if [ -n "$inc_line" ]; then
    assert_eq "before" \
      "$([ "$(grep -n '^module_hda_codec_driver' "$c" | head -1 | cut -d: -f1)" -lt "$inc_line" ] && echo before || echo after)" \
      "$label: the module registration precedes the $inc include"
  fi
}

check_placement new sound/hda -p1 new patch_cs8409.c.diff patch_cs8409.h.diff \
  cirrus_apple.h cs8409_apple codecs/cirrus/cs8409.c
check_placement old sound/pci/hda -p2 old patch_patch_cs8409.c.diff patch_patch_cs8409.h.diff \
  patch_cirrus_apple.h patch_cs8409_apple patch_cs8409.c

finish
