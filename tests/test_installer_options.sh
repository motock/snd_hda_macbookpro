#!/usr/bin/env bash
#
# tests/test_installer_options.sh -- option parsing of the installers and
# dkms.sh (HDA-38).
#
# A bad invocation (unknown option, option missing its argument, stray
# positional argument) must print a usage line to stderr and exit 2, not
# exit 1 (which the installers also use for "the install failed") and not
# silently carry on.  `-r` / `-u` must still work, and the `dkms remove` they
# trigger must name the target kernel with `-k`: without it dkms removes the
# module from every kernel it was built for.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

TARGET=6.17.0
OLD_TARGET=5.19.0   # the pre-6.17 installer refuses 6.17 and later
SHIM_UNAME=6.8.0-45-generic

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
hda_sandbox_setup > /dev/null || { echo "cannot build the sandbox" >&2; exit 1; }
export HDA_SHIM_UNAME_R=$SHIM_UNAME

# run_split <script> [args...] -- sets RC, STDERR and STDOUT separately.
run_split() {
  _errf=$(make_tmpdir)/stderr
  STDOUT=$( cd "$HDA_SANDBOX" && PATH="$HDA_SHIMS:$PATH" bash "$@" 2>"$_errf" )
  RC=$?
  STDERR=$(cat "$_errf")
}

# assert_usage_error <script> <label> [args...] -- exit 2, usage on stderr.
assert_usage_error() {
  _script=$1
  _label=$2
  shift 2
  hda_shim_clear
  run_split "$_script" "$@"
  assert_eq 2 "$RC" "$_script $_label: exit status"
  assert_contains "$STDERR" "usage:" "$_script $_label: usage line on stderr"
  assert_contains "$STDERR" "-r" "$_script $_label: usage lists -r"
  assert_contains "$STDERR" "-u" "$_script $_label: usage lists -u"
  assert_eq "" "$(hda_shim_calls dkms)" "$_script $_label: dkms must not run"
}

test_unknown_option_exits_2() {
  assert_usage_error dkms.sh "unknown option -x" -x
  assert_usage_error install.cirrus.driver.sh "unknown option -x" -x
  assert_usage_error install.cirrus.driver.pre617.sh "unknown option -x" -x
}

test_missing_option_argument_exits_2() {
  assert_usage_error dkms.sh "-k without argument" -r -k
  assert_usage_error install.cirrus.driver.sh "-k without argument" -k
  assert_usage_error install.cirrus.driver.pre617.sh "-k without argument" -k
}

test_leftover_positional_exits_2() {
  assert_usage_error dkms.sh "stray positional" -r extra
  assert_usage_error install.cirrus.driver.sh "two positionals" -r 6.17.0 extra
  assert_usage_error install.cirrus.driver.pre617.sh "two positionals" -r 5.19.0 extra
}

# every dkms remove in the log carries -k <want>
assert_remove_targets() {
  _want=$1
  _msg=$2
  _calls=$(hda_shim_calls dkms | grep ' remove ')
  assert_contains "$_calls" "remove snd_hda_macbookpro/0.1 -k $_want" "$_msg: remove is kernel-scoped"
  assert_not_contains "$_calls" "--all" "$_msg: no --all"
  assert_eq "" "$(printf '%s\n' "$_calls" | grep -v -- ' -k ')" "$_msg: no remove without -k"
}

test_dkms_sh_remove_passes_target_kernel() {
  for _flag in -r -u; do
    hda_shim_clear
    run_split dkms.sh "$_flag" -k "$TARGET"
    assert_eq 0 "$RC" "dkms.sh $_flag -k: exit status"
    assert_remove_targets "$TARGET" "dkms.sh $_flag -k $TARGET"
  done
}

test_dkms_sh_remove_defaults_to_running_kernel() {
  hda_shim_clear
  run_split dkms.sh -r
  assert_eq 0 "$RC" "dkms.sh -r: exit status"
  assert_remove_targets "$SHIM_UNAME" "dkms.sh -r"
}

test_installers_remove_the_kernel_they_target() {
  for _pair in "install.cirrus.driver.sh $TARGET" "install.cirrus.driver.pre617.sh $OLD_TARGET"; do
    _s=${_pair% *}
    _t=${_pair#* }
    for _flag in -r -u; do
      hda_shim_clear
      run_split "$_s" "$_flag" -k "$_t"
      assert_eq 0 "$RC" "$_s $_flag -k: exit status"
      assert_remove_targets "$_t" "$_s $_flag -k $_t"
    done
    hda_shim_clear
    run_split "$_s" -r "$_t"
    assert_eq 0 "$RC" "$_s -r <positional>: exit status"
    assert_remove_targets "$_t" "$_s -r $_t"
  done
}

test_dkms_sh_install_still_works() {
  hda_shim_clear
  run_split dkms.sh
  assert_eq 0 "$RC" "dkms.sh (install): exit status"
  assert_contains "$(hda_shim_calls dkms)" "install" "dkms.sh (install): dkms install called"
}

test_unknown_option_exits_2
test_missing_option_argument_exits_2
test_leftover_positional_exits_2
test_dkms_sh_remove_passes_target_kernel
test_dkms_sh_remove_defaults_to_running_kernel
test_installers_remove_the_kernel_they_target
test_dkms_sh_install_still_works

finish
