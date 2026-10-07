#!/usr/bin/env bash
#
# tests/test_kernel_cache.sh
#
# Tests for the kernel-source cache helper:
#
#   * tests/lib/kernel_cache.sh  -- a sourced shell library
#   * tests/kernel-pins.conf     -- the pinned kernel versions and sha256s
#   * a short kernel-cache section appended at the END of tests/README
#
# ---------------------------------------------------------------------------
# CONTRACT UNDER TEST.  This block is the specification for the helper.
# ---------------------------------------------------------------------------
# Sourcing tests/lib/kernel_cache.sh exposes:
#
#   kernel_tree_for new|old
#       Prints the path of the pristine extracted kernel tree, exit 0.
#       Prints no path, exit 77, when the tree is not cached and cannot be
#       downloaded (the caller should skip).
#       Every other failure -- bad arguments, checksum mismatch, unreadable
#       pins -- is a hard error: non-zero and NOT 77.
#
#   kernel_tree_copy new|old destdir
#       Copies the pristine tree to destdir (created if missing) so a test
#       can mutate the copy.  Never mutates the cached pristine tree.
#
# Environment knobs:
#
#   HDA_TEST_CACHE    cache root, created on demand.  Default
#                     ${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-tests
#                     -- outside the repository.
#   HDA_KERNEL_PINS   path of the pins file.  Default: the kernel-pins.conf
#                     sitting next to the library (not relative to the cwd).
#   HDA_KERNEL_MIRROR directory URL the tarball is fetched from:
#                     url = $HDA_KERNEL_MIRROR/$PIN_<X>_TARBALL
#                     Default: https://cdn.kernel.org/pub/linux/kernel/v6.x
#
# The pins file is a sourced shell file defining, for X in NEW and OLD:
#
#   PIN_X_VERSION    dotted version (NEW >= 6.17, OLD < 6.17)
#   PIN_X_TARBALL    linux-<version>.tar.xz -- the name the installers fetch
#   PIN_X_SHA256     kernel.org's sha256 for that tarball, 64 lowercase hex
#
# Behaviour:
#   * The tarball is checksum-verified (sha256sum, or shasum -a 256 on macOS).
#     A mismatch is a hard error (non-zero, not 77 -- even when a re-download
#     could be attempted), the offending file is deleted, and the error names
#     the expected and the actual hash, at least their first 8 hex characters.
#   * Only the subtrees the installers extract are unpacked: sound/pci/hda for
#     the old pin, plus sound/hda for the new pin.  Nothing else is extracted.
#     The printed path is the kernel tree root, so $tree/sound/pci/hda exists.
#   * The verified tarball is kept in the cache and re-verified when the tree
#     is missing, so a corrupted cached tarball fails hard.
#   * The helper writes only inside the cache root, never inside the repo.
#
# No test here touches the network: downloads use file:// URLs, curl/wget in
# PATH are replaced by a stub that only copies local files, and http(s)
# proxies point at a closed local port so even a stray https download fails
# instead of reaching kernel.org.
#
# Exit codes: 0 = pass, 1 = fail, 77 = skip.

set -u

HDA_TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HDA_TEST_DIR/.." && pwd)
LIB="$HDA_TEST_DIR/lib/kernel_cache.sh"
PINS_CONF="$HDA_TEST_DIR/kernel-pins.conf"
README="$HDA_TEST_DIR/README"

. "$HDA_TEST_DIR/lib/assert.sh"

SCRATCH=$(make_tmpdir)
ERRF="$SCRATCH/stderr"

# Belt and braces: any accidental http(s) request dies on a closed local port.
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
export HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# version_ge <a> <b> -- exit 0 when dotted-numeric version a >= b.
version_ge() {
  _i=1
  while [ "$_i" -le 4 ]; do
    _x=$(printf '%s' "$1" | cut -d. -f"$_i")
    _y=$(printf '%s' "$2" | cut -d. -f"$_i")
    case "$_x" in '' | *[!0-9]* ) _x=0 ;; esac
    case "$_y" in '' | *[!0-9]* ) _y=0 ;; esac
    [ "$_x" -gt "$_y" ] && return 0
    [ "$_x" -lt "$_y" ] && return 1
    _i=$((_i + 1))
  done
  return 0
}

# test_sha256 <file> -- print the file's sha256 (sha256sum or shasum -a 256).
test_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# cache_files_with_sha <dir> <sha> -- print every file under <dir> whose
# sha256 is <sha>.  Locating the cached tarball by content keeps these tests
# independent of how the helper lays out its cache.
cache_files_with_sha() {
  find "$1" -type f -print 2>/dev/null |
  while IFS= read -r _f || [ -n "$_f" ]; do
    [ -f "$_f" ] || continue
    [ "$(test_sha256 "$_f")" = "$2" ] && printf '%s\n' "$_f"
  done
}

# make_fake_kernel <version> -- build $MIRROR/linux-<version>.tar.xz holding
# the subtrees the installers extract plus decoy files that must NOT appear.
make_fake_kernel() {
  _root="$MIRROR/linux-$1"
  mkdir -p "$_root/sound/pci/hda" "$_root/sound/hda" "$_root/mm" || return 1
  printf 'pci-hda marker %s\n' "$1" > "$_root/sound/pci/hda/patch_cirrus.c"
  printf 'hda marker %s\n' "$1" > "$_root/sound/hda/hda_bus_type.c"
  printf 'decoy\n' > "$_root/README"
  printf 'decoy\n' > "$_root/mm/Makefile"
  printf 'decoy\n' > "$_root/sound/Makefile"
  printf 'decoy\n' > "$_root/sound/pci/Makefile"
  ( cd "$MIRROR" && tar -cJf "linux-$1.tar.xz" "linux-$1" ) || return 1
}

# write_pins <file> <new_ver> <new_sha> <old_ver> <old_sha>
write_pins() {
  {
    printf 'PIN_NEW_VERSION="%s"\n' "$2"
    printf 'PIN_NEW_TARBALL="linux-%s.tar.xz"\n' "$2"
    printf 'PIN_NEW_SHA256="%s"\n' "$3"
    printf 'PIN_OLD_VERSION="%s"\n' "$4"
    printf 'PIN_OLD_TARBALL="linux-%s.tar.xz"\n' "$4"
    printf 'PIN_OLD_SHA256="%s"\n' "$5"
  } > "$1"
}

# Fake curl/wget: serve file:// URLs from the local filesystem.  A missing
# source file fails, which is how these tests simulate an unreachable network.
make_downloader_stubs() {
  mkdir -p "$SCRATCH/bin"
  cat > "$SCRATCH/bin/curl" <<'STUB'
#!/usr/bin/env bash
url= out= outdir= remote=0
while [ $# -gt 0 ]; do
  case "$1" in
    *://*) url=$1 ;;
    -o|--output) out=$2; shift ;;
    --output=*) out=${1#--output=} ;;
    -O|--remote-name|--output-document)
      if [ $# -ge 2 ] && [ "${2#*://}" = "$2" ]; then out=$2; shift; else remote=1; fi ;;
    --output-document=*) out=${1#--output-document=} ;;
    -P|--directory-prefix) outdir=$2; shift ;;
    --directory-prefix=*) outdir=${1#--directory-prefix=} ;;
    -*) ;;  # any other flag, and any value it carries, is ignored
  esac
  shift
done
if [ -z "$url" ]; then
  echo "download stub: no URL in the arguments" >&2
  exit 1
fi
src=${url#file://}
if [ ! -f "$src" ]; then
  echo "download stub: $url unreachable (simulated network failure)" >&2
  exit 1
fi
if [ -n "$out" ] && [ "$out" != "-" ]; then
  mkdir -p "$(dirname "$out")" 2>/dev/null
  cat "$src" > "$out" || exit 1
elif [ -n "$outdir" ]; then
  mkdir -p "$outdir" 2>/dev/null
  cat "$src" > "$outdir/$(basename "$url")" || exit 1
elif [ "$remote" = 1 ]; then
  cat "$src" > "$(basename "$url")" || exit 1
elif [ -n "$out" ]; then
  cat "$src"    # -o -: stdout
elif [ "$(basename "$0")" = wget ]; then
  cat "$src" > "$(basename "$url")" || exit 1
else
  cat "$src"    # curl with no -o writes to stdout
fi
exit 0
STUB
  cp "$SCRATCH/bin/curl" "$SCRATCH/bin/wget"
  chmod +x "$SCRATCH/bin/curl" "$SCRATCH/bin/wget"
}

# run_lib <snippet> -- run the snippet in a fresh bash with the library sourced
# first.  Sets RUN_OUT (stdout), RUN_ERR (stderr), RUN_RC (exit status).
run_lib() {
  : > "$ERRF"
  RUN_OUT=$(bash -c '. "$0"; eval "$1"' "$LIB" "$1" 2>"$ERRF")
  RUN_RC=$?
  RUN_ERR=$(cat "$ERRF" 2>/dev/null)
}

# run_lib_in <dir> <snippet> -- run_lib with the child's working directory
# set to <dir>.
run_lib_in() {
  : > "$ERRF"
  RUN_OUT=$( cd "$1" && bash -c '. "$0"; eval "$1"' "$LIB" "$2" 2>"$ERRF" )
  RUN_RC=$?
  RUN_ERR=$(cat "$ERRF" 2>/dev/null)
}

# point <cache> <pins> <mirror> -- aim the helper at a scenario.
point() {
  HDA_TEST_CACHE=$1
  HDA_KERNEL_PINS=$2
  HDA_KERNEL_MIRROR=$3
  export HDA_TEST_CACHE HDA_KERNEL_PINS HDA_KERNEL_MIRROR
}

repo_status() { git -C "$REPO_ROOT" status --porcelain 2>/dev/null || echo git-unavailable; }

STATUS_BEFORE=$(repo_status)

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

make_downloader_stubs
export PATH="$SCRATCH/bin:$PATH"

MIRROR="$SCRATCH/mirror"
mkdir -p "$MIRROR"

NEW_VER=9.9.9    # >= 6.17, so a version-driven helper treats it as "new"
OLD_VER=6.16.6   # < 6.17, so a version-driven helper treats it as "old"
NEW_TARBALL="linux-$NEW_VER.tar.xz"
OLD_TARBALL="linux-$OLD_VER.tar.xz"
make_fake_kernel "$NEW_VER" || skip "tar cannot create xz archives here (is xz installed?); cannot exercise the kernel cache"
make_fake_kernel "$OLD_VER" || skip "cannot build the fake old kernel tarball"
NEW_SHA=$(test_sha256 "$MIRROR/$NEW_TARBALL")
OLD_SHA=$(test_sha256 "$MIRROR/$OLD_TARBALL")
[ -n "$NEW_SHA" ] && [ -n "$OLD_SHA" ] || skip "no sha256 tool available"

GOOD_PINS="$SCRATCH/pins-good.conf"
write_pins "$GOOD_PINS" "$NEW_VER" "$NEW_SHA" "$OLD_VER" "$OLD_SHA"

# A pin whose sha256 does not match the tarball.  It differs from the real
# hash in its first character, so the two 8-character prefixes are distinct.
_first=${NEW_SHA%"${NEW_SHA#?}"}
if [ "$_first" = "0" ]; then _first=1; else _first=0; fi
BAD_SHA="$_first${NEW_SHA#?}"
BAD_PINS="$SCRATCH/pins-bad.conf"
write_pins "$BAD_PINS" "$NEW_VER" "$BAD_SHA" "$OLD_VER" "$OLD_SHA"
BAD_PREFIX=${BAD_SHA:0:8}
REAL_PREFIX=${NEW_SHA:0:8}

# ---------------------------------------------------------------------------
# the artifacts exist
# ---------------------------------------------------------------------------

assert_file_exists "$LIB" "tests/lib/kernel_cache.sh exists"
assert_file_exists "$PINS_CONF" "tests/kernel-pins.conf exists"

# --- tests/kernel-pins.conf: the two pins ---------------------------------
if [ -f "$PINS_CONF" ]; then
  _pins_rc=0
  . "$PINS_CONF" || _pins_rc=$?
  assert_eq 0 "$_pins_rc" "tests/kernel-pins.conf is a sourceable shell file"
  assert_ne "" "${PIN_NEW_VERSION:-}" "kernel-pins.conf defines PIN_NEW_VERSION"
  assert_ne "" "${PIN_NEW_TARBALL:-}" "kernel-pins.conf defines PIN_NEW_TARBALL"
  assert_ne "" "${PIN_NEW_SHA256:-}" "kernel-pins.conf defines PIN_NEW_SHA256"
  assert_ne "" "${PIN_OLD_VERSION:-}" "kernel-pins.conf defines PIN_OLD_VERSION"
  assert_ne "" "${PIN_OLD_TARBALL:-}" "kernel-pins.conf defines PIN_OLD_TARBALL"
  assert_ne "" "${PIN_OLD_SHA256:-}" "kernel-pins.conf defines PIN_OLD_SHA256"
  if [ -n "${PIN_NEW_VERSION:-}" ] && [ -n "${PIN_NEW_TARBALL:-}" ] &&
     [ -n "${PIN_OLD_VERSION:-}" ] && [ -n "${PIN_OLD_TARBALL:-}" ]; then
    assert_eq "yes" "$(version_ge "$PIN_NEW_VERSION" 6.17 && echo yes || echo no)" \
      "PIN_NEW_VERSION ($PIN_NEW_VERSION) is 6.17 or newer"
    assert_eq "no" "$(version_ge "$PIN_OLD_VERSION" 6.17 && echo yes || echo no)" \
      "PIN_OLD_VERSION ($PIN_OLD_VERSION) is older than 6.17"
    assert_eq "linux-$PIN_NEW_VERSION.tar.xz" "$PIN_NEW_TARBALL" \
      "PIN_NEW_TARBALL is the linux-<version>.tar.xz name the installers download"
    assert_eq "linux-$PIN_OLD_VERSION.tar.xz" "$PIN_OLD_TARBALL" \
      "PIN_OLD_TARBALL is the linux-<version>.tar.xz name the installers download"
  fi
  if [ -n "${PIN_NEW_SHA256:-}" ] && [ -n "${PIN_OLD_SHA256:-}" ]; then
    [[ "$PIN_NEW_SHA256" =~ ^[0-9a-f]{64}$ ]] && _h=yes || _h=no
    assert_eq "yes" "$_h" "PIN_NEW_SHA256 is 64 lowercase hex characters (kernel.org sha256sums.asc format)"
    [[ "$PIN_OLD_SHA256" =~ ^[0-9a-f]{64}$ ]] && _h=yes || _h=no
    assert_eq "yes" "$_h" "PIN_OLD_SHA256 is 64 lowercase hex characters (kernel.org sha256sums.asc format)"
    assert_ne "$PIN_NEW_SHA256" "$PIN_OLD_SHA256" "the two pins record distinct sha256 values"
  fi
fi

# --- tests/README: a kernel-cache section appended at the end --------------
if [ -f "$README" ]; then
  _anchor=$(grep -n 'Manual hardware tests' "$README" | tail -1 | cut -d: -f1)
  _tokline=$(grep -n -E 'kernel_cache|kernel_tree|kernel-pins' "$README" | tail -1 | cut -d: -f1)
  assert_ne "" "${_tokline:-}" \
    "tests/README documents the kernel cache helper (names kernel_cache, kernel_tree_* or kernel-pins)"
  if [ -n "${_tokline:-}" ]; then
    if [ -n "${_anchor:-}" ]; then
      assert_eq "yes" "$( [ "$_tokline" -gt "$_anchor" ] && echo yes || echo no)" \
        "the kernel cache section is appended at the END of tests/README, after the previous last section"
    else
      _total=$(wc -l < "$README" | tr -d ' ')
      _from=$((_total - 59)); [ "$_from" -lt 1 ] && _from=1
      assert_contains "$(sed -n "${_from},${_total}p" "$README")" "kernel" \
        "the kernel cache section sits at the end of tests/README"
    fi
  fi
else
  assert_file_exists "$README" "tests/README exists"
fi

if [ ! -f "$LIB" ]; then
  # Every remaining case needs the library; report what is missing and stop.
  finish
fi

# ---------------------------------------------------------------------------
# kernel_tree_for: the good path
# ---------------------------------------------------------------------------

CACHE="$SCRATCH/cache-main"          # deliberately not created yet
point "$CACHE" "$GOOD_PINS" "file://$MIRROR"

run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "kernel_tree_for new succeeds when the tarball is available"
assert_file_exists "$CACHE" "kernel_tree_for creates the cache root when it is missing"
NEW_TREE=$RUN_OUT
assert_ne "" "$NEW_TREE" "kernel_tree_for new prints the tree path"
assert_eq "1" "$(printf '%s\n' "$NEW_TREE" | wc -l | tr -d ' ')" \
  "kernel_tree_for new prints only the tree path on stdout"
assert_file_exists "$NEW_TREE" "the printed new tree path exists"
if [ -d "$NEW_TREE" ]; then
  CACHE_CANON=$(cd "$CACHE" && pwd)
  case "$NEW_TREE" in
    "$CACHE"/* | "$CACHE_CANON"/*) _inside=yes ;;
    *) _inside=no ;;
  esac
  assert_eq "yes" "$_inside" "the extracted tree is stored under the cache root"
  assert_file_exists "$NEW_TREE/sound/pci/hda/patch_cirrus.c" "the new tree contains sound/pci/hda"
  assert_file_exists "$NEW_TREE/sound/hda/hda_bus_type.c" "the new tree also contains sound/hda"
  assert_contains "$(cat "$NEW_TREE/sound/pci/hda/patch_cirrus.c" 2>/dev/null)" "pci-hda marker $NEW_VER" \
    "the extracted sound/pci/hda files come from the pinned tarball"
  _decoys=yes
  for _p in README mm/Makefile sound/Makefile sound/pci/Makefile; do
    [ -e "$NEW_TREE/$_p" ] && _decoys="no ($NEW_TREE/$_p was extracted)"
  done
  assert_eq "yes" "$_decoys" \
    "the new tree holds only the sound/pci/hda and sound/hda subtrees, not the whole kernel"
fi
assert_ne "" "$(cache_files_with_sha "$CACHE" "$NEW_SHA")" \
  "the verified tarball is kept in the cache after extraction"

run_lib 'kernel_tree_for old'
assert_eq 0 "$RUN_RC" "kernel_tree_for old succeeds when the tarball is available"
OLD_TREE=$RUN_OUT
assert_file_exists "$OLD_TREE/sound/pci/hda/patch_cirrus.c" "the old tree contains sound/pci/hda"
assert_contains "$(cat "$OLD_TREE/sound/pci/hda/patch_cirrus.c" 2>/dev/null)" "pci-hda marker $OLD_VER" \
  "the old tree holds the files of the old pin, not the new one"
assert_eq "no" "$( [ -e "$OLD_TREE/sound/hda/hda_bus_type.c" ] && echo yes || echo no)" \
  "the old tree does not extract sound/hda (the pre-6.17 installer does not use it)"
assert_ne "$NEW_TREE" "$OLD_TREE" "the new and old pins have separate trees in one cache"

# Idempotent: safe to run twice.
run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "kernel_tree_for new is safe to run twice"
assert_eq "$NEW_TREE" "$RUN_OUT" "kernel_tree_for new is idempotent (same tree path)"
assert_file_exists "$NEW_TREE/sound/pci/hda/patch_cirrus.c" "the tree survives a second run"

# Works from any working directory.
point "$SCRATCH/cache-cwd" "$GOOD_PINS" "file://$MIRROR"
run_lib_in "$SCRATCH" 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "kernel_tree_for works from a different working directory"

# ---------------------------------------------------------------------------
# a checksum mismatch is rejected
# ---------------------------------------------------------------------------

point "$SCRATCH/cache-bad" "$BAD_PINS" "file://$MIRROR"
run_lib 'kernel_tree_for new'
_bad=ok
[ "$RUN_RC" -eq 0 ] && _bad="exit 0"
[ "$RUN_RC" -eq 77 ] && _bad="77 (skip)"
assert_eq "ok" "$_bad" "a tarball whose sha256 does not match the pin is a hard failure, not a pass and not a skip"
assert_contains "$RUN_OUT$RUN_ERR" "$BAD_PREFIX" "the mismatch error names the expected hash prefix"
assert_contains "$RUN_OUT$RUN_ERR" "$REAL_PREFIX" "the mismatch error names the actual hash prefix"
assert_eq "" "$(cache_files_with_sha "$SCRATCH/cache-bad" "$NEW_SHA")" \
  "the tarball that failed verification is deleted from the cache"
assert_eq "" "$(find "$SCRATCH/cache-bad" -name patch_cirrus.c 2>/dev/null)" \
  "no partially extracted tree is left behind by a failed verification"

# ---------------------------------------------------------------------------
# a corrupted cached tarball is rejected
# ---------------------------------------------------------------------------

point "$SCRATCH/cache-corrupt" "$GOOD_PINS" "file://$MIRROR"
run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "the cache is populated before corrupting it"
CORRUPT_TREE=$RUN_OUT
CACHED_TARBALL=$(cache_files_with_sha "$SCRATCH/cache-corrupt" "$NEW_SHA" | head -1)
assert_ne "" "$CACHED_TARBALL" "the verified tarball is kept in the cache under the cache root"
if [ -n "$CACHED_TARBALL" ]; then
  rm -rf "$CORRUPT_TREE"                  # as if extraction never happened
  printf 'corrupted on purpose\n' > "$CACHED_TARBALL"
  CORRUPT_SHA=$(test_sha256 "$CACHED_TARBALL")
  point "$SCRATCH/cache-corrupt" "$GOOD_PINS" "file://$SCRATCH/no-such-mirror"
  run_lib 'kernel_tree_for new'
  _bad=ok
  [ "$RUN_RC" -eq 0 ] && _bad="exit 0"
  [ "$RUN_RC" -eq 77 ] && _bad="77 (skip)"
  assert_eq "ok" "$_bad" \
    "a corrupted cached tarball is a hard failure (non-zero, not 77), never silently reused and never a skip"
  assert_contains "$RUN_OUT$RUN_ERR" "$REAL_PREFIX" "the corruption error names the expected hash prefix"
  assert_contains "$RUN_OUT$RUN_ERR" "${CORRUPT_SHA:0:8}" "the corruption error names the actual hash prefix"
  assert_eq "" "$(cache_files_with_sha "$SCRATCH/cache-corrupt" "$CORRUPT_SHA")" \
    "the corrupted tarball is deleted from the cache"
fi

# ---------------------------------------------------------------------------
# offline: empty cache skips, populated cache is reused
# ---------------------------------------------------------------------------

point "$SCRATCH/cache-offline" "$GOOD_PINS" "file://$SCRATCH/no-such-mirror"
run_lib 'kernel_tree_for new'
assert_eq 77 "$RUN_RC" "kernel_tree_for new returns 77 (skip) when the tree is unavailable and the network is down"
assert_eq "" "$RUN_OUT" "kernel_tree_for prints no tree path when it skips"
run_lib 'kernel_tree_for old'
assert_eq 77 "$RUN_RC" "kernel_tree_for old also returns 77 when offline with an empty cache"

point "$SCRATCH/cache-offline" "$GOOD_PINS" "file://$MIRROR"
run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "the cache is populated for the offline-reuse case"
REUSE_TREE=$RUN_OUT
point "$SCRATCH/cache-offline" "$GOOD_PINS" "file://$SCRATCH/no-such-mirror"
run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "a cached tree is served without the network"
assert_eq "$REUSE_TREE" "$RUN_OUT" "the offline run reuses the same cached tree"

# The default pins file is the kernel-pins.conf next to the library.
if [ -f "$PINS_CONF" ]; then
  unset HDA_KERNEL_PINS
  point "$SCRATCH/cache-default-pins" "$PINS_CONF" "file://$SCRATCH/no-such-mirror"
  unset HDA_KERNEL_PINS
  run_lib 'kernel_tree_for new'
  assert_eq 77 "$RUN_RC" "with the default pins file and no network, kernel_tree_for new skips (77)"
  run_lib 'kernel_tree_for old'
  assert_eq 77 "$RUN_RC" "with the default pins file and no network, kernel_tree_for old skips (77)"
fi

# ---------------------------------------------------------------------------
# kernel_tree_copy
# ---------------------------------------------------------------------------

point "$SCRATCH/cache-copy" "$GOOD_PINS" "file://$MIRROR"
run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "the cache is populated for the copy test"
PRISTINE=$RUN_OUT
COPY="$SCRATCH/tree-copy"
run_lib "kernel_tree_copy new '$COPY'"
assert_eq 0 "$RUN_RC" "kernel_tree_copy new succeeds"
assert_file_exists "$COPY/sound/pci/hda/patch_cirrus.c" \
  "kernel_tree_copy creates destdir and copies the sound/pci/hda subtree into it"
assert_file_exists "$COPY/sound/hda/hda_bus_type.c" \
  "kernel_tree_copy new copies the sound/hda subtree too"

COPY_OLD="$SCRATCH/tree-copy-old"
run_lib "kernel_tree_copy old '$COPY_OLD'"
assert_eq 0 "$RUN_RC" "kernel_tree_copy old succeeds"
assert_file_exists "$COPY_OLD/sound/pci/hda/patch_cirrus.c" \
  "kernel_tree_copy old copies the sound/pci/hda subtree"

# Mutating the copy must not touch the pristine cached tree.
printf 'mutated by a test\n' > "$COPY/sound/pci/hda/patch_cirrus.c"
printf 'extra file\n' > "$COPY/sound/pci/hda/extra_file.c"
run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "kernel_tree_for still works after the copy was mutated"
assert_contains "$(cat "$PRISTINE/sound/pci/hda/patch_cirrus.c" 2>/dev/null)" "pci-hda marker $NEW_VER" \
  "the pristine cached tree is unchanged after mutating the copy"
assert_eq "no" "$( [ -e "$PRISTINE/sound/pci/hda/extra_file.c" ] && echo yes || echo no)" \
  "files added to the copy do not leak into the pristine cached tree"

# Negative and boundary cases.
run_lib "kernel_tree_copy bogus '$SCRATCH/never'"
assert_ne 0 "$RUN_RC" "kernel_tree_copy rejects an unknown pin"
run_lib 'kernel_tree_copy new'
assert_ne 0 "$RUN_RC" "kernel_tree_copy requires a destination argument"
run_lib 'kernel_tree_for bogus'
assert_ne 0 "$RUN_RC" "kernel_tree_for rejects an unknown pin"
assert_eq "" "$RUN_OUT" "kernel_tree_for prints no path for an unknown pin"
run_lib 'kernel_tree_for'
assert_ne 0 "$RUN_RC" "kernel_tree_for requires a pin argument"

point "$SCRATCH/cache-missing-pins" "$SCRATCH/no-such-pins.conf" "file://$MIRROR"
run_lib 'kernel_tree_for new'
_bad=ok
[ "$RUN_RC" -eq 0 ] && _bad="exit 0"
[ "$RUN_RC" -eq 77 ] && _bad="77 (skip)"
assert_eq "ok" "$_bad" "a missing pins file is a hard error, not a pass and not a skip"

EMPTY_SHA_PINS="$SCRATCH/pins-empty-sha.conf"
write_pins "$EMPTY_SHA_PINS" "$NEW_VER" "" "$OLD_VER" "$OLD_SHA"
point "$SCRATCH/cache-empty-sha" "$EMPTY_SHA_PINS" "file://$MIRROR"
run_lib 'kernel_tree_for new'
_bad=ok
[ "$RUN_RC" -eq 0 ] && _bad="exit 0"
[ "$RUN_RC" -eq 77 ] && _bad="77 (skip)"
assert_eq "ok" "$_bad" "a pin with an empty sha256 is a hard error, never silently accepted"

# ---------------------------------------------------------------------------
# the default cache root lives outside the repository
# ---------------------------------------------------------------------------

unset HDA_TEST_CACHE
HDA_KERNEL_PINS=$GOOD_PINS
HDA_KERNEL_MIRROR="file://$MIRROR"
export HDA_KERNEL_PINS HDA_KERNEL_MIRROR
SAVE_HOME=$HOME

XDG_CACHE_HOME="$SCRATCH/home-xdg/xdg"
export XDG_CACHE_HOME
HOME="$SCRATCH/home-xdg"
export HOME
run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "kernel_tree_for works with the default cache root (XDG_CACHE_HOME set)"
assert_file_exists "$XDG_CACHE_HOME/snd_hda_macbookpro-tests" \
  'the default cache root is $XDG_CACHE_HOME/snd_hda_macbookpro-tests'

unset XDG_CACHE_HOME
HOME="$SCRATCH/home-dotcache"
export HOME
run_lib 'kernel_tree_for new'
assert_eq 0 "$RUN_RC" "kernel_tree_for works with the default cache root (XDG_CACHE_HOME unset)"
assert_file_exists "$SCRATCH/home-dotcache/.cache/snd_hda_macbookpro-tests" \
  'the default cache root is $HOME/.cache/snd_hda_macbookpro-tests when XDG_CACHE_HOME is unset'
HOME=$SAVE_HOME
export HOME

# ---------------------------------------------------------------------------
# the helper never writes inside the repository
# ---------------------------------------------------------------------------

assert_eq "$STATUS_BEFORE" "$(repo_status)" \
  "the helper leaves the repository untouched (git status is unchanged after a run)"
assert_eq "" "$(find "$REPO_ROOT" -name .git -prune -o \( -name "$NEW_TARBALL" -o -name "$OLD_TARBALL" \) -print 2>/dev/null)" \
  "no kernel tarball is written inside the repository"
assert_eq "" "$(find "$REPO_ROOT" -name .git -prune -o -name patch_cirrus.c -path '*/sound/*' -print 2>/dev/null)" \
  "no kernel tree is extracted inside the repository"

finish