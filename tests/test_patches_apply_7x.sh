#!/usr/bin/env bash
#
# tests/test_patches_apply_7x.sh
#
# Checks that patch_cs8409.c.diff and patch_cs8409.h.diff still apply to a
# pristine Linux 7.x sound/hda tree, the way install.cirrus.driver.sh applies
# them:
#
#   tar --strip-components=2 -x linux-<ver>/sound/hda   (-> <dir>/hda)
#   cd <dir>/hda
#   patch -b -p1 < patch_cs8409.c.diff
#   patch -b -p1 < patch_cs8409.h.diff
#
# The tarball is the 7.x pin in tests/kernel-pins.conf (PIN_7X_*), obtained and
# SHA-256 verified through tests/lib/kernel_cache.sh (_kc_ensure_tarball).  The
# helper only knows the "new"/"old" pins and the v6.x mirror, so this test hands it a temporary
# pins file that maps PIN_NEW_* onto PIN_7X_* and points HDA_KERNEL_MIRROR at
# the v7.x directory.
#
# Reported per file: hunks, hunks applied with an offset, hunks applied with
# fuzz, highest fuzz level, FAILED hunks.  Fails on any FAILED hunk, a non-zero
# patch exit, or any *.rej file.  Fuzz must not exceed the baseline below, so
# creeping fuzz is visible before it turns into a failed hunk.
#
# Measured against linux-7.1.13 (GNU patch 2.8, 2026-10-08):
#   cs8409.c: 3 hunks, 3 at offset 149, 0 with fuzz
#   cs8409.h: 4 hunks, 4 at offsets 1-4, 2 with fuzz 2 (hunks #1 and #4)
# (7.0 baseline: .c offset 159 no fuzz; .h offsets 1-4, fuzz 2 on #1 and #4.)
#
# Offsets and fuzz are only reported by GNU patch (BSD/Apple patch is silent
# about them), so without GNU patch (patch or gpatch) the test skips.
#
# Skips (77) when the tarball is not cached and cannot be downloaded.  Writes
# only into temp dirs and the kernel cache, never into the repository.
#
# Exit codes: 0 = pass, 1 = fail, 77 = skip.

set -u

HDA_TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HDA_TEST_DIR/.." && pwd)

. "$HDA_TEST_DIR/lib/assert.sh"
. "$HDA_TEST_DIR/lib/kernel_cache.sh"

C_DIFF="$REPO_ROOT/patch_cs8409.c.diff"
H_DIFF="$REPO_ROOT/patch_cs8409.h.diff"
C_FILE=codecs/cirrus/cs8409.c
H_FILE=codecs/cirrus/cs8409.h

# Fuzz ceilings = the measured baseline above.  Raise only on purpose.
MAX_FUZZED_HUNKS_C=0
MAX_FUZZ_LEVEL_C=0
MAX_FUZZED_HUNKS_H=2
MAX_FUZZ_LEVEL_H=2

SCRATCH=$(make_tmpdir)

# --- helpers ---------------------------------------------------------------

find_gnu_patch() {
  local cand
  for cand in patch gpatch; do
    if command -v "$cand" >/dev/null 2>&1 &&
       "$cand" --version 2>/dev/null | head -1 | grep -q 'GNU patch'; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# parse_patch_log <logfile> -- one line per patched file:
#   <file> <hunks> <offset> <fuzzed> <max_fuzz> <failed>
parse_patch_log() {
  awk '
    function flush() {
      if (file != "") print file, hunks, offs, fuzzed, maxf, failed
    }
    /^patching file / {
      flush(); file = $3; gsub(/[\047"]/, "", file)
      hunks = offs = fuzzed = maxf = failed = 0
    }
    /^Hunk #[0-9]+ succeeded/ {
      hunks++
      if ($0 ~ /offset/) offs++
      if (match($0, /with fuzz [0-9]+/)) {
        fuzzed++
        n = substr($0, RSTART + 10, RLENGTH - 10) + 0
        if (n > maxf) maxf = n
      }
    }
    /^Hunk #[0-9]+ FAILED/ { hunks++; failed++ }
    END { flush() }
  ' "$1"
}

# stat_field <stats> <file> <column 2..6> -- one number out of parse_patch_log.
stat_field() {
  printf '%s\n' "$1" | awk -v f="$2" -v c="$3" '$1 == f { print $c }'
}

# apply_diffs <gnu-patch> <hda-dir> <c-diff> <h-diff> <log> -- patch the way the
# installer does; the log gets all patch output.  Returns the first non-zero
# patch exit status.  --batch only suppresses interactive prompts.
apply_diffs() {
  local gp=$1 dir=$2 cd_=$3 hd=$4 log=$5 rc=0
  : > "$log"
  ( cd "$dir" &&
    "$gp" --batch -b -p1 < "$cd_" >> "$log" 2>&1 &&
    "$gp" --batch -b -p1 < "$hd" >> "$log" 2>&1 ) || rc=$?
  return "$rc"
}

count_rejects() {
  find "$1" -name '*.rej' | wc -l | tr -d ' '
}

# patches_apply_cleanly <gnu-patch> <hda-dir> <c-diff> <h-diff> <log> -- the
# pass/fail check: patch exit 0, no FAILED hunk, no *.rej.  Prints the counts.
patches_apply_cleanly() {
  local gp=$1 dir=$2 log=$5 rc=0 rejs failed
  apply_diffs "$@" || rc=$?
  PATCH_STATS=$(parse_patch_log "$log")
  rejs=$(count_rejects "$dir")
  failed=$(printf '%s\n' "$PATCH_STATS" | awk '{ s += $6 } END { print s + 0 }')
  printf '%s\n' "$PATCH_STATS" | while read -r f h o z m x; do
    printf '  %s: hunks=%s offset=%s fuzz=%s (max level %s) failed=%s\n' \
      "$f" "$h" "$o" "$z" "$m" "$x"
  done
  printf '  patch exit=%s failed_hunks=%s rej_files=%s\n' "$rc" "$failed" "$rejs"
  [ "$rc" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$rejs" -eq 0 ]
}

# fresh_hda <tarball> <dest> <version> -- build <dest>/hda like the installer.
fresh_hda() {
  mkdir -p "$2" || return 1
  tar --strip-components=2 -xf "$1" --directory="$2" "linux-$3/sound/hda"
}

# --- parser unit tests (offline, fixture-driven) ---------------------------

FIXTURE="$SCRATCH/fixture.log"
cat > "$FIXTURE" <<'EOF'
patching file a/one.c
Hunk #1 succeeded at 10 (offset 3 lines).
Hunk #2 succeeded at 40.
patching file 'b/two.h'
Hunk #1 succeeded at 20 with fuzz 2 (offset 1 line).
Hunk #2 FAILED at 90.
EOF
FIXTURE_STATS=$(parse_patch_log "$FIXTURE")
assert_eq "2 1 0 0 0" "$(printf '%s\n' "$FIXTURE_STATS" | awk '$1=="a/one.c"{print $2,$3,$4,$5,$6}')" \
  "parser counts hunks, one offset hunk, no fuzz, no failure"
assert_eq "2 1 1 2 1" "$(printf '%s\n' "$FIXTURE_STATS" | awk '$1=="b/two.h"{print $2,$3,$4,$5,$6}')" \
  "parser counts a fuzz-2 hunk with offset and a FAILED hunk, quotes stripped from the name"

# --- offline skip: empty cache + dead network -> exit 77 -------------------

PINS="$SCRATCH/pins.conf"
. "$HDA_TEST_DIR/kernel-pins.conf"
assert_ne "" "${PIN_7X_VERSION:-}" "kernel-pins.conf defines PIN_7X_VERSION"
assert_eq "linux-${PIN_7X_VERSION:-}.tar.xz" "${PIN_7X_TARBALL:-}" "PIN_7X_TARBALL is linux-<version>.tar.xz"
[[ "${PIN_7X_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] && _h=yes || _h=no
assert_eq "yes" "$_h" "PIN_7X_SHA256 is 64 lowercase hex characters"
assert_eq "yes" "$([[ "${PIN_7X_VERSION:-}" == 7.* ]] && echo yes || echo no)" "PIN_7X_VERSION is a 7.x release"

{
  printf 'PIN_NEW_VERSION="%s"\n' "$PIN_7X_VERSION"
  printf 'PIN_NEW_TARBALL="%s"\n' "$PIN_7X_TARBALL"
  printf 'PIN_NEW_SHA256="%s"\n' "$PIN_7X_SHA256"
  printf 'PIN_OLD_VERSION="%s"\n' "$PIN_7X_VERSION"
  printf 'PIN_OLD_TARBALL="%s"\n' "$PIN_7X_TARBALL"
  printf 'PIN_OLD_SHA256="%s"\n' "$PIN_7X_SHA256"
} > "$PINS"
export HDA_KERNEL_PINS="$PINS"
export HDA_KERNEL_MIRROR="${HDA_KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v7.x}"

OFFLINE_OUT="$SCRATCH/offline.out"
(
  export HDA_TEST_CACHE="$SCRATCH/empty-cache"
  export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
  export HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
  _kc_load_pins new && mkdir -p "$HDA_TEST_CACHE" && _kc_ensure_tarball
) > "$OFFLINE_OUT" 2>&1
OFFLINE_RC=$?
assert_eq 77 "$OFFLINE_RC" "uncached tarball and no network exits 77 (skip), not a failure"

# --- real run ---------------------------------------------------------------

if ! GP=$(find_gnu_patch); then
  skip "GNU patch (patch or gpatch) is required: BSD/Apple patch does not report offsets or fuzz"
fi

# kernel_tree_for would also extract sound/pci/hda, which no longer exists in
# 7.x, so use the helper's verified-tarball step directly.
_kc_load_pins new || { _hda_fail "cannot load the 7.x pin"; finish; }
_kc_ensure_tarball
rc=$?
if [ "$rc" -eq 77 ]; then
  skip "linux-$PIN_7X_VERSION is not cached and cannot be downloaded"
elif [ "$rc" -ne 0 ]; then
  _hda_fail "could not obtain a verified linux-$PIN_7X_VERSION tarball (exit $rc, not a skip)"
  finish
fi
TARBALL="$(_kc_cache_root)/tarballs/$PIN_7X_TARBALL"

for f in "$C_DIFF" "$H_DIFF"; do
  assert_file_exists "$f" "$(basename "$f") exists"
done
SUMS_BEFORE=$(cat "$C_DIFF" "$H_DIFF" | cksum)

# Positive: both diffs apply to the pinned tree.
WORK="$SCRATCH/pos"
fresh_hda "$TARBALL" "$WORK" "$PIN_7X_VERSION"
assert_file_exists "$WORK/hda/$C_FILE" "extracted tree contains $C_FILE"
echo "linux-$PIN_7X_VERSION, $GP --batch -b -p1:"
assert_exit_code 0 patches_apply_cleanly "$GP" "$WORK/hda" "$C_DIFF" "$H_DIFF" "$SCRATCH/pos.log"
assert_eq "2" "$(printf '%s\n' "$PATCH_STATS" | wc -l | tr -d ' ')" "exactly two files were patched"

# Fuzz ceilings, measured value printed beside the threshold.
for spec in "C:$C_FILE" "H:$H_FILE"; do
  k=${spec%%:*}; f=${spec#*:}
  eval "max_n=\$MAX_FUZZED_HUNKS_$k max_l=\$MAX_FUZZ_LEVEL_$k"
  n=$(stat_field "$PATCH_STATS" "$f" 4)
  l=$(stat_field "$PATCH_STATS" "$f" 5)
  echo "  $f: fuzzed hunks measured=$n ceiling=$max_n; max fuzz level measured=$l ceiling=$max_l"
  assert_eq "yes" "$([ "${n:-99}" -le "$max_n" ] && echo yes || echo no)" \
    "$f: hunks applied with fuzz ($n) within the baseline ($max_n)"
  assert_eq "yes" "$([ "${l:-99}" -le "$max_l" ] && echo yes || echo no)" \
    "$f: highest fuzz level ($l) within the baseline ($max_l)"
done

# Negative: a corrupted COPY of the .c diff (every context line of hunk 1
# altered, so fuzz cannot absorb it) must fail the same check.
BAD="$SCRATCH/bad"
mkdir -p "$BAD"
awk '
  /^@@/ { h++ }
  h == 1 && /^ / { print " CORRUPTED CONTEXT LINE"; next }
  { print }
' "$C_DIFF" > "$BAD/patch_cs8409.c.diff"
assert_ne "$(cksum < "$C_DIFF")" "$(cksum < "$BAD/patch_cs8409.c.diff")" "the corrupted copy differs from the real diff"
fresh_hda "$TARBALL" "$SCRATCH/neg" "$PIN_7X_VERSION"
echo "corrupted copy of patch_cs8409.c.diff (expected to fail):"
assert_exit_nonzero patches_apply_cleanly "$GP" "$SCRATCH/neg/hda" "$BAD/patch_cs8409.c.diff" "$H_DIFF" "$SCRATCH/neg.log"
assert_eq "yes" "$([ "$(stat_field "$PATCH_STATS" "$C_FILE" 6)" -ge 1 ] && echo yes || echo no)" \
  "the corrupted diff reports a FAILED hunk"

# The real patch files were never modified.
assert_eq "$SUMS_BEFORE" "$(cat "$C_DIFF" "$H_DIFF" | cksum)" "the real patch files are untouched"

finish
