#!/usr/bin/env bash
#
# tests/test_installer_no_tracked_mutation.sh -- the installers must leave the
# checkout byte-identical (HDA-13, S10).
#
# install.cirrus.driver.pre617.sh rewrote the tracked dkms.conf in place with
# `sed -i` (and, on the first run, `sed -i.orig`, which additionally left an
# untracked dkms.conf.orig behind).  Nothing required that: dkms.sh runs
# `dkms install -c dkms.conf` from its own directory and symlinks that
# directory into /usr/src, so dkms reads dkms.conf in place.  The installer
# must instead stage a copy of the tree in a temp dir, write the edited
# dkms.conf there and point dkms at the copy; the temp dir must be removed on
# exit (trap ... EXIT), including when the install fails.
#
# How the test drives the installers
# ----------------------------------
# Both installers' dkms branch (`-i -d`) exits before the kernel-headers probe,
# so no absolute path has to be redirected into the sandbox.  The sandbox is a
# real `git init` repository with a committed baseline, which makes
# `git status --porcelain` a faithful "did the installer touch a tracked file"
# probe.
#
# The generic `sed` shim is a no-op, so it is replaced here by a shim that
# performs the edit for real (translating GNU `sed -i[SUFFIX]` into the host
# sed's in-place form).  Without that the pre-fix installer would look harmless
# on macOS, where BSD sed rejects `sed -i`.
#
# The dkms shim records the argv, the path of the config it was pointed at and
# a copy of that config, so the test can assert dkms saw the edited values.
#
# Cases
# -----
#   1  pre-6.17 installer, 5.19 (run twice): exit 0, checkout byte-identical,
#      dkms pointed at a staged copy outside the checkout carrying the edited
#      values, no staging file left behind.
#   2  pre-6.17 installer, 5.12: same contract, module snd-hda-codec-cirrus.
#   3  >= 6.17 installer, 6.17: edits nothing, dkms sees the tracked config
#      unedited, checkout byte-identical.
#   4  pre-6.17 installer with `dkms install` failing: the failure is
#      reported, the checkout is still byte-identical and the staging dir is
#      still removed (the trap fires on failure too).
#   5  pre-6.17 installer, remove branch: the old edits ran before the action
#      branch, so a remove run dirtied the checkout too; it must leave the
#      checkout byte-identical.
#   6  pre-6.17 installer, 5.19: the /usr/src/snd_hda_macbookpro-0.1 symlink
#      dkms.sh creates must not be left dangling when the installer's EXIT trap
#      removes the staged dir it points at, and `dkms.sh -r` must remove it even
#      when it dangles.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

# 5.19 is the newest release the pre-6.17 installer implements; 5.12 is the
# last release whose module is snd-hda-codec-cirrus rather than -cs8409; 6.17
# is the first release the >= 6.17 installer handles itself.
OLD_UNAME=5.19.0
ANCIENT_UNAME=5.12.0
NEW_UNAME=6.17.0

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }

capture_dir=$(make_tmpdir) || exit 1
HDA_DKMS_CONF_CAPTURE="$capture_dir/dkms.conf"
HDA_DKMS_CONF_PATH="$capture_dir/dkms.conf.path"
export HDA_DKMS_CONF_CAPTURE HDA_DKMS_CONF_PATH

# --- sed shim: perform the edit for real, portably -------------------------
_real_sed=$(command -v sed) || { echo "no sed on PATH" >&2; exit 1; }
cat > "$HDA_SHIMS/sed" <<FAKE
#!/bin/bash
printf 'sed %s\n' "\$*" >> "\$HDA_SHIM_LOG"
_args=()
_inplace=0
_suffix=""
for _a in "\$@"; do
  case "\$_a" in
    -i) _inplace=1 ;;
    -i*) _inplace=1; _suffix="\${_a#-i}" ;;
    *) _args+=("\$_a") ;;
  esac
done
if [ "\$_inplace" = 1 ]; then
  if "$_real_sed" --version > /dev/null 2>&1; then
    exec "$_real_sed" "-i\$_suffix" "\${_args[@]}"
  fi
  exec "$_real_sed" -i "\$_suffix" "\${_args[@]}"
fi
exec "$_real_sed" "\${_args[@]}"
FAKE
chmod +x "$HDA_SHIMS/sed" || exit 1

# --- dkms shim: record the config dkms was pointed at ----------------------
# Honours HDA_SHIM_RC_dkms (falling back to HDA_SHIM_RC, default 0) so a case
# can make `dkms install` fail.
cat > "$HDA_SHIMS/dkms" <<'FAKE'
#!/bin/bash
printf 'dkms %s\n' "$*" >> "$HDA_SHIM_LOG"
_cfg=""
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "-c" ]; then _cfg=$_a; fi
  _prev=$_a
done
if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
  cp "$_cfg" "$HDA_DKMS_CONF_CAPTURE"
  printf '%s\n' "$(cd "$(dirname "$_cfg")" && pwd)/$(basename "$_cfg")" > "$HDA_DKMS_CONF_PATH"
fi
_rc=${HDA_SHIM_RC_dkms:-${HDA_SHIM_RC:-0}}
exit "$_rc"
FAKE
chmod +x "$HDA_SHIMS/dkms" || exit 1

# --- /usr/src symlink: fake root plus ln/rm shims ---------------------------
# dkms.sh:48 symlinks the directory it runs from into /usr/src
# (`ln -sfn $cur_dir /usr/src/snd_hda_macbookpro-0.1`) and dkms.sh:35 removes
# that symlink again on uninstall (`rm -f $src_dir`).  /usr/src is not writable
# here (on this host it does not even exist), so the generic no-op `ln` shim is
# replaced by one that performs the real symlink into a fake /usr/src under a
# scratch directory, and an `rm` shim translates the same path so dkms.sh:35's
# removal is observable.  Both log their argv like every other shim.
fake_usr_src_root=$(make_tmpdir) || exit 1
HDA_FAKE_USR_SRC="$fake_usr_src_root/usr-src"
mkdir -p "$HDA_FAKE_USR_SRC" || exit 1
export HDA_FAKE_USR_SRC
src_link="$HDA_FAKE_USR_SRC/snd_hda_macbookpro-0.1"

_real_ln=$(command -v ln) || { echo "no ln on PATH" >&2; exit 1; }
_real_rm=$(command -v rm) || { echo "no rm on PATH" >&2; exit 1; }

cat > "$HDA_SHIMS/ln" <<FAKE
#!/bin/bash
printf 'ln %s\n' "\$*" >> "\$HDA_SHIM_LOG"
_args=()
for _a in "\$@"; do
  case "\$_a" in
    /usr/src/*) _a="\$HDA_FAKE_USR_SRC/\${_a#/usr/src/}" ;;
  esac
  _args+=("\$_a")
done
exec "$_real_ln" "\${_args[@]}"
FAKE
chmod +x "$HDA_SHIMS/ln" || exit 1

cat > "$HDA_SHIMS/rm" <<FAKE
#!/bin/bash
printf 'rm %s\n' "\$*" >> "\$HDA_SHIM_LOG"
_args=()
for _a in "\$@"; do
  case "\$_a" in
    /usr/src/*) _a="\$HDA_FAKE_USR_SRC/\${_a#/usr/src/}" ;;
  esac
  _args+=("\$_a")
done
exec "$_real_rm" "\${_args[@]}"
FAKE
chmod +x "$HDA_SHIMS/rm" || exit 1

hda_sandbox_setup > /dev/null || { echo "cannot build the sandbox" >&2; exit 1; }
sandbox=$HDA_SANDBOX

# A real repository with a committed baseline.
(
  cd "$sandbox" || exit 1
  git init -q . || exit 1
  git config user.email hda-test@example.invalid || exit 1
  git config user.name "HDA test" || exit 1
  git add -A || exit 1
  git commit -qm baseline || exit 1
) || { echo "cannot initialise the sandbox repository" >&2; exit 1; }

tracked_before=$(cat "$sandbox/dkms.conf")

# reset_sandbox -- restore the committed baseline, so each case starts clean
# even if a previous case (or the pre-fix installer) dirtied the tree.
reset_sandbox() {
  ( cd "$sandbox" && git checkout -q -- . && git clean -qfd )
}

# assert_clean <label> -- the checkout must be byte-identical to the baseline.
# `git status --porcelain` covers every tracked file and any untracked litter;
# the dkms.conf.orig check names the old `sed -i.orig` backup explicitly.
assert_clean() {
  _label=$1
  _dirty=$(cd "$sandbox" && git status --porcelain)
  assert_eq "" "$_dirty" "$_label: installer must leave the checkout byte-identical"
  assert_eq "$tracked_before" "$(cat "$sandbox/dkms.conf")" \
    "$_label: tracked dkms.conf must be byte-identical after the run"
  if [ -e "$sandbox/dkms.conf.orig" ]; then
    _hda_fail "$_label: the old 'sed -i.orig' backup dkms.conf.orig must not be left behind"
  fi
}

# assert_no_stale_staging <label> -- the installer's staging directory must be
# removed when the installer exits (trap ... EXIT), so no generated file is
# left behind.  The staging dir is created as ${TMPDIR:-/tmp}/snd-hda-dkms.*.
assert_no_stale_staging() {
  _label=$1
  _stale=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'snd-hda-dkms.*' 2>/dev/null | head -1)
  assert_eq "" "$_stale" "$_label: installer must remove its staging directory on exit"
}

# assert_file_absent <path> <msg>
assert_file_absent() {
  if [ "$#" -lt 2 ]; then
    _hda_fail "assert_file_absent: usage: assert_file_absent <path> <msg>"
    return 1
  fi
  if [ ! -e "$1" ]; then
    return 0
  fi
  _hda_fail "$2 (expected no file '$1', but it exists)"
  return 1
}

# link_state <path> -- absent | dangling | valid.
link_state() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    printf 'absent\n'
  elif [ -L "$1" ] && [ ! -e "$1" ]; then
    printf 'dangling\n'
  else
    printf 'valid\n'
  fi
}

# case_done <label> <failures_before> -- one PASS/FAIL line per case, so a run
# reports what it checked.  <failures_before> is $HDA_ASSERT_FAILURES captured
# at the start of the case.
case_done() {
  if [ "${HDA_ASSERT_FAILURES:-0}" -eq "$2" ]; then
    printf 'PASS: %s\n' "$1"
  else
    printf 'FAIL: %s\n' "$1"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# case 1: pre-6.17 installer, 5.19 -- module name snd-hda-codec-cs8409
# ---------------------------------------------------------------------------

test_pre617_519_leaves_checkout_clean() {
  _failures_before=$HDA_ASSERT_FAILURES
  hda_installer_run install.cirrus.driver.pre617.sh -i -d -k "$OLD_UNAME"

  assert_eq 0 "$HDA_INSTALLER_RC" \
    "pre617 5.19: installer must exit 0 with all shims succeeding (output: $(hda_installer_output_oneline))"
  assert_clean "pre617 5.19"
  assert_no_stale_staging "pre617 5.19"

  # A second run in the same checkout must behave identically: the old
  # `sed -i.orig` left dkms.conf.orig behind, which flipped the script onto its
  # other sed branch on the next run.
  hda_installer_run install.cirrus.driver.pre617.sh -i -d -k "$OLD_UNAME"

  assert_eq 0 "$HDA_INSTALLER_RC" \
    "pre617 5.19 (repeat): installer must exit 0 on a repeat run (output: $(hda_installer_output_oneline))"
  assert_clean "pre617 5.19 (repeat)"
  assert_no_stale_staging "pre617 5.19 (repeat)"

  # dkms must have been pointed at a staged COPY carrying the edited values,
  # never at the tracked $repo/dkms.conf; the copy is removed on exit.
  assert_file_exists "$HDA_DKMS_CONF_CAPTURE" "dkms must have been pointed at a dkms.conf"
  staged=$(cat "$HDA_DKMS_CONF_CAPTURE" 2>/dev/null || true)
  assert_contains "$staged" 'PACKAGE_NAME="snd_hda_macbookpro"' \
    "staged dkms.conf must be a copy of the repo config"
  assert_contains "$staged" 'BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"' \
    "staged dkms.conf must carry the 5.19 module name"
  assert_contains "$staged" 'BUILT_MODULE_LOCATION[0]="build/hda"' \
    "staged dkms.conf must carry the pre-6.17 module location"
  assert_contains "$staged" 'PRE_BUILD="install.cirrus.driver.pre617.sh -k $kernelver --dkms"' \
    "staged dkms.conf must carry the pre-6.17 PRE_BUILD"

  staged_path=$(cat "$HDA_DKMS_CONF_PATH" 2>/dev/null || true)
  assert_ne "$sandbox/dkms.conf" "$staged_path" \
    "dkms must be pointed at a staged copy, not the tracked repo dkms.conf"
  assert_not_contains "$staged_path" "$sandbox" \
    "the staged dkms.conf must live outside the checkout"
  assert_file_absent "$staged_path" \
    "the staged dkms.conf must be removed when the installer exits"
  case_done "pre617 5.19 (two runs)" "$_failures_before"
}

# ---------------------------------------------------------------------------
# case 2: pre-6.17 installer, 5.12 -- module name snd-hda-codec-cirrus
# ---------------------------------------------------------------------------

test_pre617_512_leaves_checkout_clean() {
  _failures_before=$HDA_ASSERT_FAILURES
  reset_sandbox
  : > "$HDA_DKMS_CONF_CAPTURE"
  : > "$HDA_DKMS_CONF_PATH"

  hda_installer_run install.cirrus.driver.pre617.sh -i -d -k "$ANCIENT_UNAME"

  assert_eq 0 "$HDA_INSTALLER_RC" \
    "pre617 5.12: installer must exit 0 (output: $(hda_installer_output_oneline))"
  assert_clean "pre617 5.12"
  assert_no_stale_staging "pre617 5.12"

  staged=$(cat "$HDA_DKMS_CONF_CAPTURE" 2>/dev/null || true)
  assert_contains "$staged" 'BUILT_MODULE_NAME[0]="snd-hda-codec-cirrus"' \
    "staged dkms.conf must carry the 5.12 module name"
  assert_contains "$staged" 'BUILT_MODULE_LOCATION[0]="build/hda"' \
    "staged dkms.conf must carry the pre-6.17 module location"
  assert_contains "$staged" 'PRE_BUILD="install.cirrus.driver.pre617.sh -k $kernelver --dkms"' \
    "staged dkms.conf must carry the pre-6.17 PRE_BUILD"

  staged_path=$(cat "$HDA_DKMS_CONF_PATH" 2>/dev/null || true)
  assert_ne "$sandbox/dkms.conf" "$staged_path" \
    "dkms must be pointed at a staged copy, not the tracked repo dkms.conf"
  assert_file_absent "$staged_path" \
    "the staged dkms.conf must be removed when the installer exits"
  case_done "pre617 5.12" "$_failures_before"
}

# ---------------------------------------------------------------------------
# case 3: >= 6.17 installer -- edits nothing, so dkms sees the tracked config
# ---------------------------------------------------------------------------

test_617_leaves_checkout_clean() {
  _failures_before=$HDA_ASSERT_FAILURES
  reset_sandbox
  : > "$HDA_DKMS_CONF_CAPTURE"
  : > "$HDA_DKMS_CONF_PATH"

  hda_installer_run install.cirrus.driver.sh -i -d -k "$NEW_UNAME"

  assert_eq 0 "$HDA_INSTALLER_RC" \
    "6.17 installer must exit 0 with all shims succeeding (output: $(hda_installer_output_oneline))"
  assert_clean "6.17"

  assert_eq "$tracked_before" "$(cat "$HDA_DKMS_CONF_CAPTURE" 2>/dev/null || true)" \
    "6.17 installer must hand dkms the tracked dkms.conf unedited"
  case_done "6.17" "$_failures_before"
}

# ---------------------------------------------------------------------------
# case 4: pre-6.17 installer with `dkms install` failing -- the failure must be
# reported, the checkout must still be byte-identical, and the staging dir
# must still be removed (the trap ... EXIT fires on failure too)
# ---------------------------------------------------------------------------

test_pre617_failed_install_leaves_checkout_clean() {
  _failures_before=$HDA_ASSERT_FAILURES
  reset_sandbox
  : > "$HDA_DKMS_CONF_CAPTURE"
  : > "$HDA_DKMS_CONF_PATH"

  hda_shim_rc dkms 1
  hda_installer_run install.cirrus.driver.pre617.sh -i -d -k "$OLD_UNAME"
  hda_shim_rc_clear dkms

  assert_ne 0 "$HDA_INSTALLER_RC" \
    "pre617 5.19 (failed install): the installer must report the dkms failure"
  assert_clean "pre617 5.19 (failed install)"
  assert_no_stale_staging "pre617 5.19 (failed install)"

  staged_path=$(cat "$HDA_DKMS_CONF_PATH" 2>/dev/null || true)
  assert_ne "$sandbox/dkms.conf" "$staged_path" \
    "failed install: dkms must not be pointed at the tracked repo dkms.conf"
  assert_file_absent "$staged_path" \
    "failed install: the staged dkms.conf must be removed even when the install fails"
  case_done "pre617 5.19 (failed install)" "$_failures_before"
}

# ---------------------------------------------------------------------------
# case 5: pre-6.17 installer, remove branch -- the old edits ran before the
# action branch, so a remove run dirtied the checkout too; it must leave the
# checkout byte-identical
# ---------------------------------------------------------------------------

test_pre617_remove_leaves_checkout_clean() {
  _failures_before=$HDA_ASSERT_FAILURES
  reset_sandbox

  hda_installer_run install.cirrus.driver.pre617.sh -r -d -k "$OLD_UNAME"

  assert_eq 0 "$HDA_INSTALLER_RC" \
    "pre617 5.19 (remove): installer must exit 0 with all shims succeeding (output: $(hda_installer_output_oneline))"
  assert_clean "pre617 5.19 (remove)"
  assert_no_stale_staging "pre617 5.19 (remove)"
  case_done "pre617 5.19 (remove)" "$_failures_before"
}

# ---------------------------------------------------------------------------
# case 6: the pre-6.17 installer must not leave a dangling /usr/src symlink
# ---------------------------------------------------------------------------
#
# dkms.sh:48 symlinks the directory it runs from into /usr/src.  The pre-6.17
# installer runs dkms.sh from its staged temp dir, so the symlink points there;
# the installer's `trap 'rm -rf "$stage_dir"' EXIT` then deletes that directory
# and leaves the symlink dangling.  dkms.sh:35's uninstall cleanup
# (`[[ -e $src_dir ]] && rm -f $src_dir`) tests -e, which is false for a
# dangling symlink, so the dead link also survives `dkms.sh -r`.  Both are
# regressions against the old behaviour, where the symlink pointed at the
# persistent checkout and was removed on uninstall.

test_pre617_leaves_no_dangling_src_symlink() {
  _failures_before=$HDA_ASSERT_FAILURES
  reset_sandbox
  rm -f "$src_link"

  hda_installer_run install.cirrus.driver.pre617.sh -i -d -k "$OLD_UNAME"

  assert_eq 0 "$HDA_INSTALLER_RC" \
    "pre617 5.19 (src symlink): installer must exit 0 (output: $(hda_installer_output_oneline))"

  # The installer must actually have reached dkms.sh, otherwise the assertions
  # below would be vacuous.
  assert_contains "$(hda_shim_calls dkms)" "dkms install" \
    "pre617 5.19 (src symlink): the installer must have run dkms.sh"
  assert_contains "$(hda_shim_calls ln)" "ln " \
    "pre617 5.19 (src symlink): dkms.sh must have created the /usr/src symlink"

  # The regression: after the installer exits, the symlink must not dangle.
  assert_ne "dangling" "$(link_state "$src_link")" \
    "pre617 5.19 (src symlink): the installer must not leave a dangling $src_link (its EXIT trap deletes the staged dir the symlink points at)"

  # And `dkms.sh -r` must remove it, dangling or not.
  hda_installer_run dkms.sh -r

  assert_eq 0 "$HDA_INSTALLER_RC" \
    "pre617 5.19 (src symlink): dkms.sh -r must exit 0 (output: $(hda_installer_output_oneline))"
  assert_eq "absent" "$(link_state "$src_link")" \
    "pre617 5.19 (src symlink): dkms.sh -r must remove the /usr/src symlink even when it dangles (dkms.sh:35 tests -e, false for a dangling symlink)"

  case_done "pre617 5.19 (src symlink)" "$_failures_before"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

test_pre617_519_leaves_checkout_clean
test_pre617_512_leaves_checkout_clean
test_617_leaves_checkout_clean
test_pre617_failed_install_leaves_checkout_clean
test_pre617_remove_leaves_checkout_clean
test_pre617_leaves_no_dangling_src_symlink

finish
