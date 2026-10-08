#!/usr/bin/env bash
#
# tests/test_driver_apple_ops_probe.sh
#
# Static guard for HDA-24: `cs_8409_apple_ops` in patch_cirrus/cirrus_apple.h
# must carry a `.probe` member, and the dead "explicit" scaffolding around it
# must be gone.
#
# Why `.probe` matters (diagnosis, pinned linux-6.17.13 tree):
#
#   sound/hda/common/bind.c, hda_codec_driver_probe():
#       if (WARN_ON(!(driver->ops && driver->ops->probe))) {
#               err = -EINVAL;
#               goto error_module_put;
#       }
#       err = driver->ops->probe(codec, codec->preset);
#
#   The kernel's own table is
#       sound/hda/codecs/cirrus/cs8409.c
#       static const struct hda_codec_ops cs8409_codec_ops = {
#               .probe = cs8409_probe, ...
#       };
#
#   cs8409_apple() overwrites driver->ops with cs_8409_apple_ops.  Before this
#   fix that table had no .probe, so the *next* probe of the codec (unbind then
#   bind, or a module reload) tripped the WARN_ON and failed with -EINVAL.
#   The original behaviour -- the probe the driver was registered with -- is
#   cs8409_probe, which is in scope at the include point: the hook
#   patch_cs8409.c.diff inserts `#include "cirrus_apple.h"` into cs8409.c
#   *after* the definition of cs8409_probe and after cs8409_codec_ops.
#
# Checks:
#   1. the cs_8409_apple_ops initialiser contains `.probe` (and names the
#      kernel's own cs8409_probe);
#   2. the dead `cs_8409_apple_ops_explicit` alternative and the `int explicit`
#      variable are gone;
#   3. the file holds no `#if 0` blocks -- the negative guard that stops the
#      fix from being "achieved" by commenting the old code out;
#   4. the >= 6.17 hooks still apply cleanly to the pinned new tree, and the
#      include point really is after cs8409_probe (the premise of check 1).
#
# Exit codes: 0 pass, 1 fail, 77 skip (pinned tarball unavailable offline).
#
# ---------------------------------------------------------------------------
# TDD NOTE
# ---------------------------------------------------------------------------
# This file was written before the fix and run to confirm it goes red: checks
# 1-3 all failed against the unfixed cirrus_apple.h.  Check 4 passed both
# before and after -- it is the guard that the fix's premise (cs8409_probe is
# visible at the include point) still holds, not a check of the fix itself.
# ---------------------------------------------------------------------------

set -u

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
APPLE_H="$REPO_ROOT/patch_cirrus/cirrus_apple.h"

. "$TEST_DIR/lib/assert.sh"

scratch=$(make_tmpdir)

# ---------------------------------------------------------------------------
# 0. sanity -- the file exists and the ops table can be located.  Without this
#    an empty extraction would make check 1 vacuously "pass".
# ---------------------------------------------------------------------------

assert_file_exists "$APPLE_H" "patch_cirrus/cirrus_apple.h exists"

apple_h_text=$(cat "$APPLE_H")

ops_block=$(awk '
  /static const struct hda_codec_ops cs_8409_apple_ops = \{/ { inblk = 1 }
  inblk { print }
  inblk && /^\};/ { exit }
' "$APPLE_H")

assert_ne "" "$ops_block" \
  "found the cs_8409_apple_ops initialiser (an empty block would make check 1 vacuous)"

# ---------------------------------------------------------------------------
# 1. the ops table carries .probe, pointing at the kernel's own probe
# ---------------------------------------------------------------------------

assert_contains "$ops_block" ".probe" \
  "cs_8409_apple_ops has a .probe member (hda_codec_driver_probe WARN_ONs without one)"

assert_contains "$ops_block" "cs8409_probe" \
  "cs_8409_apple_ops .probe preserves the original behaviour by naming cs8409_probe"

# The overwrite itself must survive: the fix adds .probe, it does not stop
# cs8409_apple() from installing its own table.
assert_contains "$apple_h_text" "driver->ops = &cs_8409_apple_ops;" \
  "cs8409_apple() still installs cs_8409_apple_ops as driver->ops"

# ---------------------------------------------------------------------------
# 2. the dead explicit-ops scaffolding is gone
# ---------------------------------------------------------------------------

assert_not_contains "$apple_h_text" "cs_8409_apple_ops_explicit" \
  "the commented-out cs_8409_apple_ops_explicit alternative is deleted"

assert_not_contains "$apple_h_text" "int explicit" \
  "the dead 'int explicit' variable is deleted"

# ---------------------------------------------------------------------------
# 3. negative guard: no #if 0 blocks anywhere in the file
# ---------------------------------------------------------------------------

if0=$(grep -nE '^[[:space:]]*#[[:space:]]*if[[:space:]]+0([[:space:]]|$)' "$APPLE_H" || true)
assert_eq "" "$if0" \
  "cirrus_apple.h contains no #if 0 blocks (dead code must be deleted, not disabled)"

# ---------------------------------------------------------------------------
# 4. the >= 6.17 hooks still apply to the pinned new tree, and the include
#    point is after cs8409_probe -- the premise check 1 relies on.
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
. "$TEST_DIR/kernel-pins.conf"

cache_root=${HDA_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-tests}
tarball="$cache_root/tarballs/$PIN_NEW_TARBALL"
if [ ! -f "$tarball" ]; then
  skip "pinned new kernel tarball $PIN_NEW_TARBALL is not cached (offline)"
fi

tree="$scratch/new-tree"
mkdir -p "$tree"
if ! tar -xf "$tarball" -C "$tree" --strip-components=2 \
     "linux-$PIN_NEW_VERSION/sound/hda"; then
  fail "cannot extract sound/hda from $PIN_NEW_TARBALL"
  finish
fi
hda="$tree/hda"

# The two hooks install.cirrus.driver.sh applies for >= 6.17 (lines 276, 286).
# patch_cs8409.c.diff is the one that inserts `#include "cirrus_apple.h"`.
for hook in patch_cs8409.c.diff patch_cs8409.h.diff; do
  hook_path="$REPO_ROOT/$hook"
  assert_file_exists "$hook_path" "$hook exists in the repository root"
  if [ ! -f "$hook_path" ]; then
    continue
  fi
  out=$(cd "$hda" && patch -p1 < "$hook_path" 2>&1)
  rc=$?
  assert_eq 0 "$rc" "$hook applies cleanly to the pinned new tree (output: $out)"
  assert_eq "absent" "$(printf '%s\n' "$out" | grep -qi 'fuzz' && echo present || echo absent)" \
    "$hook applies with no fuzz to the pinned new tree (output: $out)"
  assert_eq "absent" "$(printf '%s\n' "$out" | grep -qi 'offset' && echo present || echo absent)" \
    "$hook applies with no offset to the pinned new tree (output: $out)"
done

rej=$(find "$hda" -name '*.rej' 2>/dev/null)
assert_eq "" "$rej" "the hooks leave no .rej files behind"

cs8409_c="$hda/codecs/cirrus/cs8409.c"
assert_file_exists "$cs8409_c" "the patched cs8409.c exists"

probe_line=$(grep -n '^static int cs8409_probe(struct hda_codec \*codec' "$cs8409_c" | cut -d: -f1)
inc_line=$(grep -n '^#include "cirrus_apple.h"' "$cs8409_c" | cut -d: -f1)

assert_ne "" "$probe_line" "cs8409_probe is defined in the patched cs8409.c"
assert_ne "" "$inc_line" "cirrus_apple.h is included by the patched cs8409.c"

if [ -n "$probe_line" ] && [ -n "$inc_line" ]; then
  assert_eq "before" \
    "$([ "$probe_line" -lt "$inc_line" ] && echo before || echo after)" \
    "cs8409_probe is defined before the cirrus_apple.h include, so it is in scope there"
fi

finish
