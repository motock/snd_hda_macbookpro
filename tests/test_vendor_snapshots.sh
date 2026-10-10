#!/usr/bin/env bash
#
# tests/test_vendor_snapshots.sh -- tools/layout-hash.sh,
# tools/vendor-kernel-sources.sh and the committed vendor/ snapshots.
#
#   L1-L5  layout-hash.sh: stable across checkout locations, sensitive to a
#          closure header, blind to everything outside the include closure,
#          clear failure on a missing closure file or bad usage.
#   V1-V6  vendor-kernel-sources.sh against a fixture tarball (no network; a
#          fake wget serves the fixture): only closure files are extracted,
#          MANIFEST is truthful, bad versions / unsafe members / checksum
#          mismatches are refused and leave nothing behind.
#   D1-D6  the committed data, read offline: MANIFEST hashes match the files,
#          LAYOUT-TABLE parses, ranges do not overlap, every snapshot exists,
#          range hashes equal the snapshot's, 7.0.9 and 7.0.10 are split.

. "$(dirname "$0")/lib/assert.sh"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT" || exit 1

LAYOUT_HASH=tools/layout-hash.sh
VENDOR_TOOL=tools/vendor-kernel-sources.sh

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# make_hda_tree <root> -- a miniature sound/hda with the cs8409 include graph:
#   cs8409.c, cs8409-tables.c -> cs8409.h -> common/{hda_local,hda_jack}.h,
#   codecs/generic.h, codecs/side-codecs/hda_component.h
# plus two files outside the closure.
make_hda_tree() {
  local r=$1
  mkdir -p "$r/codecs/cirrus" "$r/common" "$r/codecs/side-codecs"
  printf '#include "cs8409.h"\n#include "../side-codecs/hda_component.h"\n' > "$r/codecs/cirrus/cs8409.c"
  printf '#include "cs8409.h"\n' > "$r/codecs/cirrus/cs8409-tables.c"
  printf '#include <linux/types.h>\n#include "hda_local.h"\n#include "hda_jack.h"\n#include "../generic.h"\n#include "../side-codecs/hda_component.h"\n' > "$r/codecs/cirrus/cs8409.h"
  printf 'struct hda_local { int a; };\n' > "$r/common/hda_local.h"
  printf 'struct hda_jack { int b; };\n' > "$r/common/hda_jack.h"
  printf '#include "hda_local.h"\nstruct generic { int c; };\n' > "$r/codecs/generic.h"
  printf 'struct hda_component { int d; };\n' > "$r/codecs/side-codecs/hda_component.h"
  printf 'int cs420x;\n' > "$r/codecs/cirrus/cs420x.c"
  printf 'struct unrelated { int e; };\n' > "$r/common/unrelated.h"
}

# --- L: layout-hash.sh --------------------------------------------------------

assert_file_exists "$LAYOUT_HASH" "L0 $LAYOUT_HASH exists"

base=$(make_tmpdir)
make_hda_tree "$base/a/sound/hda"
mkdir -p "$base/elsewhere/deeper"
cp -R "$base/a/sound/hda" "$base/elsewhere/deeper/hda-copy"

h_a=$(bash "$LAYOUT_HASH" "$base/a/sound/hda" 2>/dev/null)
h_copy=$(bash "$LAYOUT_HASH" "$base/elsewhere/deeper/hda-copy" 2>/dev/null)
assert_eq 1 "$(printf '%s' "$h_a" | grep -Ec '^[0-9a-f]{64}$')" "L1 prints exactly one sha256"
assert_eq "$h_a" "$h_copy" "L1 hash is independent of the checkout location"
assert_eq "$h_a" "$(bash "$LAYOUT_HASH" "$base/a/sound/hda" 2>/dev/null)" "L1 hash is deterministic"

printf 'struct hda_jack { int B; };\n' > "$base/elsewhere/deeper/hda-copy/common/hda_jack.h"
h_changed=$(bash "$LAYOUT_HASH" "$base/elsewhere/deeper/hda-copy" 2>/dev/null)
assert_ne "$h_a" "$h_changed" "L2 hash changes when a closure header changes by one byte"

printf 'struct unrelated { int zzz; };\n' > "$base/a/sound/hda/common/unrelated.h"
printf 'int other_codec;\n' > "$base/a/sound/hda/codecs/cirrus/cs421x.c"
assert_eq "$h_a" "$(bash "$LAYOUT_HASH" "$base/a/sound/hda" 2>/dev/null)" "L3 hash ignores files outside the include closure"

printf 'int cs8409_body_changed;\n' >> "$base/a/sound/hda/codecs/cirrus/cs8409.c"
assert_eq "$h_a" "$(bash "$LAYOUT_HASH" "$base/a/sound/hda" 2>/dev/null)" "L3 hash ignores .c bodies (headers only)"

rm "$base/a/sound/hda/codecs/side-codecs/hda_component.h"
out=$(bash "$LAYOUT_HASH" "$base/a/sound/hda" 2>&1)
rc=$?
assert_ne 0 "$rc" "L4 missing closure file exits non-zero"
assert_contains "$out" "hda_component.h" "L4 the message names the missing file"

assert_exit_nonzero bash "$LAYOUT_HASH" "$base/does-not-exist" 2>/dev/null
assert_exit_nonzero bash "$LAYOUT_HASH" 2>/dev/null

# --- V: vendor-kernel-sources.sh ------------------------------------------------

assert_file_exists "$VENDOR_TOOL" "V0 $VENDOR_TOOL exists"

fx=$(make_tmpdir)           # fixture world: tarballs + fake wget
mkdir -p "$fx/bin" "$fx/serve" "$fx/cache"
cat > "$fx/bin/wget" <<'FAKE'
#!/bin/bash
# fake wget: `wget [-q] -O <dest> <url>` serves $FAKE_SERVE/<basename of url>
dest=""; url=""
while [ $# -gt 0 ]; do
  case $1 in
    -O) dest=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
src="$FAKE_SERVE/${url##*/}"
[ -f "$src" ] || exit 8
cp "$src" "$dest"
FAKE
chmod +x "$fx/bin/wget"

# good fixture: linux-9.9 with the mini tree plus a file outside sound/hda
good="$fx/src/linux-9.9"
make_hda_tree "$good/sound/hda"
printf 'all:\n' > "$good/Makefile"
tar -C "$fx/src" -cJf "$fx/serve/linux-9.9.tar.xz" linux-9.9
printf '%s  linux-9.9.tar.xz\n' "$(sha_of "$fx/serve/linux-9.9.tar.xz")" > "$fx/serve/sha256sums.asc"

run_vendor() {   # run_vendor <out> <args...>
  local out=$1; shift
  PATH="$fx/bin:$PATH" FAKE_SERVE="$fx/serve" HDA_VENDOR_CACHE="$fx/cache" \
    HDA_KERNEL_MIRROR="http://mirror.invalid/v9.x" \
    bash "$VENDOR_TOOL" "$@" --out "$out" 2>&1
}

out1="$fx/out1"
msg=$(run_vendor "$out1" 9.9)
rc=$?
assert_eq 0 "$rc" "V1 vendoring the fixture succeeds ($msg)"
snap="$out1/linux-9.9"
files=$(cd "$snap" 2>/dev/null && find . -type f ! -name MANIFEST | LC_ALL=C sort)
expected_files=$(printf '%s\n' \
  ./sound/hda/codecs/cirrus/cs8409-tables.c ./sound/hda/codecs/cirrus/cs8409.c \
  ./sound/hda/codecs/cirrus/cs8409.h ./sound/hda/codecs/generic.h \
  ./sound/hda/codecs/side-codecs/hda_component.h \
  ./sound/hda/common/hda_jack.h ./sound/hda/common/hda_local.h)
assert_eq "$expected_files" "$files" "V2 only the include-closure files are extracted"
assert_file_exists "$snap/MANIFEST" "V3 MANIFEST is written"
manifest=$(cat "$snap/MANIFEST" 2>/dev/null)
assert_contains "$manifest" "linux-9.9.tar.xz" "V3 MANIFEST names the tarball"
assert_contains "$manifest" "$(sha_of "$fx/serve/linux-9.9.tar.xz")" "V3 MANIFEST records the verified tarball sha256"
assert_contains "$manifest" "$(bash "$LAYOUT_HASH" "$snap/sound/hda" 2>/dev/null)" "V3 MANIFEST records the layout hash"
bad=0
while read -r hash path; do
  [ "${#hash}" -eq 64 ] || continue
  [ "$(sha_of "$snap/$path")" = "$hash" ] || bad=$((bad + 1))
done < <(grep -E '^[0-9a-f]{64}  sound/' "$snap/MANIFEST")
assert_eq 0 "$bad" "V3 every MANIFEST file hash matches"
assert_eq 7 "$(grep -Ec '^[0-9a-f]{64}  sound/' "$snap/MANIFEST")" "V3 MANIFEST lists exactly the extracted files"

out2="$fx/out2"
for v in "abc" "9" "9.9.9.9" "9.9;id" "../9.9" "9.9-rc1" ""; do
  run_vendor "$out2" "$v" >/dev/null
  assert_ne 0 "$?" "V4 rejects version '$v'"
done
assert_eq "" "$(ls -A "$out2" 2>/dev/null)" "V4 rejected versions create nothing"

# unsafe member: linux-9.8/../escape
python3 -I - "$fx/serve/linux-9.8.tar.xz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:xz") as t:
    for name in ("linux-9.8/sound/hda/codecs/cirrus/cs8409.c", "linux-9.8/../escape"):
        data = b"x\n"
        info = tarfile.TarInfo(name)
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
PY
printf '%s  linux-9.8.tar.xz\n' "$(sha_of "$fx/serve/linux-9.8.tar.xz")" >> "$fx/serve/sha256sums.asc"
out3="$fx/out3"
msg=$(run_vendor "$out3" 9.8)
assert_ne 0 "$?" "V5 rejects a tarball member containing '..'"
assert_contains "$msg" ".." "V5 the message mentions the unsafe member"
assert_eq "" "$(ls -A "$out3" 2>/dev/null)" "V5 nothing is left in the output dir"
assert_eq "no" "$([ -e "$fx/escape" ] && echo yes || echo no)" "V5 nothing escaped the extraction dir"

# checksum mismatch: published sum differs from the served tarball
cp "$fx/serve/linux-9.9.tar.xz" "$fx/serve/linux-9.7.tar.xz"
printf '%s  linux-9.7.tar.xz\n' "$(printf 'wrong' | shasum -a 256 | cut -d' ' -f1)" >> "$fx/serve/sha256sums.asc"
out4="$fx/out4"
msg=$(run_vendor "$out4" 9.7)
assert_ne 0 "$?" "V6 fails closed on a checksum mismatch"
assert_contains "$msg" "mismatch" "V6 the message says mismatch"
assert_eq "" "$(ls -A "$out4" 2>/dev/null)" "V6 nothing is left in the output dir"
assert_eq "no" "$([ -e "$fx/cache/tarballs/linux-9.7.tar.xz" ] && echo yes || echo no)" "V6 the bad tarball is not kept in the cache"

# a pre-seeded cache copy is still verified (verification is never skipped)
mkdir -p "$fx/cache/tarballs"
printf 'poisoned' > "$fx/cache/tarballs/linux-9.9.tar.xz"
out5="$fx/out5"
run_vendor "$out5" 9.9 >/dev/null
assert_ne 0 "$?" "V6 a poisoned cached tarball is rejected, not trusted"
assert_eq "" "$(ls -A "$out5" 2>/dev/null)" "V6 nothing is left after a poisoned cache hit"

# --- D: committed data ----------------------------------------------------------

TABLE=vendor/LAYOUT-TABLE
assert_file_exists "$TABLE" "D0 $TABLE exists"
assert_file_exists vendor/README.md "D0 vendor/README.md exists"

snapshots=$(ls -d vendor/linux-*/ 2>/dev/null)
assert_ne "" "$snapshots" "D1 at least one snapshot is committed"

for want in linux-7.0 linux-7.0.14 linux-6.17.13 linux-7.1.13; do
  assert_file_exists "vendor/$want/MANIFEST" "D1 snapshot $want is committed"
done

for d in $snapshots; do
  d=${d%/}
  bad=0
  while read -r hash path; do
    [ "$(sha_of "$d/$path" 2>/dev/null)" = "$hash" ] || bad=$((bad + 1))
  done < <(grep -E '^[0-9a-f]{64}  sound/' "$d/MANIFEST")
  assert_eq 0 "$bad" "D2 every MANIFEST hash matches the files in $d"
  recorded=$(sed -n 's/^layout-hash  *//p' "$d/MANIFEST")
  assert_eq "$recorded" "$(bash "$LAYOUT_HASH" "$d/sound/hda" 2>/dev/null)" "D2 recorded layout hash of $d matches a recomputation"
done

# table rows: first last snapshot hash
rows=$(sed -e 's/#.*//' "$TABLE" | awk 'NF { print }')
assert_ne "" "$rows" "D3 LAYOUT-TABLE has data rows"
assert_eq "" "$(printf '%s\n' "$rows" | awk 'NF != 4')" "D3 every row has exactly four fields"
assert_eq "" "$(printf '%s\n' "$rows" | awk '$4 !~ /^[0-9a-f]{64}$/ || $1 !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/ || $2 !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/')" "D3 versions and hashes are well formed"

# vkey 7.0.9 -> 7000009 (a bare 7.0 is 7.0.0)
vkey() { printf '%s' "$1" | awk -F. '{ printf "%d", $1 * 1000000 + $2 * 1000 + $3 }'; }
series() { printf '%s' "$1" | cut -d. -f1,2; }

n=0
while read -r first last name hash; do
  n=$((n + 1))
  f[$n]=$(vkey "$first"); l[$n]=$(vkey "$last"); s[$n]=$(series "$first"); sl[$n]=$(series "$last")
  assert_eq "${s[$n]}" "${sl[$n]}" "D4 range $first..$last stays within one series"
  assert_eq 1 "$([ "${f[$n]}" -le "${l[$n]}" ] && echo 1 || echo 0)" "D4 range $first..$last is ordered"
  assert_file_exists "vendor/$name/MANIFEST" "D5 snapshot $name named by the table exists"
  assert_eq "$(sed -n 's/^layout-hash  *//p' "vendor/$name/MANIFEST" 2>/dev/null)" "$hash" "D6 range $first..$last hash equals snapshot $name's"
done < <(printf '%s\n' "$rows")

overlaps=0
for ((i = 1; i <= n; i++)); do
  for ((j = i + 1; j <= n; j++)); do
    [ "${s[$i]}" = "${s[$j]}" ] || continue
    if [ "${f[$i]}" -le "${l[$j]}" ] && [ "${f[$j]}" -le "${l[$i]}" ]; then
      overlaps=$((overlaps + 1))
    fi
  done
done
assert_eq 0 "$overlaps" "D4 ranges within a series do not overlap"

# row_for <version> -- print the snapshot name whose range covers it
row_for() {
  local k
  k=$(vkey "$1")
  printf '%s\n' "$rows" | awk -v k="$k" -v v="$1" '
    function key(x,  p) { split(x, p, "."); return p[1] * 1000000 + p[2] * 1000 + p[3] }
    key($1) <= k && k <= key($2) { print $3 }'
}
assert_ne "" "$(row_for 7.0.9)" "D7 7.0.9 is covered"
assert_ne "" "$(row_for 7.0.10)" "D7 7.0.10 is covered"
assert_ne "$(row_for 7.0.9)" "$(row_for 7.0.10)" "D7 7.0.9 and 7.0.10 fall in different ranges (struct hda_multi_out changed)"
assert_eq "" "$(row_for 7.0.15)" "D7 a version past the last range is not covered"

kb=$(du -sk vendor | cut -f1)
printf 'vendor/ size: %s KiB\n' "$kb"
assert_eq 1 "$([ "$kb" -lt 2048 ] && echo 1 || echo 0)" "D8 vendor/ is under 2 MB (got ${kb} KiB)"

finish
