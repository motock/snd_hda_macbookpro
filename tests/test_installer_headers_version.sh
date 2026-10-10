#!/usr/bin/env bash
#
# tests/test_installer_headers_version.sh -- the Ubuntu mainline fallback reads
# the upstream point release from the target kernel's headers Makefile
# (DKMS-HDRVER), so it works when the target is not the running kernel.
#
# dkms.conf runs `install.cirrus.driver.sh -k $kernelver --dkms` while the OLD
# kernel is still running, so /proc/version_signature names the wrong kernel.
# /usr/src/linux-headers-<target>/Makefile carries VERSION/PATCHLEVEL/SUBLEVEL
# of the target itself.  Order: headers Makefile, then the signature (running
# kernel only), then the base x.y release with a warning.
#
# Same sandbox, fake wget/tar and HDA_SHIM_UNAME_R approach as
# tests/test_installer_upstream_version.sh.  Nothing touches the network.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

SCRIPT=install.cirrus.driver.sh
UNAME=7.0.0-40-generic
RUNNING=7.0.0-38-generic
SIG='Ubuntu 7.0.0-38.38~24.04.4-generic 7.0.14'
WARNING="may not match the target kernel's struct layout"
CDN=https://cdn.kernel.org/pub/linux/kernel/v7.x
hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
FAKE_BIN=$(make_tmpdir)

# fake wget: the sums file is served for -O; for -P the fixture tarball is
# written under the name in the URL, unless the URL contains HDA_WGET_FAIL_MATCH.
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
if [ -n "$out" ]; then
  [ -f "$HDA_FIXTURE_SUMS" ] || exit 8
  cp "$HDA_FIXTURE_SUMS" "$out"
elif [ -n "$dir" ]; then
  [ -n "${HDA_WGET_FAIL_MATCH:-}" ] && [[ $url == *"$HDA_WGET_FAIL_MATCH"* ]] && exit 4
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

# new_fixture <bad-hash-or-empty> -- a sums file listing the tarball under every
# name the installer may ask for; an explicit hash models a corrupt download.
new_fixture() {
  _work=$(make_tmpdir) || return 1
  printf 'pretend kernel source\n' > "$_work/pristine.tar.xz" || return 1
  _sha=${1:-$(sha_of "$_work/pristine.tar.xz")}
  HDA_FIXTURE_SUMS="$_work/sha256sums.asc"
  HDA_FIXTURE_TARBALL="$_work/pristine.tar.xz"
  {
    echo '-----BEGIN PGP SIGNED MESSAGE-----'
    echo 'Hash: SHA256'
    echo
    for _v in 7.0 7.0.14 7.0.0; do printf '%s  linux-%s.tar.xz\n' "$_sha" "$_v"; done
    echo '-----BEGIN PGP SIGNATURE-----'
  } > "$HDA_FIXTURE_SUMS" || return 1
  export HDA_FIXTURE_SUMS HDA_FIXTURE_TARBALL
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
}

# run_installer [extra installer args]  (default: -k $UNAME)
run_installer() {
  _saved=$HDA_SHIMS
  HDA_SHIMS="$FAKE_BIN:$HDA_SHIMS"
  if [ $# -eq 0 ]; then hda_installer_run "$SCRIPT" -k "$UNAME"; else hda_installer_run "$SCRIPT" "$@"; fi
  HDA_SHIMS=$_saved
}

MINT='NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\n'
PLAIN='NAME=TestOS\nID=testos\nID_LIKE=testos\n'

# mk <version> <patchlevel> <sublevel> -- a headers Makefile head
mk() { printf 'VERSION = %s\nPATCHLEVEL = %s\nSUBLEVEL = %s\nEXTRAVERSION =\n' "$1" "$2" "$3"; }

# setup <os-release> <signature-content-or-MISSING> <makefile-content-or-MISSING>
# The target is NOT the running kernel (the DKMS upgrade case).
setup() {
  new_fixture "" || { assert_eq fixture failed "fixture"; return 1; }
  prepare_installer "$1" 0 || { assert_eq prepared failed "sandbox"; return 1; }
  hda_shim_clear
  HDA_WGET_FAIL_MATCH=""
  HDA_SHIM_UNAME_R=$RUNNING
  HDA_VERSION_SIGNATURE="$HDA_SANDBOX/fake/version_signature"
  rm -f "$HDA_VERSION_SIGNATURE" "$HDA_SANDBOX/fake/linux-headers/Makefile"
  [ "$2" = MISSING ] || printf '%s' "$2" > "$HDA_VERSION_SIGNATURE"
  [ "$3" = MISSING ] || printf '%s' "$3" > "$HDA_SANDBOX/fake/linux-headers/Makefile"
  export HDA_WGET_FAIL_MATCH HDA_SHIM_UNAME_R HDA_VERSION_SIGNATURE
}

assert_base_with_warning() {
  hda_assert_shim_called wget "$CDN/linux-7.0.tar.xz" \
    "downloads the base 7.0 tarball (output: $(hda_installer_output_oneline))" || return 1
  assert_eq "" "$(hda_shim_calls wget | grep 'linux-7.0.14')" "never asks for 7.0.14" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "warns about the layout mismatch"
}

assert_stable_from_makefile() {
  hda_assert_shim_called wget "$CDN/linux-7.0.14.tar.xz" \
    "downloads linux-7.0.14 (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "verified linux-7.0.14.tar.xz" "verifies its SHA-256" || return 1
  hda_assert_shim_called tar "linux-7.0.14/sound/hda" "extracts sound/hda from 7.0.14" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "using mainline kernel 7.0.14 sources" "names the version used" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "no base-release warning"
}

test_should_use_headers_makefile_when_target_is_not_running_kernel() {
  setup "$MINT" MISSING "$(mk 7 0 14)" || return
  run_installer
  assert_stable_from_makefile
}

test_should_use_headers_makefile_under_dkms_invocation() {
  setup "$MINT" MISSING "$(mk 7 0 14)" || return
  run_installer --dkms -k "$UNAME"
  assert_stable_from_makefile
}

test_should_prefer_makefile_over_disagreeing_signature() {
  setup "$MINT" 'Ubuntu 7.0.0-40.40-generic 7.0.9' "$(mk 7 0 14)" || return
  HDA_SHIM_UNAME_R=$UNAME
  run_installer
  assert_stable_from_makefile
}

test_should_fall_through_to_signature_when_makefile_missing() {
  setup "$MINT" "$SIG" MISSING || return
  HDA_SHIM_UNAME_R=$UNAME
  run_installer
  assert_stable_from_makefile
}

test_should_warn_and_use_base_when_makefile_and_signature_unusable() {
  setup "$MINT" MISSING MISSING || return
  run_installer
  assert_base_with_warning
}

test_should_fall_through_to_signature_when_sublevel_missing() {
  setup "$MINT" "$SIG" 'VERSION = 7
PATCHLEVEL = 0
' || return
  HDA_SHIM_UNAME_R=$UNAME
  run_installer
  assert_stable_from_makefile
}

test_should_warn_and_use_base_when_sublevel_missing() {
  setup "$MINT" MISSING 'VERSION = 7
PATCHLEVEL = 0
' || return
  run_installer
  assert_base_with_warning
}

test_should_warn_and_use_base_when_sublevel_non_numeric() {
  setup "$MINT" MISSING "$(mk 7 0 14-rc1)" || return
  run_installer
  assert_base_with_warning
}

test_should_warn_and_use_base_when_sublevel_empty() {
  setup "$MINT" MISSING "$(mk 7 0 '')" || return
  run_installer
  assert_base_with_warning
}

test_should_warn_and_use_base_when_makefile_major_minor_differs() {
  setup "$MINT" MISSING "$(mk 6 8 12)" || return
  run_installer
  assert_base_with_warning
}

test_should_use_base_without_warning_when_sublevel_is_zero() {
  setup "$MINT" MISSING "$(mk 7 0 0)" || return
  run_installer
  hda_assert_shim_called wget "$CDN/linux-7.0.tar.xz" "downloads the base release" || return 1
  assert_eq "" "$(hda_shim_calls wget | grep 'linux-7.0.0')" "never asks for linux-7.0.0" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "no warning for a genuine x.y.0 kernel"
}

test_should_reject_version_line_with_trailing_garbage() {
  setup "$MINT" MISSING 'VERSION = 7
PATCHLEVEL = 0
SUBLEVEL = 14 # note
' || return
  run_installer
  assert_base_with_warning
}

test_should_reject_version_line_with_leading_tab() {
  setup "$MINT" MISSING 'VERSION = 7
PATCHLEVEL = 0
	SUBLEVEL = 14
' || return
  run_installer
  assert_base_with_warning
}

test_should_fall_back_to_base_when_stable_download_fails() {
  setup "$MINT" MISSING "$(mk 7 0 14)" || return
  HDA_WGET_FAIL_MATCH=linux-7.0.14
  export HDA_WGET_FAIL_MATCH
  run_installer
  hda_assert_shim_called wget "$CDN/linux-7.0.14.tar.xz" "tries 7.0.14 first" || return 1
  hda_assert_shim_called wget "$CDN/linux-7.0.tar.xz" "then tries the base release" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "warns about the layout mismatch"
}

test_should_not_consult_headers_makefile_on_non_ubuntu() {
  setup "$PLAIN" MISSING "$(mk 7 0 14)" || return
  run_installer
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using mainline" "prints no fallback note" || return 1
  assert_eq "" "$(hda_shim_calls wget | grep 'linux-7.0.14')" "never asks for 7.0.14"
}

test_should_use_headers_makefile_when_target_is_not_running_kernel
test_should_use_headers_makefile_under_dkms_invocation
test_should_prefer_makefile_over_disagreeing_signature
test_should_fall_through_to_signature_when_makefile_missing
test_should_warn_and_use_base_when_makefile_and_signature_unusable
test_should_fall_through_to_signature_when_sublevel_missing
test_should_warn_and_use_base_when_sublevel_missing
test_should_warn_and_use_base_when_sublevel_non_numeric
test_should_warn_and_use_base_when_sublevel_empty
test_should_warn_and_use_base_when_makefile_major_minor_differs
test_should_use_base_without_warning_when_sublevel_is_zero
test_should_reject_version_line_with_trailing_garbage
test_should_reject_version_line_with_leading_tab
test_should_fall_back_to_base_when_stable_download_fails
test_should_not_consult_headers_makefile_on_non_ubuntu

finish
