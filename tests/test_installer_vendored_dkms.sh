#!/usr/bin/env bash
#
# tests/test_installer_vendored_dkms.sh -- under --dkms the installer refuses to
# build from a guessed base x.y release (Ubuntu fallback, point release
# undeterminable) unless a vendored snapshot covers that exact base version: a
# mismatched module oopses at load, whereas a failed DKMS build shows up in
# `dkms status`.  Interactive runs keep the warn-and-continue behaviour.
#
# Same sandbox style as tests/test_installer_vendored.sh, with its own fixture
# vendor/ and fake wget/tar that record any call.
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
NO_BASE_TABLE="7.0.10 7.0.14 snap-b $HASH\n"

# write_headers_makefile <version> <patchlevel> <sublevel>
write_headers_makefile() {
  printf 'VERSION = %s\nPATCHLEVEL = %s\nSUBLEVEL = %s\nEXTRAVERSION =\n' "$1" "$2" "$3" > "$HDA_SANDBOX/fake/linux-headers/Makefile"
}

test_should_continue_with_snapshot_when_base_covered_under_dkms() {
  setup "$MINT" "$TABLE" || return
  run_installer 7.0.12-1-generic
  assert_eq 0 "$HDA_INSTALLER_RC" "installer succeeds (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot snap-a for kernel 7.0" "uses the base snapshot" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download"
}

test_should_leave_determinable_point_release_unchanged_under_dkms() {
  setup "$MINT" "$NO_BASE_TABLE" || return
  write_headers_makefile 7 0 12
  run_installer 7.0.12-1-generic
  assert_eq 0 "$HDA_INSTALLER_RC" "installer succeeds (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "using vendored snapshot snap-b for kernel 7.0.12" "uses the point release snapshot" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "warning: using the base" "no base release warning"
}

test_should_not_refuse_sublevel_zero_kernel_under_dkms() {
  setup "$MINT" "$NO_BASE_TABLE" || return
  write_headers_makefile 7 0 0
  run_installer 7.0.0-1-generic
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "refusing" "genuine base kernel is not refused" || return 1
  hda_assert_shim_called wget "$CDN/linux-7.0.tar.xz" "downloads the base release as before"
}

test_should_refuse_uncovered_base_release_under_dkms() {
  setup "$MINT" "$NO_BASE_TABLE" || return
  run_installer 7.0.12-1-generic
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "7.0.12-1-generic" "names the target kernel" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "could not be determined" "says why" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "would oops" "says why the build is refused" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "no extraction" || return 1
  assert_eq "" "$(hda_shim_calls make)" "no build"
}

test_should_warn_and_continue_without_dkms_when_base_uncovered() {
  setup "$MINT" "$NO_BASE_TABLE" || return
  run_installer_interactive 7.0.12-1-generic
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "refusing" "not refused" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "warning: using the base 7.0 release" "warns as before" || return 1
  hda_assert_shim_called wget "$CDN/linux-7.0.tar.xz" "downloads the base release as before"
}

test_should_not_affect_non_ubuntu_under_dkms() {
  setup "$PLAIN" "7.0.0 7.0.9 snap-a $HASH\n" || return
  run_installer 7.0.12-1-generic
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "refusing" "not refused" || return 1
  hda_assert_shim_called wget "$CDN/linux-7.0.12.tar.xz" "downloads the exact version as before"
}

test_should_not_affect_ubuntu_with_linux_source_package_under_dkms() {
  setup "$MINT" "$NO_BASE_TABLE" || return
  : > "$HDA_SANDBOX/fake/usr/src/linux-source-7.0.12.tar.bz2"
  run_installer 7.0.12-1-generic
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "refusing" "not refused" || return 1
  hda_assert_shim_called tar "linux-source-7.0.12.tar.bz2" "extracts from the package"
}

test_should_continue_with_snapshot_when_base_covered_under_dkms
test_should_leave_determinable_point_release_unchanged_under_dkms
test_should_not_refuse_sublevel_zero_kernel_under_dkms
test_should_refuse_uncovered_base_release_under_dkms
test_should_warn_and_continue_without_dkms_when_base_uncovered
test_should_not_affect_non_ubuntu_under_dkms
test_should_not_affect_ubuntu_with_linux_source_package_under_dkms

finish
