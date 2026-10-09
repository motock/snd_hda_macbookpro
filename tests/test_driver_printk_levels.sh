#!/usr/bin/env bash
#
# tests/test_driver_printk_levels.sh
#
# HDA-44 (S18): every `printk(` in the in-scope driver headers must start with
# a KERN_* log level.  An unlevelled printk logs at the default level
# (KERN_WARNING), so debug chatter lands in dmesg for every user.  The
# `myprintk` / `myprintk_dbg` debug macros are fine to call: their bodies are
# the only place the level is spelled, and the check covers those bodies.
#
# Out of scope (follow-up stories): patch_cirrus_real84.h and
# patch_cirrus_real84_i2c.h.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/lib/assert.sh"

IN_SCOPE=(
  patch_cirrus/cirrus_apple.h
  patch_cirrus/patch_cirrus_apple.h
  patch_cirrus/patch_cirrus_new84.h
)

# unlevelled FILE -- print `line:text` for each bare printk( whose first
# argument is not a KERN_* constant.  `myprintk(` is a different identifier and
# is not matched.
unlevelled() {
  grep -nE '(^|[^A-Za-z0-9_])printk\(' "$1" | grep -vE 'printk\(KERN_[A-Z]+[ ,)"]' || true
}

# --- checker self-test against a negative fixture ---------------------------
TMP=$(make_tmpdir)
cat > "$TMP/bad.h" <<'FIXTURE'
printk("snd_hda_intel: no level\n");
printk(fmt, ##args)
printk(KERN_DEBUG "snd_hda_intel: levelled\n");
myprintk("snd_hda_intel: macro call\n");
printk(KERN_CONT "continuation\n");
FIXTURE
assert_eq $'1:printk("snd_hda_intel: no level\\n");\n2:printk(fmt, ##args)' \
  "$(unlevelled "$TMP/bad.h")" \
  "the checker flags unlevelled printk and ignores KERN_* and myprintk"

# --- the in-scope headers ---------------------------------------------------
for rel in "${IN_SCOPE[@]}"; do
  assert_file_exists "$REPO_ROOT/$rel" "$rel exists"
  assert_eq "" "$(unlevelled "$REPO_ROOT/$rel")" "$rel has no unlevelled printk"
done

finish
