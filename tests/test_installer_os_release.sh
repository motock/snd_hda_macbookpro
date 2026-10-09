#!/usr/bin/env bash
#
# tests/test_installer_os_release.sh -- HDA_OS_RELEASE selects the os-release
# file both installers use to detect Ubuntu (CI-OSREL-SEAM).
#
# The seam is `${HDA_OS_RELEASE:-/etc/os-release}`.  Unlike the other installer
# tests, this one does NOT rewrite the os-release path with sed: the variable
# is the thing under test.  Only /usr/src, the headers probe and /lib/modules
# are redirected into the sandbox, and wget/tar are fakes (nothing touches the
# network).
#
# Observable difference between the two paths, with a linux-source package
# present in the sandbox:
#   Ubuntu      tar extracts linux-source-<ver>.tar.bz2, wget is never called
#   non-Ubuntu  wget downloads the mainline tarball, linux-source is ignored
#
# A missing or unreadable HDA_OS_RELEASE behaves exactly as an absent
# /etc/os-release does today: grep fails on stderr, finds nothing, the
# installer treats the host as non-Ubuntu and carries on (the pipeline sits
# inside $(...) in an `[ ]` test, so `set -e` does not fire).
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

NEW=install.cirrus.driver.sh
NEW_UNAME=7.0.0-38-generic
OLD=install.cirrus.driver.pre617.sh
OLD_UNAME=5.19.0

UBUNTU='NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n'
FEDORA='NAME="Fedora Linux"\nID=fedora\n'

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
FAKE_BIN=$(make_tmpdir)

# fake wget: -O serves HDA_FIXTURE_SUMS, -P writes the fixture tarball
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
  cp "$HDA_FIXTURE_SUMS" "$out"
elif [ -n "$dir" ]; then
  cp "$HDA_FIXTURE_TARBALL" "$dir/linux-$HDA_FIXTURE_VERSION.tar.xz"
fi
exit 0
FAKE
chmod +x "$FAKE_BIN/wget"

# fake tar: logs its argv and creates the build/hda trees either installer wants
cat > "$FAKE_BIN/tar" <<'FAKE'
#!/bin/bash
printf 'tar %s\n' "$*" >> "$HDA_SHIM_LOG"
for hda in "$HDA_SANDBOX/build/hda"; do
  mkdir -p "$hda/common" "$hda/codecs/cirrus" || exit 1
  for f in Makefile common/Makefile codecs/Makefile codecs/cirrus/Makefile; do
    : > "$hda/$f"
  done
done
exit 0
FAKE
chmod +x "$FAKE_BIN/tar"

sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi
}

# new_fixture <version> -- a tarball and a matching sums file for linux-<version>
new_fixture() {
  _work=$(make_tmpdir) || return 1
  printf 'pretend kernel source\n' > "$_work/pristine.tar.xz" || return 1
  HDA_FIXTURE_SUMS="$_work/sha256sums.asc"
  HDA_FIXTURE_TARBALL="$_work/pristine.tar.xz"
  HDA_FIXTURE_VERSION=$1
  {
    echo '-----BEGIN PGP SIGNED MESSAGE-----'
    echo 'Hash: SHA256'
    echo
    printf '%s  linux-%s.tar.xz\n' "$(sha_of "$_work/pristine.tar.xz")" "$1"
    echo '-----BEGIN PGP SIGNATURE-----'
  } > "$HDA_FIXTURE_SUMS" || return 1
  export HDA_FIXTURE_SUMS HDA_FIXTURE_TARBALL HDA_FIXTURE_VERSION
}

# prepare_installer <script> <uname> <package-version> [default-os-release-body]
# A sandbox copy with a linux-source-<package-version> package present.  When a
# body is given, the literal default /etc/os-release is redirected to a fixture
# holding it, so the "variable unset" path can be driven without a real host file.
prepare_installer() {
  hda_sandbox_setup > /dev/null || return 1
  _fake="$HDA_SANDBOX/fake"
  mkdir -p "$_fake/linux-headers" "$_fake/usr/src" "$_fake/lib/modules/$2" || return 1
  : > "$_fake/usr/src/linux-source-$3.tar.bz2" || return 1
  sed -i.bak \
    -e "s#/usr/src/linux-headers-\${UNAME}#$_fake/linux-headers#" \
    -e "s#/usr/src/linux-source-#$_fake/usr/src/linux-source-#g" \
    -e "s#/lib/modules/#$_fake/lib/modules/#g" \
    "$HDA_SANDBOX/$1" || return 1
  if [ $# -ge 4 ]; then
    printf '%b' "$4" > "$_fake/default-os-release" || return 1
    sed -i.bak -e "s#:-/etc/os-release}#:-$_fake/default-os-release}#g" "$HDA_SANDBOX/$1" || return 1
  fi
  rm -f "$HDA_SANDBOX/$1.bak"
  grep -q "$_fake/usr/src/linux-source-" "$HDA_SANDBOX/$1" || {
    echo "linux-source probe not redirected in $1" >&2; return 1; }
}

# run_installer <script> <uname>
run_installer() {
  _saved=$HDA_SHIMS
  HDA_SHIMS="$FAKE_BIN:$HDA_SHIMS"
  hda_installer_run "$1" -k "$2"
  HDA_SHIMS=$_saved
}

# osrel_file <body> -- write an os-release fixture, print its path
osrel_file() {
  _p=$(make_tmpdir)/os-release
  printf '%b' "$1" > "$_p" || return 1
  printf '%s\n' "$_p"
}

# drive <script> <uname> <package-version> <mainline-version> [default-body]
# Prepares a sandbox and runs the installer with the caller's HDA_OS_RELEASE.
drive() {
  new_fixture "$4" || { assert_eq fixture failed "fixture"; return 1; }
  prepare_installer "$1" "$2" "$3" ${5+"$5"} || { assert_eq prepared failed "sandbox"; return 1; }
  hda_shim_clear
  run_installer "$1" "$2"
}

assert_ubuntu_path() {
  hda_assert_shim_called tar "linux-source-$1.tar.bz2" \
    "extracts the linux-source package (output: $(hda_installer_output_oneline))" || return 1
  assert_eq "" "$(hda_shim_calls wget)" "no mainline download is attempted"
}

assert_mainline_path() {
  hda_assert_shim_called wget "https://cdn.kernel.org/pub/linux/kernel/" \
    "downloads a mainline tarball (output: $(hda_installer_output_oneline))" || return 1
  assert_not_contains "$(hda_shim_calls tar)" "linux-source-" "does not extract the linux-source package"
}

# --- Ubuntu fixture -> Ubuntu linux-source path ---------------------------

test_should_take_ubuntu_path_for_ubuntu_fixture_in_new_installer() {
  HDA_OS_RELEASE=$(osrel_file "$UBUNTU") || return 1; export HDA_OS_RELEASE
  drive $NEW $NEW_UNAME 7.0.0 7.0 || return
  assert_ubuntu_path 7.0.0
}

test_should_take_ubuntu_path_for_ubuntu_fixture_in_pre617_installer() {
  HDA_OS_RELEASE=$(osrel_file "$UBUNTU") || return 1; export HDA_OS_RELEASE
  drive $OLD $OLD_UNAME 5.19.0 5.19.0 || return
  assert_ubuntu_path 5.19.0
}

# --- Fedora fixture -> mainline download path -----------------------------

test_should_take_mainline_path_for_fedora_fixture_in_new_installer() {
  HDA_OS_RELEASE=$(osrel_file "$FEDORA") || return 1; export HDA_OS_RELEASE
  drive $NEW $NEW_UNAME 7.0.0 7.0.0 || return
  assert_mainline_path
}

test_should_take_mainline_path_for_fedora_fixture_in_pre617_installer() {
  HDA_OS_RELEASE=$(osrel_file "$FEDORA") || return 1; export HDA_OS_RELEASE
  drive $OLD $OLD_UNAME 5.19.0 5.19.0 || return
  assert_mainline_path
}

# --- missing / unreadable file == absent /etc/os-release ------------------
# On such a host `grep` complains on stderr and the host counts as non-Ubuntu.

test_should_treat_missing_file_as_non_ubuntu_in_new_installer() {
  HDA_OS_RELEASE=$(make_tmpdir)/does-not-exist; export HDA_OS_RELEASE
  drive $NEW $NEW_UNAME 7.0.0 7.0.0 || return
  assert_mainline_path || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "does-not-exist: No such file" "grep reports the absent file, as for an absent /etc/os-release"
}

test_should_treat_missing_file_as_non_ubuntu_in_pre617_installer() {
  HDA_OS_RELEASE=$(make_tmpdir)/does-not-exist; export HDA_OS_RELEASE
  drive $OLD $OLD_UNAME 5.19.0 5.19.0 || return
  assert_mainline_path || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "does-not-exist: No such file" "grep reports the absent file, as for an absent /etc/os-release"
}

test_should_treat_unreadable_file_as_non_ubuntu() {
  [ "$(id -u)" -ne 0 ] || { echo "SKIP-CASE: root reads any file"; return 0; }
  HDA_OS_RELEASE=$(osrel_file "$UBUNTU") || return 1; export HDA_OS_RELEASE
  chmod 000 "$HDA_OS_RELEASE" || return 1
  drive $NEW $NEW_UNAME 7.0.0 7.0.0 || return
  assert_mainline_path
}

# --- unset variable falls back to /etc/os-release -------------------------
# The literal default is redirected to a fixture by prepare_installer, so these
# prove the fallback is the `:-` default and an explicit value overrides it.

test_should_use_default_file_when_variable_unset() {
  unset HDA_OS_RELEASE
  drive $NEW $NEW_UNAME 7.0.0 7.0 "$UBUNTU" || return
  assert_ubuntu_path 7.0.0
}

test_should_prefer_variable_over_default_file() {
  HDA_OS_RELEASE=$(osrel_file "$FEDORA") || return 1; export HDA_OS_RELEASE
  drive $NEW $NEW_UNAME 7.0.0 7.0.0 "$UBUNTU" || return
  assert_mainline_path
}

test_should_default_to_etc_os_release_literally() {
  for _s in $NEW $OLD; do
    assert_eq 1 "$(grep -c '^os_release=\${HDA_OS_RELEASE:-/etc/os-release}$' "$(dirname "$0")/../$_s")" "$_s defaults to /etc/os-release"
  done
}

unset HDA_OS_RELEASE
test_should_take_ubuntu_path_for_ubuntu_fixture_in_new_installer
test_should_take_ubuntu_path_for_ubuntu_fixture_in_pre617_installer
test_should_take_mainline_path_for_fedora_fixture_in_new_installer
test_should_take_mainline_path_for_fedora_fixture_in_pre617_installer
test_should_treat_missing_file_as_non_ubuntu_in_new_installer
test_should_treat_missing_file_as_non_ubuntu_in_pre617_installer
test_should_treat_unreadable_file_as_non_ubuntu
test_should_use_default_file_when_variable_unset
test_should_prefer_variable_over_default_file
test_should_default_to_etc_os_release_literally
unset HDA_OS_RELEASE

finish
