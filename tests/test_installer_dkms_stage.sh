#!/usr/bin/env bash
#
# tests/test_installer_dkms_stage.sh -- the >= 6.17 installer must hand dkms a
# persistent staged copy of the tree, not the git checkout (DKMS-STAGE).
#
# dkms.sh symlinks the directory it runs from into /usr/src and dkms rebuilds
# from that link on every kernel update (AUTOINSTALL=yes).  Run from the
# checkout, moving or deleting the checkout silently breaks every later rebuild.
# The installer therefore copies the tree to
# $SND_HDA_USR_SRC/snd_hda_macbookpro-0.1.src (default /usr/src), runs dkms.sh
# from the copy, and removes the copy only on a failed install or on uninstall.
# Mirrors the pre-6.17 installer; see tests/test_installer_no_tracked_mutation.sh.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

NEW_UNAME=6.17.0

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }

capture_dir=$(make_tmpdir) || exit 1

# dkms shim: records its working directory and the config it was given.
cat > "$HDA_SHIMS/dkms" <<'FAKE'
#!/bin/bash
printf 'dkms %s\n' "$*" >> "$HDA_SHIM_LOG"
case "$1" in
  install) pwd -P > "$HDA_DKMS_CWD" ;;
esac
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "-c" ] && [ -f "$_a" ]; then cp "$_a" "$HDA_DKMS_CONF_CAPTURE"; fi
  _prev=$_a
done
exit "${HDA_SHIM_RC_dkms:-${HDA_SHIM_RC:-0}}"
FAKE
chmod +x "$HDA_SHIMS/dkms" || exit 1
HDA_DKMS_CWD="$capture_dir/dkms.cwd"
HDA_DKMS_CONF_CAPTURE="$capture_dir/dkms.conf"
export HDA_DKMS_CWD HDA_DKMS_CONF_CAPTURE

# ln/rm shims translate /usr/src into a fake root, as in the no-tracked-mutation test.
fake_root=$(make_tmpdir) || exit 1
HDA_FAKE_USR_SRC="$fake_root/usr-src"
mkdir -p "$HDA_FAKE_USR_SRC" || exit 1
export HDA_FAKE_USR_SRC
src_link="$HDA_FAKE_USR_SRC/snd_hda_macbookpro-0.1"
stage_path="$HDA_FAKE_USR_SRC/snd_hda_macbookpro-0.1.src"
SND_HDA_USR_SRC=$HDA_FAKE_USR_SRC
export SND_HDA_USR_SRC

_real_ln=$(command -v ln) || exit 1
_real_rm=$(command -v rm) || exit 1
for _c in ln rm; do
  _real=$_real_ln; [ "$_c" = rm ] && _real=$_real_rm
  cat > "$HDA_SHIMS/$_c" <<FAKE
#!/bin/bash
printf '$_c %s\n' "\$*" >> "\$HDA_SHIM_LOG"
_args=()
for _a in "\$@"; do
  case "\$_a" in
    /usr/src/*) _a="\$HDA_FAKE_USR_SRC/\${_a#/usr/src/}" ;;
  esac
  _args+=("\$_a")
done
exec "$_real" "\${_args[@]}"
FAKE
  chmod +x "$HDA_SHIMS/$_c" || exit 1
done

hda_sandbox_setup > /dev/null || { echo "cannot build the sandbox" >&2; exit 1; }
sandbox=$HDA_SANDBOX

(
  cd "$sandbox" || exit 1
  git init -q . || exit 1
  git config user.email hda-test@example.invalid || exit 1
  git config user.name "HDA test" || exit 1
  git add -A || exit 1
  git commit -qm baseline || exit 1
) || { echo "cannot initialise the sandbox repository" >&2; exit 1; }

# The sandbox lacks build/ and tests/; add them so staging must skip them.
reset_sandbox() {
  ( cd "$sandbox" && git checkout -q -- . && git clean -qfd )
  mkdir -p "$sandbox/build" "$sandbox/tests"
  : > "$sandbox/build/leftover.o"
  : > "$sandbox/tests/test_x.sh"
  rm -rf "$stage_path" "$src_link"
  : > "$HDA_DKMS_CWD"
}

case_done() {
  if [ "${HDA_ASSERT_FAILURES:-0}" -eq "$2" ]; then
    printf 'PASS: %s\n' "$1"
  else
    printf 'FAIL: %s\n' "$1"
  fi
  return 0
}

link_state() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then printf 'absent\n'
  elif [ -L "$1" ] && [ ! -e "$1" ]; then printf 'dangling\n'
  else printf 'valid\n'
  fi
}

# checkout_status -- git's view of the checkout; build/ and tests/ are fixture
# litter ignored here by excluding them.
checkout_status() {
  ( cd "$sandbox" && git status --porcelain -- . ':!build' ':!tests' )
}

run_install() { hda_installer_run install.cirrus.driver.sh -i -d -k "$NEW_UNAME"; }
run_remove() { hda_installer_run install.cirrus.driver.sh -r -d -k "$NEW_UNAME"; }

test_should_stage_a_copy_and_run_dkms_from_it() {
  _fb=$HDA_ASSERT_FAILURES
  reset_sandbox
  run_install
  assert_eq 0 "$HDA_INSTALLER_RC" "install must exit 0 (output: $(hda_installer_output_oneline))"
  assert_file_exists "$stage_path/dkms.sh" "staged dkms.sh"
  assert_file_exists "$stage_path/install.cirrus.driver.sh" "staged installer"
  assert_file_exists "$stage_path/patch_cirrus" "staged patch_cirrus/"
  assert_eq "$(cat "$sandbox/dkms.conf")" "$(cat "$stage_path/dkms.conf" 2>/dev/null)" \
    "staged dkms.conf must be byte-identical to the tracked one"
  assert_eq "$(cat "$sandbox/dkms.conf")" "$(cat "$HDA_DKMS_CONF_CAPTURE")" \
    "dkms must be handed the unedited dkms.conf"
  assert_eq absent "$([ -e "$stage_path/build" ] && echo present || echo absent)" "build/ must not be staged"
  assert_eq absent "$([ -e "$stage_path/tests" ] && echo present || echo absent)" "tests/ must not be staged"
  assert_eq "$(cd "$stage_path" 2>/dev/null && pwd -P)" "$(cat "$HDA_DKMS_CWD")" \
    "dkms.sh must run with the staged dir as its working directory"
  assert_eq "" "$(checkout_status)" "checkout must be left byte-identical"
  case_done "stage a copy and run dkms from it" "$_fb"
}

test_should_keep_link_valid_after_checkout_moves() {
  _fb=$HDA_ASSERT_FAILURES
  reset_sandbox
  _moved=$(make_tmpdir) || return 1
  cp -R "$sandbox/." "$_moved/work" 2>/dev/null || { mkdir -p "$_moved/work"; cp -R "$sandbox/." "$_moved/work"; }
  _old=$HDA_SANDBOX
  HDA_SANDBOX="$_moved/work"
  run_install
  HDA_SANDBOX=$_old
  assert_eq 0 "$HDA_INSTALLER_RC" "install must exit 0 (output: $(hda_installer_output_oneline))"
  assert_eq valid "$(link_state "$src_link")" "link must resolve after install"
  assert_eq "$(cd "$stage_path" 2>/dev/null && pwd -P)" "$(cd "$src_link" 2>/dev/null && pwd -P)" \
    "link must resolve into the staged dir"
  mv "$_moved/work" "$_moved/renamed"
  assert_eq valid "$(link_state "$src_link")" "link must still resolve after the checkout is moved"
  assert_file_exists "$src_link/dkms.conf" "dkms.conf reachable through the link after the move"
  case_done "link survives checkout move" "$_fb"
}

test_should_remove_stage_and_link_when_install_fails() {
  _fb=$HDA_ASSERT_FAILURES
  reset_sandbox
  hda_shim_rc dkms 1
  run_install
  hda_shim_rc_clear dkms
  assert_ne 0 "$HDA_INSTALLER_RC" "failed dkms install must exit non-zero"
  assert_eq absent "$([ -e "$stage_path" ] && echo present || echo absent)" "staged dir must be removed"
  assert_eq absent "$(link_state "$src_link")" "no dangling /usr/src link may remain"
  case_done "failed install cleans up" "$_fb"
}

test_should_replace_a_stale_staged_dir() {
  _fb=$HDA_ASSERT_FAILURES
  reset_sandbox
  mkdir -p "$stage_path" && : > "$stage_path/stale.txt"
  run_install
  assert_eq 0 "$HDA_INSTALLER_RC" "install must exit 0 (output: $(hda_installer_output_oneline))"
  assert_eq absent "$([ -e "$stage_path/stale.txt" ] && echo present || echo absent)" "stale file must be gone"
  assert_file_exists "$stage_path/dkms.sh" "fresh copy must be staged"
  case_done "stale staged dir replaced" "$_fb"
}

test_should_be_idempotent_across_two_installs() {
  _fb=$HDA_ASSERT_FAILURES
  reset_sandbox
  run_install
  assert_eq 0 "$HDA_INSTALLER_RC" "first install must exit 0 (output: $(hda_installer_output_oneline))"
  run_install
  assert_eq 0 "$HDA_INSTALLER_RC" "second install must exit 0 (output: $(hda_installer_output_oneline))"
  assert_eq 1 "$(ls -d "$HDA_FAKE_USR_SRC"/*.src 2>/dev/null | wc -l | tr -d ' ')" "exactly one staged dir"
  case_done "two installs" "$_fb"
}

test_should_remove_stage_on_uninstall() {
  _fb=$HDA_ASSERT_FAILURES
  reset_sandbox
  run_install
  run_remove
  assert_eq 0 "$HDA_INSTALLER_RC" "remove must exit 0 (output: $(hda_installer_output_oneline))"
  assert_eq absent "$([ -e "$stage_path" ] && echo present || echo absent)" "staged dir must be removed"
  assert_eq absent "$(link_state "$src_link")" "link must be gone"
  case_done "uninstall removes stage" "$_fb"
}

test_should_clear_stage_even_when_dkms_remove_fails() {
  _fb=$HDA_ASSERT_FAILURES
  reset_sandbox
  run_install
  hda_shim_rc dkms 1
  run_remove
  hda_shim_rc_clear dkms
  assert_ne 0 "$HDA_INSTALLER_RC" "failed dkms remove must exit non-zero"
  assert_eq absent "$([ -e "$stage_path" ] && echo present || echo absent)" "staged dir must still be cleared"
  case_done "failed remove still clears stage" "$_fb"
}

test_should_fail_cleanly_when_usr_src_is_uncreatable() {
  _fb=$HDA_ASSERT_FAILURES
  reset_sandbox
  : > "$fake_root/not-a-dir"
  hda_shim_clear
  _saved=$SND_HDA_USR_SRC
  SND_HDA_USR_SRC="$fake_root/not-a-dir/usr-src"
  export SND_HDA_USR_SRC
  run_install
  SND_HDA_USR_SRC=$_saved
  export SND_HDA_USR_SRC
  assert_ne 0 "$HDA_INSTALLER_RC" "uncreatable usr_src must exit non-zero"
  assert_contains "$HDA_INSTALLER_OUTPUT" "cannot create a staging directory" "clear error message"
  assert_eq "" "$(hda_shim_calls dkms)" "dkms must not be called"
  case_done "uncreatable usr_src" "$_fb"
}

test_should_stage_a_copy_and_run_dkms_from_it
test_should_keep_link_valid_after_checkout_moves
test_should_remove_stage_and_link_when_install_fails
test_should_replace_a_stale_staged_dir
test_should_be_idempotent_across_two_installs
test_should_remove_stage_on_uninstall
test_should_clear_stage_even_when_dkms_remove_fails
test_should_fail_cleanly_when_usr_src_is_uncreatable

finish
