#!/usr/bin/env bash
#
# tests/test_installer_cwd_independence.sh -- the installers must not depend on
# the directory they are launched from (HDA-14, S11).
#
# Both installers used a relative build dir (`build_dir='build'`,
# `--directory=build/`, `wget -P build`) and ran `make` in whatever the current
# directory was, so running one from anywhere but the checkout created build/
# in the wrong place and built the wrong tree.  They now resolve the repo root
# once and use absolute paths derived from it.
#
# How the installers are driven: as in tests/test_installer_build_check.sh --
# the sandbox copy has its three absolute-path probes redirected, and wget, tar
# and make are shims.  Unlike the generic shims, the fake tar and wget honour a
# *relative* destination against the cwd they are called in, so a relative path
# in the installer lands in the foreign cwd where the test can see it.
#
# Cases (for each installer)
#   1  run from an empty foreign dir: it stays empty (negative)
#   2  every tar --directory, wget -P and make -C argument is absolute and
#      under the sandbox copy
#   3  the normalised shim log equals that of a run from inside the repo
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

NEW_UNAME=6.17.0
OLD_UNAME=5.19.0
MODULE=snd-hda-codec-cs8409

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
FAKE_BIN=$(make_tmpdir)

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
  cp "$HDA_FIXTURE_SUMS" "$out" || exit 8
elif [ -n "$dir" ]; then
  mkdir -p "$dir" && cp "$HDA_FIXTURE_TARBALL" "$dir/linux-$HDA_FIXTURE_VERSION.tar.xz" || exit 8
fi
exit 0
FAKE

# the extraction target is resolved against the cwd, like the real tar
cat > "$FAKE_BIN/tar" <<'FAKE'
#!/bin/bash
printf 'tar %s\n' "$*" >> "$HDA_SHIM_LOG"
dest=""
for a in "$@"; do
  case $a in --directory=*) dest=${a#--directory=} ;; esac
done
[ -n "$dest" ] || exit 1
hda="$dest/hda"
mkdir -p "$hda/common" "$hda/codecs/cirrus" || exit 1
for f in Makefile common/Makefile codecs/Makefile codecs/cirrus/Makefile; do
  : > "$hda/$f"
done
exit 0
FAKE

# make logs its argv and, as if the build succeeded, writes the module into the
# sandbox
cat > "$FAKE_BIN/make" <<'FAKE'
#!/bin/bash
printf 'make %s\n' "$*" >> "$HDA_SHIM_LOG"
mkdir -p "$HDA_MAKE_MODULE_DIR" && printf 'pretend module\n' > "$HDA_MAKE_MODULE_DIR/$HDA_MAKE_MODULE" || exit 1
exit 0
FAKE
chmod +x "$FAKE_BIN/wget" "$FAKE_BIN/tar" "$FAKE_BIN/make"

sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -c1-64
  else
    shasum -a 256 "$1" | cut -c1-64
  fi
}

new_fixture() {
  _version=$1
  _work=$(make_tmpdir) || return 1
  printf 'pretend kernel source\n' > "$_work/pristine.tar.xz" || return 1
  _sha=$(sha_of "$_work/pristine.tar.xz")
  HDA_FIXTURE_SUMS="$_work/sha256sums.asc"
  HDA_FIXTURE_TARBALL="$_work/pristine.tar.xz"
  HDA_FIXTURE_VERSION=$_version
  {
    echo '-----BEGIN PGP SIGNED MESSAGE-----'
    echo 'Hash: SHA256'
    echo
    printf '%s  linux-%s.tar.xz\n' "$_sha" "$_version"
    echo '-----BEGIN PGP SIGNATURE-----'
  } > "$HDA_FIXTURE_SUMS" || return 1
  export HDA_FIXTURE_SUMS HDA_FIXTURE_TARBALL HDA_FIXTURE_VERSION
}

prepare_installer() {
  hda_sandbox_setup > /dev/null || return 1
  mkdir -p "$HDA_SANDBOX/fake/linux-headers" \
           "$HDA_SANDBOX/fake/lib/modules/$NEW_UNAME" \
           "$HDA_SANDBOX/fake/lib/modules/$OLD_UNAME" || return 1
  printf 'NAME=TestOS\nID=testos\nID_LIKE=testos\n' > "$HDA_SANDBOX/fake/os-release" || return 1
  for _s in install.cirrus.driver.sh install.cirrus.driver.pre617.sh; do
    sed -i.bak \
      -e "s#/usr/src/linux-headers-\${UNAME}#$HDA_SANDBOX/fake/linux-headers#" \
      -e "s#/etc/os-release#$HDA_SANDBOX/fake/os-release#g" \
      -e "s#/lib/modules/#$HDA_SANDBOX/fake/lib/modules/#g" \
      "$HDA_SANDBOX/$_s" || return 1
    rm -f "$HDA_SANDBOX/$_s.bak"
  done
  HDA_MAKE_MODULE=$MODULE.ko
  HDA_MAKE_MODULE_DIR="$HDA_SANDBOX/build/hda/codecs/cirrus"
  export HDA_MAKE_MODULE HDA_MAKE_MODULE_DIR
}

# run_from <script> <uname> <cwd> -- run the sandbox copy of <script> by
# absolute path from <cwd>, with the fake wget/tar/make ahead of the shims.
run_from() {
  HDA_INSTALLER_OUTPUT=$( cd "$3" && PATH="$FAKE_BIN:$HDA_SHIMS:$PATH" bash "$HDA_SANDBOX/$1" -k "$2" 2>&1 )
  HDA_INSTALLER_RC=$?
}

# run_case <script> <uname> <where> -- fresh sandbox, run from <where> (repo or
# foreign).  Sets CASE_SANDBOX, CASE_CWD, CASE_LOG (the shim log, with the
# sandbox path replaced by @REPO@) and the exit status.
run_case() {
  new_fixture "$2" || return 1
  prepare_installer || return 1
  hda_shim_clear
  CASE_SANDBOX=$(cd "$HDA_SANDBOX" && pwd)
  if [ "$3" = repo ]; then
    CASE_CWD=$HDA_SANDBOX
  else
    CASE_CWD=$(make_tmpdir) || return 1
  fi
  run_from "$1" "$2" "$CASE_CWD"
  CASE_LOG=$(grep -E '^(tar|wget|make) ' "$HDA_SHIM_LOG" | sed -e "s#$CASE_SANDBOX#@REPO@#g" -e 's#^\(wget -q -O\) [^ ]*#\1 @TMP@#')
}

# tool_paths -- the path operands of tar/wget/make in the log, one per line
tool_paths() {
  printf '%s\n' "$CASE_LOG" | while read -r _tool _rest; do
    case $_tool in
      tar) for _w in $_rest; do case $_w in --directory=*) printf '%s\n' "${_w#--directory=}" ;; esac; done ;;
      wget) _prev=""; for _w in $_rest; do [ "$_prev" = -P ] && printf '%s\n' "$_w"; _prev=$_w; done ;;
      make) _prev=""; for _w in $_rest; do [ "$_prev" = -C ] && printf '%s\n' "$_w"; _prev=$_w; done ;;
    esac
  done
}

check_installer() {
  _script=$1 _uname=$2
  run_case "$_script" "$_uname" foreign || { assert_eq ran failed "$_script foreign run"; return; }
  assert_eq 0 "$HDA_INSTALLER_RC" "$_script exits 0 from a foreign cwd (output: $(hda_installer_output_oneline))"
  assert_eq "" "$(ls -A "$CASE_CWD")" "$_script creates nothing in the foreign cwd"
  _paths=$(tool_paths)
  assert_contains "$_paths" "@REPO@/build" "$_script passes absolute build paths to tar/wget"
  assert_contains "$(printf '%s\n' "$CASE_LOG" | grep '^make ')" "-C @REPO@" "$_script runs make -C <repo>"
  assert_eq "" "$(printf '%s\n' "$_paths" | grep -vE '^@REPO@(/|$)')" "$_script logs no relative or foreign tar/wget/make path"
  _foreign_log=$CASE_LOG
  run_case "$_script" "$_uname" repo || { assert_eq ran failed "$_script repo run"; return; }
  assert_eq "$CASE_LOG" "$_foreign_log" "$_script behaves identically from inside the repo"
}

test_new_installer() { check_installer install.cirrus.driver.sh "$NEW_UNAME"; }
test_pre617_installer() { check_installer install.cirrus.driver.pre617.sh "$OLD_UNAME"; }

test_new_installer
test_pre617_installer

finish
