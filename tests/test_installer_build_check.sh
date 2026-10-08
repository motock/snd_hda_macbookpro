#!/usr/bin/env bash
#
# tests/test_installer_build_check.sh -- the installers must not install a
# module that was never built (HDA-12, S17).
#
# `make` can exit 0 without producing a module: a stale build tree, an object
# the kernel skipped, or a module the kernel compressed.  Both installers ran
# `make install` unconditionally, so a build that produced nothing was
# reported to the user as a successful install.  Each installer now checks,
# between the build `make` and `make install`, that
#
#     build/hda/codecs/cirrus/snd-hda-codec-cs8409.{ko,ko.zst,ko.xz}
#
# exists and is non-empty, and exits non-zero with the directory it searched
# named on stderr when it does not.
#
# How the installers are driven
# -----------------------------
# Same technique as tests/test_tarball_verify.sh.  Three of the installer's
# preconditions are bash builtins on absolute paths -- the kernel-headers
# probe, the /etc/os-release distribution probe and the /lib/modules update
# directory -- so no PATH shim can reach them.  The sandbox *copy* of each
# installer therefore has those paths redirected into the sandbox; the code
# under test (the check between `make` and `make install`) is untouched.
#
# Everything that needs root, a kernel tree or the network is a shim:
#
#   wget   serves a fixture tarball for -P and a matching sha256sums.asc for
#          -O, so the download -> verify -> extract stage succeeds
#   tar    creates the build/hda tree the real extraction would have produced
#   patch  the generic logging shim from tests/lib/shims.sh (exits 0)
#   make   a test-local shim that logs its argv and, when told to, writes the
#          module file -- this is the knob the cases turn
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

# The kernel releases the shims report.  6.17 is the first release the >= 6.17
# installer handles itself; 5.19 is the newest release the pre-6.17 installer
# claims to implement.
NEW_UNAME=6.17.0
OLD_UNAME=5.19.0

# The module the Makefile's object list names (makefiles/Makefile_cirrus:6,
# patch_cirrus/Makefile:5).
MODULE=snd-hda-codec-cs8409

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
FAKE_BIN=$(make_tmpdir)

# ---------------------------------------------------------------------------
# fake wget: HDA_FIXTURE_SUMS is served for -O, HDA_FIXTURE_TARBALL for -P
# ---------------------------------------------------------------------------

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
  cp "$HDA_FIXTURE_TARBALL" "$dir/linux-$HDA_FIXTURE_VERSION.tar.xz"
fi
exit 0
FAKE
chmod +x "$FAKE_BIN/wget"

# ---------------------------------------------------------------------------
# fake tar: creates the build/hda tree the real extraction would have produced
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# fake make: the knob under test
#
#   HDA_MAKE_MODULE      file name to write after the build `make` (unset: the
#                        build produces nothing, which is case 1)
#   HDA_MAKE_MODULE_DIR  directory to write it in
#   HDA_MAKE_EMPTY=1     write a zero-byte file (case 3)
# ---------------------------------------------------------------------------

cat > "$FAKE_BIN/make" <<'FAKE'
#!/bin/bash
printf 'make %s\n' "$*" >> "$HDA_SHIM_LOG"
if [ -n "${HDA_MAKE_MODULE:-}" ]; then
  mkdir -p "$HDA_MAKE_MODULE_DIR" || exit 1
  if [ "${HDA_MAKE_EMPTY:-0}" = "1" ]; then
    : > "$HDA_MAKE_MODULE_DIR/$HDA_MAKE_MODULE"
  else
    printf 'pretend module\n' > "$HDA_MAKE_MODULE_DIR/$HDA_MAKE_MODULE"
  fi
fi
exit "${HDA_SHIM_RC_make:-0}"
FAKE
chmod +x "$FAKE_BIN/make"

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -c1-64
  else
    shasum -a 256 "$1" | cut -c1-64
  fi
}

# new_fixture <version> -- a tarball and a sha256sums.asc that agrees with it,
# so the installer's download -> verify -> extract stage succeeds.
new_fixture() {
  _version=$1
  _work=$(make_tmpdir) || return 1
  mkdir -p "$_work/build" || return 1
  printf 'pretend kernel source\n' > "$_work/build/linux-$_version.tar.xz" || return 1
  _sha=$(sha_of "$_work/build/linux-$_version.tar.xz")
  HDA_FIXTURE_SUMS="$_work/sha256sums.asc"
  HDA_FIXTURE_TARBALL="$_work/pristine.tar.xz"
  HDA_FIXTURE_VERSION=$_version
  cp "$_work/build/linux-$_version.tar.xz" "$HDA_FIXTURE_TARBALL" || return 1
  {
    echo '-----BEGIN PGP SIGNED MESSAGE-----'
    echo 'Hash: SHA256'
    echo
    printf '%s  linux-%s.tar.xz\n' "$_sha" "$_version"
    echo '-----BEGIN PGP SIGNATURE-----'
  } > "$HDA_FIXTURE_SUMS" || return 1
  export HDA_FIXTURE_SUMS HDA_FIXTURE_TARBALL HDA_FIXTURE_VERSION
  return 0
}

# prepare_installer <script> -- a fresh sandbox whose copy of <script> has its
# three absolute-path probes redirected into the sandbox.
prepare_installer() {
  hda_sandbox_setup > /dev/null || return 1
  mkdir -p "$HDA_SANDBOX/fake/linux-headers" || return 1
  # the installer does `mkdir $update_dir` (no -p), so the kernel release
  # directory it would find on a real host must exist here
  mkdir -p "$HDA_SANDBOX/fake/lib/modules/$NEW_UNAME" \
           "$HDA_SANDBOX/fake/lib/modules/$OLD_UNAME" || return 1
  # a distribution that is not Ubuntu, so the installer takes its mainline
  # (download + verify + extract) branch on any host
  printf 'NAME=TestOS\nID=testos\nID_LIKE=testos\n' > "$HDA_SANDBOX/fake/os-release" || return 1
  sed -i.bak \
    -e "s#/usr/src/linux-headers-\${UNAME}#$HDA_SANDBOX/fake/linux-headers#" \
    -e "s#/etc/os-release#$HDA_SANDBOX/fake/os-release#g" \
    -e "s#/lib/modules/#$HDA_SANDBOX/fake/lib/modules/#g" \
    "$HDA_SANDBOX/$1" || return 1
  rm -f "$HDA_SANDBOX/$1.bak"
  grep -q "$HDA_SANDBOX/fake/linux-headers" "$HDA_SANDBOX/$1" || {
    echo "headers probe not redirected in $1" >&2; return 1; }
  grep -q "$HDA_SANDBOX/fake/os-release" "$HDA_SANDBOX/$1" || {
    echo "os-release probe not redirected in $1" >&2; return 1; }
  grep -q "$HDA_SANDBOX/fake/lib/modules" "$HDA_SANDBOX/$1" || {
    echo "update dir not redirected in $1" >&2; return 1; }
  return 0
}

# run_installer <script> <uname> -- run it with the fake wget/tar/make ahead of
# the logging shims.  Sets HDA_INSTALLER_RC and HDA_INSTALLER_OUTPUT.
run_installer() {
  _saved=$HDA_SHIMS
  HDA_SHIMS="$FAKE_BIN:$HDA_SHIMS"
  hda_installer_run "$1" -k "$2"
  HDA_SHIMS=$_saved
  return 0
}

# make_install_calls -- the `make install` lines in the shim log, if any.
make_install_calls() {
  hda_shim_calls make | grep ' install' || true
}

# sandbox_dir -- $HDA_SANDBOX without the double slash make_tmpdir leaves in
# it, so it can be compared with the path the installer prints: the installer
# normalises its own directory with `cd ... && pwd`.
sandbox_dir() {
  ( cd "$HDA_SANDBOX" && pwd )
}

# ---------------------------------------------------------------------------
# case 1 -- `make` exits 0 but produces no module
# ---------------------------------------------------------------------------

installer_rejects_missing_module() {
  _script=$1 _uname=$2
  new_fixture "$_uname" || { assert_eq fixture failed "$_script fixture"; return; }
  prepare_installer "$_script" || { assert_eq prepared failed "$_script sandbox"; return; }
  hda_shim_clear
  HDA_MAKE_MODULE=""
  HDA_MAKE_MODULE_DIR="$HDA_SANDBOX/build/hda/codecs/cirrus"
  export HDA_MAKE_MODULE HDA_MAKE_MODULE_DIR
  run_installer "$_script" "$_uname"
  hda_assert_shim_called make "KERNELRELEASE" \
    "$_script must actually reach the build 'make' (output: $(hda_installer_output_oneline))" || return 1
  assert_ne 0 "$HDA_INSTALLER_RC" \
    "$_script exits non-zero when the build produced no module (output: $(hda_installer_output_oneline))" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$(sandbox_dir)/build/hda/codecs/cirrus" \
    "$_script names the directory it searched" || return 1
  assert_eq "" "$(make_install_calls)" \
    "$_script must not run 'make install' when no module was built" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# case 2 -- `make` produces the module: the installer proceeds to install
# ---------------------------------------------------------------------------

installer_proceeds_when_module_exists() {
  _script=$1 _uname=$2 _ext=$3
  new_fixture "$_uname" || { assert_eq fixture failed "$_script fixture"; return; }
  prepare_installer "$_script" || { assert_eq prepared failed "$_script sandbox"; return; }
  hda_shim_clear
  HDA_MAKE_MODULE="$MODULE.$_ext"
  HDA_MAKE_MODULE_DIR="$HDA_SANDBOX/build/hda/codecs/cirrus"
  export HDA_MAKE_MODULE HDA_MAKE_MODULE_DIR
  run_installer "$_script" "$_uname"
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "not found" \
    "$_script must not report a missing module when $MODULE.$_ext exists" || return 1
  hda_assert_shim_called make " install" \
    "$_script must run 'make install' once the module exists" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# case 3 -- the module file exists but is empty
# ---------------------------------------------------------------------------

installer_rejects_empty_module() {
  _script=$1 _uname=$2
  new_fixture "$_uname" || { assert_eq fixture failed "$_script fixture"; return; }
  prepare_installer "$_script" || { assert_eq prepared failed "$_script sandbox"; return; }
  hda_shim_clear
  HDA_MAKE_MODULE="$MODULE.ko"
  HDA_MAKE_MODULE_DIR="$HDA_SANDBOX/build/hda/codecs/cirrus"
  HDA_MAKE_EMPTY=1
  export HDA_MAKE_MODULE HDA_MAKE_MODULE_DIR HDA_MAKE_EMPTY
  run_installer "$_script" "$_uname"
  unset HDA_MAKE_EMPTY
  assert_ne 0 "$HDA_INSTALLER_RC" \
    "$_script exits non-zero when the module file is empty" || return 1
  assert_contains "$HDA_INSTALLER_OUTPUT" "$(sandbox_dir)/build/hda/codecs/cirrus" \
    "$_script names the directory it searched" || return 1
  assert_eq "" "$(make_install_calls)" \
    "$_script must not run 'make install' when the module file is empty" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# cases
# ---------------------------------------------------------------------------

test_new_installer_rejects_missing_module() {
  installer_rejects_missing_module install.cirrus.driver.sh "$NEW_UNAME"
}

test_pre617_installer_rejects_missing_module() {
  installer_rejects_missing_module install.cirrus.driver.pre617.sh "$OLD_UNAME"
}

test_new_installer_proceeds_when_module_exists() {
  installer_proceeds_when_module_exists install.cirrus.driver.sh "$NEW_UNAME" ko
}

test_pre617_installer_proceeds_when_module_exists() {
  installer_proceeds_when_module_exists install.cirrus.driver.pre617.sh "$OLD_UNAME" ko
}

test_new_installer_accepts_compressed_module() {
  installer_proceeds_when_module_exists install.cirrus.driver.sh "$NEW_UNAME" ko.zst
}

test_pre617_installer_accepts_compressed_module() {
  installer_proceeds_when_module_exists install.cirrus.driver.pre617.sh "$OLD_UNAME" ko.zst
}

test_new_installer_rejects_empty_module() {
  installer_rejects_empty_module install.cirrus.driver.sh "$NEW_UNAME"
}

test_pre617_installer_rejects_empty_module() {
  installer_rejects_empty_module install.cirrus.driver.pre617.sh "$OLD_UNAME"
}

test_new_installer_rejects_missing_module
test_pre617_installer_rejects_missing_module
test_new_installer_proceeds_when_module_exists
test_pre617_installer_proceeds_when_module_exists
test_new_installer_accepts_compressed_module
test_pre617_installer_accepts_compressed_module
test_new_installer_rejects_empty_module
test_pre617_installer_rejects_empty_module

finish
