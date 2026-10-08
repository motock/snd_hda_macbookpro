#!/usr/bin/env bash
#
# tests/test_shell_quoting.sh -- the installers must treat every path and
# kernel release as ONE argument (HDA-37, N22).
#
# Unquoted expansions in install.cirrus.driver.sh / .pre617.sh split a repo
# path containing a space into several arguments to tar, wget, make, cp and mv.
# The installers are driven through the same sandbox + shim scheme as
# tests/test_installer_cwd_independence.sh, but the shims here log argv with
# each argument in [brackets], so "one argument" is observable: the generic
# shim in tests/lib/shims.sh joins arguments with spaces and cannot tell
# `/tmp/with space/x` from two arguments.
#
# Cases
#   1  repo under "/tmp/with space.XXXXXX": the installer exits 0 and every
#      --directory=, -P and -C operand logged is the whole sandbox path, never
#      a fragment of it (negative: fails on the unquoted code)
#   2  repo under a plain path: the normalised argv log equals the golden
#      recorded from the pre-quoting scripts, tests/golden/installer_argv.txt
#      (behaviour preserved).  HDA_WRITE_GOLDEN=1 re-records it.
#
# Exit codes: 0 pass, 1 fail.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

GOLDEN="$(cd "$(dirname "$0")" && pwd)/golden/installer_argv.txt"
NEW_UNAME=6.17.0
OLD_UNAME=5.19.0
MODULE=snd-hda-codec-cs8409

FAKE_BIN=$(make_tmpdir)

# every fake logs "cmd [arg1] [arg2] ..." so argument boundaries are visible
for _c in tar wget make patch ls; do
  cat > "$FAKE_BIN/$_c" <<'FAKE'
#!/bin/bash
_cmd=${0##*/}
{ printf '%s' "$_cmd"; for _a in "$@"; do printf ' [%s]' "$_a"; done; printf '\n'; } >> "$HDA_SHIM_LOG"
case $_cmd in
  wget)
    dir="" out=""
    while [ $# -gt 0 ]; do
      case $1 in -P) dir=$2; shift ;; -O) out=$2; shift ;; esac
      shift
    done
    if [ -n "$out" ]; then
      cp "$HDA_FIXTURE_SUMS" "$out" || exit 8
    elif [ -n "$dir" ]; then
      mkdir -p "$dir" && cp "$HDA_FIXTURE_TARBALL" "$dir/linux-$HDA_FIXTURE_VERSION.tar.xz" || exit 8
    fi
    ;;
  tar)
    dest=""
    for a in "$@"; do
      case $a in --directory=*) dest=${a#--directory=} ;; esac
    done
    [ -n "$dest" ] || exit 1
    mkdir -p "$dest/hda/common" "$dest/hda/codecs/cirrus" || exit 1
    for f in Makefile common/Makefile codecs/Makefile codecs/cirrus/Makefile; do : > "$dest/hda/$f"; done
    ;;
  make)
    mkdir -p "$HDA_MAKE_MODULE_DIR" && printf 'pretend module\n' > "$HDA_MAKE_MODULE_DIR/$HDA_MAKE_MODULE" || exit 1
    ;;
esac
exit 0
FAKE
  chmod +x "$FAKE_BIN/$_c"
done

sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -c1-64
  else
    shasum -a 256 "$1" | cut -c1-64
  fi
}

# new_fixture <kernel version> -- a tarball plus a matching signed sums file
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

# run_in <parent dir> <script> <uname> -- copy the repo to <parent>/repo, point
# the installer's absolute-path probes into it, run it.  Sets RUN_LOG (the
# argv log with the repo path replaced by @REPO@) and HDA_INSTALLER_RC.
run_in() {
  _parent=$1 _script=$2 _uname=$3
  new_fixture "$_uname" || return 1
  hda_sandbox_setup > /dev/null || return 1
  mkdir -p "$_parent" && cp -R "$HDA_SANDBOX" "$_parent/repo" || return 1
  _repo=$(cd "$_parent/repo" && pwd) || return 1
  mkdir -p "$_repo/fake/linux-headers" "$_repo/fake/lib/modules/$_uname" || return 1
  # os-release stays outside the spaced path: the installers' `grep` of
  # /etc/os-release takes a constant path, so only this redirect could split it
  _osrel=$(make_tmpdir)/os-release
  printf 'NAME=TestOS\nID=testos\nID_LIKE=testos\n' > "$_osrel" || return 1
  for _s in install.cirrus.driver.sh install.cirrus.driver.pre617.sh; do
    sed -i.bak \
      -e "s#/usr/src/linux-headers-\${UNAME}#$_repo/fake/linux-headers#" \
      -e "s#/etc/os-release#$_osrel#g" \
      -e "s#/lib/modules/#$_repo/fake/lib/modules/#g" \
      "$_repo/$_s" || return 1
    rm -f "$_repo/$_s.bak"
  done
  HDA_MAKE_MODULE=$MODULE.ko
  HDA_MAKE_MODULE_DIR="$_repo/build/hda/codecs/cirrus"
  export HDA_MAKE_MODULE HDA_MAKE_MODULE_DIR
  hda_shim_clear
  HDA_INSTALLER_OUTPUT=$( cd "$_repo" && PATH="$FAKE_BIN:$PATH" bash "$_repo/$_script" -k "$_uname" 2>&1 )
  HDA_INSTALLER_RC=$?
  RUN_REPO=$_repo
  RUN_LOG=$(grep -E '^(tar|wget|make|patch|ls) ' "$HDA_SHIM_LOG" | sed -e "s#$_repo#@REPO@#g" -e 's#\(wget \[-q\] \[-O\]\) \[[^]]*\]#\1 [@TMP@]#')
}

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }

# scenarios: "<label> <script> <uname>"
SCENARIOS="new:install.cirrus.driver.sh:$NEW_UNAME pre617:install.cirrus.driver.pre617.sh:$OLD_UNAME dispatch:install.cirrus.driver.sh:$OLD_UNAME"

# path operands (--directory=, -P, -C) of tar/wget/make in the log
operand_paths() {
  printf '%s\n' "$1" | sed -n \
    -e 's/^tar .*\[--directory=\([^]]*\)\].*$/\1/p' \
    -e 's/^wget .*\[-P\] \[\([^]]*\)\].*$/\1/p' \
    -e 's/^make \[-C\] \[\([^]]*\)\].*$/\1/p'
}

test_space_in_path() {
  _label=$1 _script=$2 _uname=$3
  _base=$(mktemp -d "/tmp/with space.XXXXXX") || { assert_eq ran failed "$_label mktemp"; return; }
  run_in "$_base" "$_script" "$_uname" || { assert_eq ran failed "$_label setup"; return; }
  assert_eq 0 "$HDA_INSTALLER_RC" "$_label: installer exits 0 under a path with a space (output: $(hda_installer_output_oneline))"
  _ops=$(operand_paths "$RUN_LOG")
  assert_contains "$_ops" "@REPO@/build" "$_label: tar/wget get the build dir as one argument"
  assert_eq "" "$(printf '%s\n' "$_ops" | grep -vE '^@REPO@(/|$)')" "$_label: no path operand is a fragment of the repo path"
  rm -rf "$_base"
}

record_or_diff() {
  _out=""
  for _sc in $SCENARIOS; do
    IFS=: read -r _label _script _uname <<< "$_sc"
    _base=$(make_tmpdir) || return 1
    run_in "$_base" "$_script" "$_uname" || return 1
    _out="$_out## $_label ($_script -k $_uname) rc=$HDA_INSTALLER_RC
$RUN_LOG
"
  done
  if [ "${HDA_WRITE_GOLDEN:-0}" = 1 ]; then
    mkdir -p "$(dirname "$GOLDEN")" && printf '%s' "$_out" > "$GOLDEN"
    return
  fi
  assert_eq "$(cat "$GOLDEN")" "${_out%$'\n'}" "argv logs match the pre-quoting golden ($GOLDEN)"
}

for _sc in $SCENARIOS; do
  IFS=: read -r _l _s _u <<< "$_sc"
  test_space_in_path "$_l" "$_s" "$_u"
done
record_or_diff

finish
