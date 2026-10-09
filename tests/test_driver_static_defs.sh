#!/usr/bin/env bash
#
# tests/test_driver_static_defs.sh
#
# HDA-43 (S18): functions defined in the in-scope driver headers must be
# `static`.  The headers are #included into a single translation unit
# (cs8409.c / patch_cs8409.c), so a non-static function only leaks a symbol
# into the module's global namespace.  The same check covers forward
# prototypes, because a `static` definition after a non-static prototype is a
# compile error.
#
# Heuristic (no kernel build needed): a line at column 0 that looks like
# `name(` and is not preceded by `static` -- either on the same line or on a
# preceding return-type-only line -- is a violation.
#
# Out of scope (follow-up stories): the other patch_cirrus/*.h headers and
# non-static variable definitions.  A kernel build is the real check.
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

# "file:function" entries that may stay non-static, one justification each.
ALLOW=()

# non_static_functions FILE -- print `name` for each non-static function
# definition or prototype in FILE.
non_static_functions() {
  awk '
    /^[a-z_][a-z0-9_ \*]*\(/ {
      if (prev !~ /^static[^(;]*$/ && $0 !~ /^static/) {
        name = $0; sub(/\(.*/, "", name); sub(/^.*[ \*]/, "", name)
        print name
      }
    }
    { prev = $0 }
  ' "$1"
}

# violations FILE -- non_static_functions minus the allow-list.
violations() {
  local f=$1 name entry
  while IFS= read -r name; do
    for entry in "${ALLOW[@]+"${ALLOW[@]}"}"; do
      [ "$entry" = "${f}:${name}" ] && continue 2
    done
    printf '%s\n' "$name"
  done < <(non_static_functions "$f")
}

# --- checker self-test against a negative fixture ---------------------------
TMP=$(make_tmpdir)
cat > "$TMP/bad.h" <<'FIXTURE'
void leaks_symbol(struct hda_codec *codec)
{
}

struct hda_jack_callback *
leaks_split_signature(struct hda_codec *codec);

static void is_fine(struct hda_codec *codec)
{
}

static struct hda_jack_tbl *
is_fine_split(struct hda_codec *codec)
{
}
FIXTURE
assert_eq $'leaks_symbol\nleaks_split_signature' "$(non_static_functions "$TMP/bad.h")" \
  "the checker flags non-static functions and ignores static ones"

# --- the in-scope headers ---------------------------------------------------
for rel in "${IN_SCOPE[@]}"; do
  assert_file_exists "$REPO_ROOT/$rel" "$rel exists"
  assert_eq "" "$(violations "$REPO_ROOT/$rel")" "$rel has no non-static functions"
done

finish
