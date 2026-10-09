#!/usr/bin/env bash
#
# tests/test_build_flags.sh
#
# HDA-45 (S18): the build must not hide unused-symbol warnings.
#   1. -Wno-unused-variable / -Wno-unused-function appear in no build file.
#   2. The three KBUILD_EXTRA_CFLAGS variants (debug, normal, INTERNAL_MIKE_ONLY)
#      still exist and still carry the -D flags they need (positive control: a
#      lazy deletion of a whole line would fail here).
#   3. Every `static` function/variable in the in-scope headers is referenced
#      at least once besides its definition (comments excluded), so removing
#      the warning suppression cannot expose a new warning from dead code.
#
# Check 3 is a grep heuristic.  It cannot see symbols that are referenced only
# inside a conditional block that is off in a given build, nor unused locals.
# A real kernel build on both kernel generations is the actual verification.
#
# Out of scope (follow-up stories): dead statics in patch_cirrus_real84.h,
# patch_cirrus_real84_i2c.h, patch_cirrus_boot84.h, patch_cirrus_apple.h.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=tests/lib/assert.sh
. "$SCRIPT_DIR/lib/assert.sh"

BUILD_FILES=(
  Makefile
  makefiles/Makefile
  makefiles/Makefile_cirrus
  makefiles/Makefile_codecs
  makefiles/Makefile_common
  patch_cirrus/Makefile
  dkms.conf
)

IN_SCOPE=(
  patch_cirrus/cirrus_apple.h
  patch_cirrus/patch_cirrus_new84.h
)

# "file:symbol" entries allowed to have no other reference, one justification each.
ALLOW=()

# strip_comments FILE -- FILE without /* */ and // comments.
strip_comments() {
  perl -0pe 's{/\*.*?\*/}{my $n = () = $& =~ /\n/g; "\n" x $n}gse; s{//[^\n]*}{}g' "$1"
}

# static_symbols FILE -- print the name of each column-0-or-indented `static`
# function or variable defined in comment-stripped stdin-style text FILE.
static_symbols() {
  awk '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] !~ /^[ \t]*static[ \t]/) continue
        txt = line[i] " " line[i+1] " " line[i+2] " " line[i+3]
        sub(/\(.*/, "", txt); sub(/\[.*/, "", txt); sub(/[ \t]*=.*/, "", txt); sub(/;.*/, "", txt)
        sub(/[ \t]+$/, "", txt)
        sub(/^.*[ \t*]/, "", txt)
        print txt
      }
    }' "$1"
}

# unreferenced_symbols FILE CORPUS -- statics of FILE whose name occurs fewer
# than twice (definition + one use) in CORPUS, minus the allow-list.
unreferenced_symbols() {
  local f=$1 corpus=$2 name entry count
  while IFS= read -r name; do
    for entry in "${ALLOW[@]+"${ALLOW[@]}"}"; do
      [ "$entry" = "${f}:${name}" ] && continue 2
    done
    count=$(grep -ow -- "$name" "$corpus" | wc -l | tr -d ' ')
    [ "$count" -lt 2 ] && printf '%s\n' "$name"
  done < <(strip_comments "$REPO_ROOT/$f" | static_symbols /dev/stdin)
}

# --- 1. no suppression flags anywhere ---------------------------------------
for rel in "${BUILD_FILES[@]}"; do
  [ -f "$REPO_ROOT/$rel" ] || continue
  content=$(cat "$REPO_ROOT/$rel")
  assert_not_contains "$content" "Wno-unused-variable" "$rel has no -Wno-unused-variable"
  assert_not_contains "$content" "Wno-unused-function" "$rel has no -Wno-unused-function"
done

# --- 2. the three variants survive with their flags -------------------------
MAKEFILE="$REPO_ROOT/Makefile"
debug_line=$(grep -E '^#?KBUILD_EXTRA_CFLAGS.*MYSOUNDDEBUGFULL' "$MAKEFILE")
normal_line=$(grep -E '^KBUILD_EXTRA_CFLAGS' "$MAKEFILE")
mike_line=$(grep -E '^#?KBUILD_EXTRA_CFLAGS.*INTERNAL_MIKE_ONLY' "$MAKEFILE")

assert_eq "1" "$(printf '%s\n' "$debug_line" | grep -c .)" "exactly one debug variant exists"
assert_eq "1" "$(printf '%s\n' "$normal_line" | grep -c .)" "exactly one active (normal) variant exists"
assert_eq "1" "$(printf '%s\n' "$mike_line" | grep -c .)" "exactly one INTERNAL_MIKE_ONLY variant exists"

for line_name in debug_line normal_line mike_line; do
  line=${!line_name}
  assert_contains "$line" "-DAPPLE_PINSENSE_FIXUP" "$line_name keeps -DAPPLE_PINSENSE_FIXUP"
  assert_contains "$line" "-DAPPLE_CODECS" "$line_name keeps -DAPPLE_CODECS"
  assert_contains "$line" "-DCONFIG_SND_HDA_RECONFIG=1" "$line_name keeps -DCONFIG_SND_HDA_RECONFIG=1"
done
assert_contains "$debug_line" "-DCONFIG_SND_DEBUG=1" "debug variant keeps -DCONFIG_SND_DEBUG=1"
assert_not_contains "$normal_line" "INTERNAL_MIKE_ONLY" "normal variant does not enable INTERNAL_MIKE_ONLY"

# --- 3. static symbols are referenced ---------------------------------------
TMP=$(make_tmpdir)
cat > "$TMP/dead.h" <<'FIXTURE'
static void dead_function(struct hda_codec *codec)
{
}

static const struct hda_verb dead_table[] = {
	{} /* terminator */
};

static void
dead_split_signature(struct hda_codec *codec);

static void live_function(struct hda_codec *codec)
{
}

/* dead_in_comment(codec) only appears in this comment */
static void dead_in_comment(struct hda_codec *codec)
{
	live_function(codec);
}
FIXTURE
strip_comments "$TMP/dead.h" > "$TMP/dead.stripped"
assert_eq "dead_function dead_in_comment dead_split_signature dead_table live_function " \
  "$(static_symbols "$TMP/dead.stripped" | sort | tr '\n' ' ')" \
  "the extractor finds plain, table and split-signature statics"

dead_found=$(
  while IFS= read -r name; do
    [ "$(grep -ow -- "$name" "$TMP/dead.stripped" | wc -l | tr -d ' ')" -lt 2 ] && echo "$name"
  done < <(static_symbols "$TMP/dead.stripped") | sort | tr '\n' ' '
)
assert_eq "dead_function dead_in_comment dead_split_signature dead_table " "$dead_found" \
  "the checker flags unreferenced statics (comment mentions do not count) and spares live ones"

CORPUS="$TMP/corpus"
for rel in "$REPO_ROOT"/patch_cirrus/*.h "$REPO_ROOT"/patch_cirrus/*.c; do
  strip_comments "$rel"
done > "$CORPUS"

for rel in "${IN_SCOPE[@]}"; do
  assert_file_exists "$REPO_ROOT/$rel" "$rel exists"
  assert_eq "" "$(unreferenced_symbols "$rel" "$CORPUS")" "$rel has no unreferenced static symbols"
done

finish
