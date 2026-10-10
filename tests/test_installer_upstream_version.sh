#!/usr/bin/env bash
#
# tests/test_installer_upstream_version.sh -- the Ubuntu mainline fallback
# downloads the upstream point release named by /proc/version_signature
# (INST-UPSTREAM-VER), not the base x.y release.
#
# A module built from base 7.0 headers disagrees with a 7.0.14 kernel about
# struct hda_gen_spec's layout (hda_multi_out grew in 7.0.10) and oopses at
# probe.  The version is only trusted when it is well formed, matches the
# target's major.minor and the target is the running kernel; otherwise the
# installer keeps the base release and warns.
#
# Driven like tests/test_installer_mainline_fallback.sh: sandboxed installer
# copy, fake wget/tar, HDA_SHIM_UNAME_R for `uname -r`, HDA_VERSION_SIGNATURE
# for the signature file.  Nothing touches the network.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

SCRIPT=install.cirrus.driver.sh
UNAME=7.0.0-38-generic
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
    for _v in 7.0 7.0.14; do printf '%s  linux-%s.tar.xz\n' "$_sha" "$_v"; done
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

# run_installer [-k target]  (HDA_SHIM_UNAME_R / HDA_VERSION_SIGNATURE from env)
run_installer() {
  _saved=$HDA_SHIMS
  HDA_SHIMS="$FAKE_BIN:$HDA_SHIMS"
  hda_installer_run "$SCRIPT" -k "${1:-$UNAME}"
  HDA_SHIMS=$_saved
}

MINT='NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\n'
PLAIN='NAME=TestOS\nID=testos\nID_LIKE=testos\n'

# setup <os-release> <with-package> <signature-content-or-MISSING> [bad-hash]
setup() {
  new_fixture "${4:-}" || { assert_eq fixture failed "fixture"; return 1; }
  prepare_installer "$1" "$2" || { assert_eq prepared failed "sandbox"; return 1; }
  hda_shim_clear
  HDA_WGET_FAIL_MATCH=""
  HDA_SHIM_UNAME_R=$UNAME
  HDA_VERSION_SIGNATURE="$HDA_SANDBOX/fake/version_signature"
  rm -f "$HDA_VERSION_SIGNATURE"
  [ "$3" = MISSING ] || printf '%s' "$3" > "$HDA_VERSION_SIGNATURE"
  export HDA_WGET_FAIL_MATCH HDA_SHIM_UNAME_R HDA_VERSION_SIGNATURE
}

assert_base_with_warning() {
  hda_assert_shim_called wget "$CDN/linux-7.0.tar.xz" \
    "downloads the base 7.0 tarball (output: $(hda_installer_output_oneline))" || return 1
  assert_eq "" "$(hda_shim_calls wget | grep 'linux-7.0.14')" "never asks for 7.0.14" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "warns about the layout mismatch"
}

test_should_use_upstream_point_release_from_signature() {
  setup "$MINT" 0 "$SIG" || return
  run_installer
  hda_assert_shim_called wget "$CDN/linux-7.0.14.tar.xz" \
    "downloads linux-7.0.14 (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "verified linux-7.0.14.tar.xz" "verifies its SHA-256" || return 1
  hda_assert_shim_called tar "linux-7.0.14/sound/hda" "extracts sound/hda from 7.0.14" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "using mainline kernel 7.0.14 sources" "names the version used" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "no warning when the version is trusted"
}

test_should_warn_and_use_base_when_signature_missing() {
  setup "$MINT" 0 MISSING || return
  run_installer
  assert_base_with_warning
}

test_should_warn_and_use_base_when_signature_has_no_patch_level() {
  setup "$MINT" 0 'Ubuntu 7.0.0-38.38-generic 7.0' || return
  run_installer
  assert_base_with_warning
}

test_should_warn_and_use_base_when_signature_is_a_release_candidate() {
  setup "$MINT" 0 'Ubuntu 7.0.0-38.38-generic 7.0.14-rc1' || return
  run_installer
  assert_base_with_warning
}

test_should_warn_and_use_base_when_signature_is_empty() {
  setup "$MINT" 0 '' || return
  run_installer
  assert_base_with_warning
}

test_should_warn_and_use_base_when_major_minor_differs() {
  setup "$MINT" 0 'Ubuntu 6.8.0-38.38-generic 6.8.12' || return
  run_installer
  assert_base_with_warning
}

test_should_warn_and_use_base_when_target_is_not_running_kernel() {
  setup "$MINT" 0 "$SIG" || return
  HDA_SHIM_UNAME_R=7.0.0-40-generic
  run_installer
  assert_base_with_warning
}

test_should_fall_back_to_base_when_stable_download_fails() {
  setup "$MINT" 0 "$SIG" || return
  HDA_WGET_FAIL_MATCH=linux-7.0.14
  export HDA_WGET_FAIL_MATCH
  run_installer
  hda_assert_shim_called wget "$CDN/linux-7.0.14.tar.xz" "tries 7.0.14 first" || return 1
  hda_assert_shim_called wget "$CDN/linux-7.0.tar.xz" "then tries the base release" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "warns about the layout mismatch" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "verified linux-7.0.tar.xz" "verifies the base tarball"
}

test_should_fail_when_stable_and_base_downloads_both_fail() {
  setup "$MINT" 0 "$SIG" || return
  HDA_WGET_FAIL_MATCH=linux-7.0
  export HDA_WGET_FAIL_MATCH
  run_installer
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "nothing is extracted"
}

test_should_fail_closed_on_stable_checksum_mismatch() {
  setup "$MINT" 0 "$SIG" "$(printf '0%.0s' $(seq 64))" || return
  run_installer
  assert_ne 0 "$HDA_INSTALLER_RC" "exits non-zero on a checksum mismatch" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "SHA-256 mismatch" "states the mismatch" || return 1
  assert_eq "" "$(hda_shim_calls tar)" "nothing is extracted" || return 1
  assert_eq "" "$(hda_shim_calls make)" "nothing is built or installed"
}

test_should_not_read_signature_on_non_ubuntu() {
  setup "$PLAIN" 0 "$SIG" || return
  run_installer
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "using mainline" "prints no fallback note" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "prints no layout warning" || return 1
  assert_eq "" "$(hda_shim_calls wget | grep 'linux-7.0.14')" "never asks for 7.0.14"
}

test_should_not_consult_signature_when_package_present() {
  setup "$MINT" 1 "$SIG" || return
  run_installer
  hda_assert_shim_called tar "linux-source-7.0.0.tar.bz2" "extracts from the package" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no download is attempted" || return 1
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "$WARNING" "prints no layout warning"
}

test_should_use_upstream_point_release_from_signature
test_should_warn_and_use_base_when_signature_missing
test_should_warn_and_use_base_when_signature_has_no_patch_level
test_should_warn_and_use_base_when_signature_is_a_release_candidate
test_should_warn_and_use_base_when_signature_is_empty
test_should_warn_and_use_base_when_major_minor_differs
test_should_warn_and_use_base_when_target_is_not_running_kernel
test_should_fall_back_to_base_when_stable_download_fails
test_should_fail_when_stable_and_base_downloads_both_fail
test_should_fail_closed_on_stable_checksum_mismatch
test_should_not_read_signature_on_non_ubuntu
test_should_not_consult_signature_when_package_present

finish
