#!/usr/bin/env bash
#
# tests/test_installer_vendored.sh -- the >= 6.17 installer builds from a
# vendored snapshot when vendor/LAYOUT-TABLE covers the exact kernel version
# (VENDOR-USE), and refuses a guessed layout under dkms.
#
# A covered version never touches the network: no wget, no checksum fetch, no
# tar.  The snapshot's MANIFEST is verified before use and a mismatch is a
# hard error.  An uncovered version downloads and verifies as before.  Under
# --dkms an Ubuntu kernel whose point release cannot be determined would be
# built from the base release; unless that base is itself vendored the
# installer exits non-zero instead of producing a module that oopses at load.
#
# Driven like tests/test_installer_mainline_fallback.sh: sandboxed installer
# copy, fake wget/tar, a fixture vendor/ replacing the real one.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

SCRIPT=install.cirrus.driver.sh
UNAME_UBUNTU=7.0.0-38-generic
MINT='NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\n'
PLAIN='NAME=TestOS\nID=testos\nID_LIKE=testos\n'
HASH=$(printf 'a%.0s' $(seq 64))
NO_VENDOR_NOTE='no vendored snapshot for'

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
FAKE_BIN=$(make_tmpdir)

# fake wget: serves HDA_FIXTURE_SUMS for -O and a tarball named after the URL
# for -P; HDA_WGET_FAIL=1 makes every call fail (offline).
cat > "$FAKE_BIN/wget" <<'FAKE'
#!/bin/bash
printf 'wget %s\n' "$*" >> "$HDA_SHIM_LOG"
[ "${HDA_WGET_FAIL:-0}" = "1" ] && exit 4
out="" dir="" url=""
while [ $# -gt 0 ]; do
  case $1 in
    -O) out=$2; shift ;;
    -P) dir=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
if [ -n "$out" ]; then
  [ -f "$HDA_FIXTURE_SUMS" ] || exit 8
  cp "$HDA_FIXTURE_SUMS" "$out"
elif [ -n "$dir" ]; then
  cp "$HDA_FIXTURE_TARBALL" "$dir/${url##*/}"
fi
exit 0
FAKE
chmod +x "$FAKE_BIN/wget"

cat > "$FAKE_BIN/tar" <<'FAKE'
#!/bin/bash
printf 'tar %s\n' "$*" >> "$HDA_SHIM_LOG"
hda="$HDA_SANDBOX/build/hda"
mkdir -p "$hda/common" "$hda/codecs/cirrus" || exit 1
for f in Makefile common/Makefile codecs/Makefile codecs/cirrus/Makefile; do
  : > "$hda/$f"
done
exit 0
FAKE
chmod +x "$FAKE_BIN/tar"

sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi
}

# new_fixture <version> -- a tarball and a sums file naming it, for the
# download path.
new_fixture() {
  _work=$(make_tmpdir) || return 1
  printf 'pretend kernel source\n' > "$_work/pristine.tar.xz" || return 1
  HDA_FIXTURE_SUMS="$_work/sha256sums.asc"
  HDA_FIXTURE_TARBALL="$_work/pristine.tar.xz"
  {
    echo '-----BEGIN PGP SIGNED MESSAGE-----'
    echo 'Hash: SHA256'
    echo
    printf '%s  linux-%s.tar.xz\n' "$(sha_of "$_work/pristine.tar.xz")" "$1"
    echo '-----BEGIN PGP SIGNATURE-----'
  } > "$HDA_FIXTURE_SUMS" || return 1
  export HDA_FIXTURE_SUMS HDA_FIXTURE_TARBALL
}

# make_snapshot <name> -- vendor/<name>/ with two files whose content names the
# snapshot, and a MANIFEST in the real format.
make_snapshot() {
  _snap="$HDA_SANDBOX/vendor/$1"
  mkdir -p "$_snap/sound/hda/codecs/cirrus" "$_snap/sound/hda/common" || return 1
  printf 'snapshot %s\n' "$1" > "$_snap/sound/hda/codecs/cirrus/cs8409.c" || return 1
  printf '#define SNAPSHOT "%s"\n' "$1" > "$_snap/sound/hda/common/hda_local.h" || return 1
  {
    echo "tarball linux-$1.tar.xz"
    echo "tarball-sha256 $HASH"
    echo "layout-hash $HASH"
    printf '%s  sound/hda/codecs/cirrus/cs8409.c\n' "$(sha_of "$_snap/sound/hda/codecs/cirrus/cs8409.c")"
    printf '%s  sound/hda/common/hda_local.h\n' "$(sha_of "$_snap/sound/hda/common/hda_local.h")"
  } > "$_snap/MANIFEST"
}

# default table: 7.0.0-7.0.9 -> snap-a, 7.0.10-7.0.14 -> snap-b
DEFAULT_TABLE="# fixture
7.0.0 7.0.9 snap-a $HASH
7.0.10 7.0.14 snap-b $HASH"

# setup <os-release> <with-linux-source-package: 0|1> <table-body>
# Builds the sandbox with a fixture vendor/ holding snap-a and snap-b.
setup() {
  hda_sandbox_setup > /dev/null || { assert_eq prepared failed "sandbox"; return 1; }
  _fake="$HDA_SANDBOX/fake"
  mkdir -p "$_fake/linux-headers" "$_fake/usr/src" "$_fake/lib/modules" || return 1
  printf '%b' "$1" > "$_fake/os-release" || return 1
  [ "$2" = 1 ] && { : > "$_fake/usr/src/linux-source-7.0.0.tar.bz2" || return 1; }
  sed -i.bak \
    -e "s#/usr/src/linux-headers-\${UNAME}#$_fake/linux-headers#" \
    -e "s#/usr/src/linux-source-#$_fake/usr/src/linux-source-#g" \
    -e "s#/etc/os-release#$_fake/os-release#g" \
    -e "s#/lib/modules/#$_fake/lib/modules/#g" \
    "$HDA_SANDBOX/$SCRIPT" || return 1
  rm -f "$HDA_SANDBOX/$SCRIPT.bak"
  rm -rf "$HDA_SANDBOX/vendor"
  mkdir -p "$HDA_SANDBOX/vendor" || return 1
  make_snapshot snap-a && make_snapshot snap-b || return 1
  printf '%s\n' "$3" > "$HDA_SANDBOX/vendor/LAYOUT-TABLE" || return 1
  HDA_VERSION_SIGNATURE=/nonexistent/version_signature
  export HDA_VERSION_SIGNATURE
  HDA_WGET_FAIL=0
  export HDA_WGET_FAIL
  hda_shim_clear
}

# run_installer <uname> [extra installer args...]
run_installer() {
  _uname=$1
  shift
  mkdir -p "$HDA_SANDBOX/fake/lib/modules/$_uname" || return 1
  _saved=$HDA_SHIMS
  HDA_SHIMS="$FAKE_BIN:$HDA_SHIMS"
  hda_installer_run "$SCRIPT" -k "$_uname" "$@"
  HDA_SHIMS=$_saved
}

built_file() { cat "$HDA_SANDBOX/build/hda/$1" 2> /dev/null; }

assert_vendored() {
  # <snapshot> <version>
  assert_eq 0 "$HDA_INSTALLER_RC" "exits 0 (output: $(hda_installer_output_oneline))" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no wget call" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "no tar call" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot $1 for kernel $2" "names the snapshot" || return 1
  assert_contains "$(built_file codecs/cirrus/cs8409.c)" "snapshot $1" "snapshot files are in the build tree"
}

test_should_use_snapshot_without_network_when_version_covered() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  HDA_WGET_FAIL=1
  run_installer 7.0.5-1-generic --dkms
  assert_vendored snap-a 7.0.5 || return 1
  assert_contains "$(built_file common/hda_local.h)" 'SNAPSHOT "snap-a"' "headers are copied too"
}

test_should_cover_first_boundary_of_range() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  run_installer 7.0.0-1-generic --dkms
  assert_vendored snap-a 7.0.0
}

test_should_cover_last_boundary_of_range() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  run_installer 7.0.14-1-generic --dkms
  assert_vendored snap-b 7.0.14
}

test_should_pick_older_snapshot_for_7_0_9() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  run_installer 7.0.9-1-generic --dkms
  assert_vendored snap-a 7.0.9
}

test_should_pick_newer_snapshot_for_7_0_10() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  run_installer 7.0.10-1-generic --dkms
  assert_vendored snap-b 7.0.10
}

test_should_leave_placeholder_makefiles_for_later_steps() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  run_installer 7.0.5-1-generic --dkms
  assert_file_exists "$HDA_SANDBOX/build/hda/codecs/cirrus/Makefile.orig" "the mv steps found the placeholder Makefile"
}

test_should_download_when_version_not_in_any_range() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  new_fixture 7.0.15 || return
  run_installer 7.0.15-1-generic --dkms
  assert_eq 0 "$HDA_INSTALLER_RC" "exits 0 (output: $(hda_installer_output_oneline))" || return 1
  hda_assert_shim_called wget "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.15.tar.xz" "downloads the matching tarball" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "verified linux-7.0.15.tar.xz" "verifies it" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$NO_VENDOR_NOTE 7.0.15; downloading from cdn.kernel.org" "prints the no-snapshot note" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot" "uses no snapshot"
}

test_should_fail_closed_when_snapshot_file_hash_differs() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  printf 'tampered\n' >> "$HDA_SANDBOX/vendor/snap-a/sound/hda/codecs/cirrus/cs8409.c"
  run_installer 7.0.5-1-generic --dkms
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero on a hash mismatch" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "cs8409.c" "names the offending file" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download is attempted" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "nothing is extracted" || return 1
  assert_eq "" "$(hda_shim_calls patch)" "nothing is patched or built" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot" "does not claim the snapshot"
}

test_should_fail_when_manifest_missing() {
  setup "$PLAIN" 0 "$DEFAULT_TABLE" || return
  rm "$HDA_SANDBOX/vendor/snap-a/MANIFEST"
  run_installer 7.0.5-1-generic --dkms
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero without a MANIFEST" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "MANIFEST" "names the missing MANIFEST" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download is attempted" || return 1
  assert_eq "" "$(hda_shim_calls patch)" "nothing is built"
}

test_should_ignore_malformed_table_line_and_download() {
  setup "$PLAIN" 0 "this is not a table line
7.0.0 $HASH" || return
  new_fixture 7.0.5 || return
  run_installer 7.0.5-1-generic --dkms
  assert_eq 0 "$HDA_INSTALLER_RC" "does not crash (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "LAYOUT-TABLE" "warns about the table" || return 1
  hda_assert_shim_called wget "linux-7.0.5.tar.xz" "takes the download path" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$NO_VENDOR_NOTE 7.0.5" "prints the no-snapshot note"
}

test_should_ignore_snapshot_name_escaping_vendor_dir() {
  setup "$PLAIN" 0 "7.0.0 7.0.9 ../fake $HASH" || return
  new_fixture 7.0.5 || return
  run_installer 7.0.5-1-generic --dkms
  assert_contains "$HDA_INSTALLER_OUTPUT" "LAYOUT-TABLE" "warns about the table" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot" "does not use a path outside vendor/" || return 1
  hda_assert_shim_called wget "linux-7.0.5.tar.xz" "takes the download path"
}

test_should_ignore_range_with_last_before_first() {
  setup "$PLAIN" 0 "7.0.9 7.0.0 snap-a $HASH" || return
  new_fixture 7.0.5 || return
  run_installer 7.0.5-1-generic --dkms
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot" "an inverted range covers nothing" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "LAYOUT-TABLE" "warns about the table" || return 1
  hda_assert_shim_called wget "linux-7.0.5.tar.xz" "takes the download path"
}

test_should_not_consult_table_when_ubuntu_source_present() {
  setup "$MINT" 1 "$DEFAULT_TABLE" || return
  run_installer "$UNAME_UBUNTU" --dkms
  hda_assert_shim_called tar "linux-source-7.0.0.tar.bz2" "extracts from the linux-source package (output: $(hda_installer_output_oneline))" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "vendored snapshot" "does not look at the table" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download is attempted"
}

test_should_fail_under_dkms_when_point_release_unknown_and_base_not_vendored() {
  setup "$MINT" 0 "7.0.10 7.0.14 snap-b $HASH" || return
  new_fixture 7.0 || return
  run_installer "$UNAME_UBUNTU" --dkms
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "7.0" "names the release" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "nothing is extracted" || return 1
  assert_eq "" "$(hda_shim_calls patch)" "nothing is built" || return 1
  assert_eq "" "$(hda_shim_calls make)" "make is not run"
}

test_should_continue_without_dkms_when_point_release_unknown() {
  setup "$MINT" 0 "7.0.10 7.0.14 snap-b $HASH" || return
  new_fixture 7.0 || return
  run_installer "$UNAME_UBUNTU"
  assert_contains "$HDA_INSTALLER_OUTPUT" "may not match the target kernel's struct layout" "warns" || return 1
  hda_assert_shim_called tar "linux-7.0/sound/hda" "continues with the base release"
}

test_should_accept_vendored_base_release_under_dkms() {
  setup "$MINT" 0 "$DEFAULT_TABLE" || return
  HDA_WGET_FAIL=1
  run_installer "$UNAME_UBUNTU" --dkms
  assert_vendored snap-a 7.0
}

test_should_use_snapshot_without_network_when_version_covered
test_should_cover_first_boundary_of_range
test_should_cover_last_boundary_of_range
test_should_pick_older_snapshot_for_7_0_9
test_should_pick_newer_snapshot_for_7_0_10
test_should_leave_placeholder_makefiles_for_later_steps
test_should_download_when_version_not_in_any_range
test_should_fail_closed_when_snapshot_file_hash_differs
test_should_fail_when_manifest_missing
test_should_ignore_malformed_table_line_and_download
test_should_ignore_snapshot_name_escaping_vendor_dir
test_should_ignore_range_with_last_before_first
test_should_not_consult_table_when_ubuntu_source_present
test_should_fail_under_dkms_when_point_release_unknown_and_base_not_vendored
test_should_continue_without_dkms_when_point_release_unknown
test_should_accept_vendored_base_release_under_dkms

finish
