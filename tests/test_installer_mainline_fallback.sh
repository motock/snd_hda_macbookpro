#!/usr/bin/env bash
#
# tests/test_installer_mainline_fallback.sh -- on Ubuntu/Mint the installer
# falls back to verified mainline sources when the linux-source package is
# absent (HDA7-A).
#
# HWE and newer-than-LTS kernels have no linux-source-<version> package, so the
# Ubuntu branch used to give up.  It now prefers the package when present and
# otherwise downloads linux-<major>.<minor>.tar.xz from cdn.kernel.org, verifies
# its SHA-256 (fail closed, as HDA-11) and extracts sound/hda from it.
#
# Driven like tests/test_installer_build_check.sh: the sandbox copy of the real
# installer has /etc/os-release, /usr/src and /lib/modules redirected into the
# sandbox; wget and tar are fakes, nothing touches the network.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

SCRIPT=install.cirrus.driver.sh
UNAME=7.0.0-38-generic
MAINLINE=7.0
NOTE="using mainline kernel $MAINLINE sources from cdn.kernel.org"

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
FAKE_BIN=$(make_tmpdir)

# fake wget: HDA_FIXTURE_SUMS is served for -O; for -P the fixture tarball is
# written, unless HDA_WGET_FAIL_DOWNLOAD=1 (the download itself fails).
cat > "$FAKE_BIN/wget" <<'FAKE'
#!/bin/bash
printf 'wget %s\n' "$*" >> "$HDA_SHIM_LOG"
out="" dir=""
while [ $# -gt 0 ]; do
  case $1 in
    -O) out=$2; shift ;;
    -P) dir=$2; shift ;;
  esac
  shift
done
if [ -n "$out" ]; then
  [ -f "$HDA_FIXTURE_SUMS" ] || exit 8
  cp "$HDA_FIXTURE_SUMS" "$out"
elif [ -n "$dir" ]; then
  [ "${HDA_WGET_FAIL_DOWNLOAD:-0}" = "1" ] && exit 4
  cp "$HDA_FIXTURE_TARBALL" "$dir/linux-$HDA_FIXTURE_VERSION.tar.xz"
fi
exit 0
FAKE
chmod +x "$FAKE_BIN/wget"

# fake tar: logs its argv and creates the build/hda tree extraction would make
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

# new_fixture <sums-hash-or-empty> -- tarball plus a sums file; an explicit hash
# overrides the correct one (to model a corrupt download).
new_fixture() {
  _work=$(make_tmpdir) || return 1
  printf 'pretend kernel source\n' > "$_work/pristine.tar.xz" || return 1
  _sha=${1:-$(sha_of "$_work/pristine.tar.xz")}
  HDA_FIXTURE_SUMS="$_work/sha256sums.asc"
  HDA_FIXTURE_TARBALL="$_work/pristine.tar.xz"
  HDA_FIXTURE_VERSION=$MAINLINE
  {
    echo '-----BEGIN PGP SIGNED MESSAGE-----'
    echo 'Hash: SHA256'
    echo
    printf '%s  linux-%s.tar.xz\n' "$_sha" "$MAINLINE"
    echo '-----BEGIN PGP SIGNATURE-----'
  } > "$HDA_FIXTURE_SUMS" || return 1
  export HDA_FIXTURE_SUMS HDA_FIXTURE_TARBALL HDA_FIXTURE_VERSION
}

# prepare_installer <os-release body> <with-package: 0|1>
prepare_installer() {
  hda_sandbox_setup > /dev/null || return 1
  _fake="$HDA_SANDBOX/fake"
  mkdir -p "$_fake/linux-headers" "$_fake/usr/src" "$_fake/lib/modules/$UNAME" || return 1
  printf '%b' "$1" > "$_fake/os-release" || return 1
  [ "$2" = 1 ] && { : > "$_fake/usr/src/linux-source-7.0.0.tar.bz2" || return 1; }
  sed -i.bak \
    -e "s#/usr/src/linux-headers-\${UNAME}#$_fake/linux-headers#" \
    -e "s#/usr/src/linux-source-#$_fake/usr/src/linux-source-#g" \
    -e "s#/etc/os-release#$_fake/os-release#g" \
    -e "s#/lib/modules/#$_fake/lib/modules/#g" \
    "$HDA_SANDBOX/$SCRIPT" || return 1
  rm -f "$HDA_SANDBOX/$SCRIPT.bak"
  grep -q "$_fake/usr/src/linux-source-" "$HDA_SANDBOX/$SCRIPT" || {
    echo "linux-source probe not redirected" >&2; return 1; }
}

run_installer() {
  _saved=$HDA_SHIMS
  HDA_SHIMS="$FAKE_BIN:$HDA_SHIMS"
  hda_installer_run "$SCRIPT" -k "$UNAME"
  HDA_SHIMS=$_saved
}

MINT='NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\n'
PLAIN='NAME=TestOS\nID=testos\nID_LIKE=testos\n'

# setup <os-release> <with-package> <download-fails> <sums-hash>
setup() {
  new_fixture "$4" || { assert_eq fixture failed "fixture"; return 1; }
  prepare_installer "$1" "$2" || { assert_eq prepared failed "sandbox"; return 1; }
  hda_shim_clear
  HDA_WGET_FAIL_DOWNLOAD=$3
  export HDA_WGET_FAIL_DOWNLOAD
}

test_should_download_mainline_when_package_absent() {
  setup "$MINT" 0 0 "" || return
  run_installer
  hda_assert_shim_called wget "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.tar.xz" \
    "downloads the mainline $MAINLINE tarball (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "verified linux-7.0.tar.xz" "verifies its SHA-256" || return 1
  hda_assert_shim_called tar "--strip-components=2 -xvf $(cd "$HDA_SANDBOX" && pwd)/build/linux-7.0.tar.xz --directory=$(cd "$HDA_SANDBOX" && pwd)/build linux-7.0/sound/hda" \
    "extracts sound/hda from the mainline tarball" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$NOTE" "prints the using-mainline note"
}

test_should_use_package_when_present() {
  setup "$MINT" 1 0 "" || return
  run_installer
  hda_assert_shim_called tar "linux-source-7.0.0.tar.bz2" \
    "extracts from the linux-source package (output: $(hda_installer_output_oneline))" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download is attempted" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using mainline" "does not print the note"
}

test_should_fail_naming_kernel_when_download_fails() {
  setup "$MINT" 0 1 "" || return
  run_installer
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero when the download fails" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "linux-7.0.tar.xz" "names the failed download" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$UNAME" "names the kernel version" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "nothing is extracted"
}

test_should_fail_closed_on_checksum_mismatch() {
  setup "$MINT" 0 0 "$(printf '0%.0s' $(seq 64))" || return
  run_installer
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero on a checksum mismatch" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "SHA-256 mismatch" "states the mismatch" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "nothing is extracted" || return 1
  assert_eq "" "$(hda_shim_calls make)" "nothing is built or installed"
}

test_should_not_fall_back_on_non_ubuntu() {
  setup "$PLAIN" 0 0 "" || return
  run_installer
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using mainline" "non-Ubuntu prints no fallback note" || return 1
  hda_assert_shim_called wget "linux-7.0.0.tar.xz" "non-Ubuntu still tries the full version first"
}

test_should_download_mainline_when_package_absent
test_should_use_package_when_present
test_should_fail_naming_kernel_when_download_fails
test_should_fail_closed_on_checksum_mismatch
test_should_not_fall_back_on_non_ubuntu

finish
