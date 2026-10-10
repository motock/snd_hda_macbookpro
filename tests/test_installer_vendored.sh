#!/usr/bin/env bash
#
# tests/test_installer_vendored.sh -- the installer prefers a vendored kernel
# snapshot (vendor/LAYOUT-TABLE) over downloading the kernel tarball, verifies
# the snapshot against its MANIFEST (fail closed).
#
# Driven like tests/test_installer_upstream_version.sh: sandboxed installer
# copy with a FIXTURE vendor/ directory, fake wget/tar that record any call.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

SCRIPT=install.cirrus.driver.sh
CDN=https://cdn.kernel.org/pub/linux/kernel/v7.x
SRC=sound/hda/codecs/cirrus/cs8409.c
HDR=sound/hda/common/hda_jack.h
MINT='NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\n'
PLAIN='NAME=TestOS\nID=testos\nID_LIKE=testos\n'
HASH=$(printf 'a%.0s' $(seq 64))

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
FAKE_BIN=$(make_tmpdir)

# fake wget: HDA_WGET_FAIL_ALL=1 models being offline
cat > "$FAKE_BIN/wget" <<'FAKE'
#!/bin/bash
printf 'wget %s\n' "$*" >> "$HDA_SHIM_LOG"
out="" dir="" url=""
while [ $# -gt 0 ]; do
  case $1 in
    -O) out=$2; shift ;;
    -P) dir=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
[ "${HDA_WGET_FAIL_ALL:-0}" = "1" ] && exit 4
if [ -n "$out" ]; then
  cp "$HDA_FIXTURE_SUMS" "$out"
elif [ -n "$dir" ]; then
  cp "$HDA_FIXTURE_TARBALL" "$dir/${url##*/}"
fi
exit 0
FAKE
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
chmod +x "$FAKE_BIN/wget" "$FAKE_BIN/tar"

sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi
}

# sums file listing the fixture tarball under every version the tests ask for
new_download_fixture() {
  _work=$(make_tmpdir) || return 1
  printf 'pretend kernel source\n' > "$_work/pristine.tar.xz" || return 1
  _sha=$(sha_of "$_work/pristine.tar.xz")
  HDA_FIXTURE_SUMS="$_work/sha256sums.asc"
  HDA_FIXTURE_TARBALL="$_work/pristine.tar.xz"
  {
    echo '-----BEGIN PGP SIGNED MESSAGE-----'
    echo 'Hash: SHA256'
    echo
    for _v in 7.0 7.0.0 7.0.10 7.0.12 7.0.14 7.2.1; do printf '%s  linux-%s.tar.xz\n' "$_sha" "$_v"; done
    echo '-----BEGIN PGP SIGNATURE-----'
  } > "$HDA_FIXTURE_SUMS" || return 1
  export HDA_FIXTURE_SUMS HDA_FIXTURE_TARBALL
}

# add_snapshot <name> -- vendor/<name>/ with two files whose content names the snapshot, plus a valid MANIFEST
add_snapshot() {
  _s="${HDA_SANDBOX:?}/vendor/$1"
  mkdir -p "$_s/$(dirname "$SRC")" "$_s/$(dirname "$HDR")" || return 1
  printf 'source from %s\n' "$1" > "$_s/$SRC" || return 1
  printf 'header from %s\n' "$1" > "$_s/$HDR" || return 1
  {
    echo "tarball linux-fixture.tar.xz"
    echo "tarball-sha256 $HASH"
    echo "layout-hash $HASH"
    printf '%s  %s\n' "$(sha_of "$_s/$SRC")" "$SRC"
    printf '%s  %s\n' "$(sha_of "$_s/$HDR")" "$HDR"
  } > "$_s/MANIFEST"
}

# setup <os-release> <table-body> -- sandbox with a fixture vendor/ holding snap-a and snap-b
setup() {
  new_download_fixture || { assert_eq fixture failed "fixture"; return 1; }
  hda_sandbox_setup > /dev/null || { assert_eq prepared failed "sandbox"; return 1; }
  _fake="${HDA_SANDBOX:?}/fake"
  mkdir -p "$_fake/linux-headers" "$_fake/usr/src" || return 1
  printf '%b' "$1" > "$_fake/os-release" || return 1
  sed -i.bak \
    -e "s#/usr/src/linux-headers-\${UNAME}#$_fake/linux-headers#" \
    -e "s#/usr/src/linux-source-#$_fake/usr/src/linux-source-#g" \
    -e "s#/etc/os-release#$_fake/os-release#g" \
    -e "s#/lib/modules/#$_fake/lib/modules/#g" \
    "$HDA_SANDBOX/$SCRIPT" || return 1
  rm -f "${HDA_SANDBOX:?}/${SCRIPT:?}.bak"
  rm -rf "${HDA_SANDBOX:?}/vendor" && mkdir "$HDA_SANDBOX/vendor" || return 1
  add_snapshot snap-a && add_snapshot snap-b || return 1
  printf '%b' "$2" > "$HDA_SANDBOX/vendor/LAYOUT-TABLE" || return 1
  hda_shim_clear
  HDA_SHIM_UNAME_R=none
  HDA_VERSION_SIGNATURE="$_fake/version_signature"
  HDA_WGET_FAIL_ALL=0
  rm -f "${HDA_VERSION_SIGNATURE:?}"
  export HDA_SHIM_UNAME_R HDA_VERSION_SIGNATURE HDA_WGET_FAIL_ALL
}

# run_installer <kernel-release> [extra installer args] -- runs in --dkms mode (the
# non-dkms tail needs a real built module, which the fake make does not produce)
run_installer() {
  run_installer_interactive "$@" --dkms
}

run_installer_interactive() {
  _rel=$1
  shift
  mkdir -p "$HDA_SANDBOX/fake/lib/modules/$_rel" || return 1
  _saved=$HDA_SHIMS
  HDA_SHIMS="$FAKE_BIN:$HDA_SHIMS"
  hda_installer_run "$SCRIPT" -k "$_rel" "$@"
  HDA_SHIMS=$_saved
}

TABLE="7.0.0 7.0.9 snap-a $HASH\n7.0.10 7.0.14 snap-b $HASH\n"

# assert_used_snapshot <snapshot> <version>
assert_used_snapshot() {
  assert_eq "" "$(hda_shim_calls wget)" "no download for $2" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "no tar extraction for $2" || return 1
  assert_eq "source from $1" "$(cat "$HDA_SANDBOX/build/hda/${SRC#sound/hda/}" 2>/dev/null)" "build tree holds $1's source" || return 1
  assert_file_exists "$HDA_SANDBOX/build/hda/${HDR#sound/hda/}" "header is copied" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot $1 for kernel $2" "names the snapshot"
}

test_should_use_vendored_snapshot_without_download() {
  setup "$PLAIN" "$TABLE" || return
  run_installer 7.0.12-1-generic
  assert_used_snapshot snap-b 7.0.12 || return 1
  assert_eq "header from snap-b" "$(cat "$HDA_SANDBOX/build/hda/${HDR#sound/hda/}")" "all snapshot files are copied" || return 1
  assert_eq 0 "$HDA_INSTALLER_RC" "installer succeeds (output: $(hda_installer_output_oneline))"
}

test_should_cover_first_version_of_range() {
  setup "$PLAIN" "$TABLE" || return
  run_installer 7.0.0-1-generic
  assert_used_snapshot snap-a 7.0.0
}

test_should_cover_last_version_of_range() {
  setup "$PLAIN" "$TABLE" || return
  run_installer 7.0.14-1-generic
  assert_used_snapshot snap-b 7.0.14
}

test_should_pick_snapshot_a_for_7_0_9() {
  setup "$PLAIN" "$TABLE" || return
  run_installer 7.0.9-1-generic
  assert_used_snapshot snap-a 7.0.9
}

test_should_pick_snapshot_b_for_7_0_10() {
  setup "$PLAIN" "$TABLE" || return
  run_installer 7.0.10-1-generic
  assert_used_snapshot snap-b 7.0.10
}

test_should_compare_versions_numerically_not_as_strings() {
  setup "$PLAIN" "7.0.2 7.0.9 snap-a $HASH\n" || return
  run_installer 7.0.10-1-generic
  hda_assert_shim_called wget "$CDN/linux-7.0.10.tar.xz" "7.0.10 is above 7.0.9, so it is not covered" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot" "no snapshot used"
}

test_should_succeed_offline_for_covered_version() {
  setup "$PLAIN" "$TABLE" || return
  HDA_WGET_FAIL_ALL=1
  export HDA_WGET_FAIL_ALL
  run_installer 7.0.12-1-generic
  assert_eq 0 "$HDA_INSTALLER_RC" "offline run succeeds (output: $(hda_installer_output_oneline))"
}

test_should_download_and_note_when_version_not_covered() {
  setup "$PLAIN" "$TABLE" || return
  run_installer 7.2.1-1-generic
  hda_assert_shim_called wget "$CDN/linux-7.2.1.tar.xz" "downloads as before" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "verified linux-7.2.1.tar.xz" "still verifies the tarball" || return 1
  hda_assert_shim_called tar "linux-7.2.1/sound/hda" "still extracts from the tarball" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "no vendored snapshot for 7.2.1; downloading from cdn.kernel.org" "prints the note"
}

test_should_fail_closed_when_snapshot_file_hash_differs() {
  setup "$PLAIN" "$TABLE" || return
  printf 'tampered\n' >> "$HDA_SANDBOX/vendor/snap-b/$SRC"
  run_installer 7.0.12-1-generic
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero on a hash mismatch" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download is attempted" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "nothing is extracted" || return 1
  assert_eq "" "$(hda_shim_calls make)" "nothing is built"
}

test_should_fail_when_manifest_missing() {
  setup "$PLAIN" "$TABLE" || return
  rm "${HDA_SANDBOX:?}/vendor/snap-b/MANIFEST"
  run_installer 7.0.12-1-generic
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero without a MANIFEST" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download is attempted" || return 1
  assert_eq "" "$(hda_shim_calls make)" "nothing is built"
}

test_should_ignore_malformed_table_line_and_download() {
  setup "$PLAIN" "7.0.10 7.0.14 snap-b\n" || return
  run_installer 7.0.12-1-generic
  assert_eq 0 "$HDA_INSTALLER_RC" "does not crash (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "LAYOUT-TABLE" "warns about the table" || return 1
  hda_assert_shim_called wget "$CDN/linux-7.0.12.tar.xz" "uses the download path"
}

test_should_ignore_range_with_last_before_first() {
  setup "$PLAIN" "7.0.14 7.0.10 snap-b $HASH\n" || return
  run_installer 7.0.12-1-generic
  hda_assert_shim_called wget "$CDN/linux-7.0.12.tar.xz" "uses the download path" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot" "no snapshot used"
}

test_should_not_consult_table_when_ubuntu_source_package_present() {
  setup "$MINT" "$TABLE" || return
  : > "$HDA_SANDBOX/fake/usr/src/linux-source-7.0.12.tar.bz2"
  run_installer 7.0.12-1-generic
  hda_assert_shim_called tar "linux-source-7.0.12.tar.bz2" "extracts from the package" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "vendored snapshot" "table not consulted"
}

test_should_download_without_error_when_vendor_dir_absent() {
  setup "$PLAIN" "$TABLE" || return
  rm -rf "${HDA_SANDBOX:?}/vendor"
  run_installer 7.0.12-1-generic
  assert_eq 0 "$HDA_INSTALLER_RC" "exits 0 (output: $(hda_installer_output_oneline))" || return 1
  hda_assert_shim_called wget "$CDN/linux-7.0.12.tar.xz" "downloads the tarball" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "no vendored snapshot for 7.0.12; downloading from cdn.kernel.org" "prints the note" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "LAYOUT-TABLE" "no warning about the table"
}

test_should_use_vendored_snapshot_without_download
test_should_cover_first_version_of_range
test_should_cover_last_version_of_range
test_should_pick_snapshot_a_for_7_0_9
test_should_pick_snapshot_b_for_7_0_10
test_should_compare_versions_numerically_not_as_strings
test_should_succeed_offline_for_covered_version
test_should_download_and_note_when_version_not_covered
test_should_fail_closed_when_snapshot_file_hash_differs
test_should_fail_when_manifest_missing
test_should_ignore_malformed_table_line_and_download
test_should_ignore_range_with_last_before_first
test_should_not_consult_table_when_ubuntu_source_package_present
test_should_download_without_error_when_vendor_dir_absent

finish
