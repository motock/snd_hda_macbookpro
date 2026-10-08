#!/usr/bin/env bash
#
# tests/test_installer_exit_status_controls.sh -- positive controls for
# tests/test_installer_exit_status.sh.
#
# The failure-reporting tests live in their own file because the runner is
# per-file: that file is in tests/xfail.list (every case in it fails until B1 /
# HDA-10 lands), and an xfail entry marks the *whole file*.  These controls must
# stay green today, so they cannot share a file with it.
#
# What is controlled
# ------------------
# With every shim succeeding, each script must exit 0.  Without this, a
# "must exit non-zero" assertion is worthless: a script that always fails, or
# a sandbox that breaks the script before it reaches the code under test, would
# satisfy it.  Together the two files say "exits 0 when everything works, and
# non-zero when the thing it depends on fails".
#
# The scripts are driven exactly as in the failure tests -- throwaway copy of
# the repository, shim directory first on PATH -- see tests/lib/shims.sh.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

NEW_UNAME=6.17.0
OLD_UNAME=5.19.0

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
hda_sandbox_setup > /dev/null || { echo "cannot build the sandbox" >&2; exit 1; }

# Every shim succeeds unless a test says otherwise.
export HDA_SHIM_RC=0

# ---------------------------------------------------------------------------
# dkms.sh
# ---------------------------------------------------------------------------

# dkms.sh with a working dkms: creates the source symlink, installs, pops back.
test_dkms_sh_success_exits_zero() {
  hda_shim_clear
  hda_assert_installer_zero dkms.sh "dkms install succeeded"
  hda_assert_shim_called dkms "install" \
    "dkms.sh must actually call 'dkms install'"
}

# dkms.sh -r with a working dkms: removes the module and the source symlink.
test_dkms_sh_remove_success_exits_zero() {
  hda_shim_clear
  hda_assert_installer_zero dkms.sh "dkms remove succeeded" -r
  hda_assert_shim_called dkms "remove" \
    "dkms.sh -r must actually call 'dkms remove'"
}

# ---------------------------------------------------------------------------
# install.cirrus.driver.sh (>= 6.17)
# ---------------------------------------------------------------------------

test_new_installer_dkms_install_success_exits_zero() {
  hda_shim_clear
  hda_assert_installer_zero install.cirrus.driver.sh \
    "dkms install succeeded (-i)" -i -k "$NEW_UNAME"
  hda_assert_shim_called dkms "install" \
    "the installer must actually call 'dkms install'"
}

test_new_installer_dkms_remove_success_exits_zero() {
  hda_shim_clear
  hda_assert_installer_zero install.cirrus.driver.sh \
    "dkms remove succeeded (-r)" -r -k "$NEW_UNAME"
  hda_assert_shim_called dkms "remove" \
    "the installer must actually call 'dkms remove'"
}

# The >= 6.17 installer hands a pre-6.17 kernel to the old script via exec
# (install.cirrus.driver.sh:40-43).  This is the dispatch, not the old script's
# own behaviour, and it must keep working.
test_new_installer_dispatches_old_kernel_to_pre617() {
  hda_shim_clear
  hda_assert_installer_zero install.cirrus.driver.sh \
    "old kernel dispatched to the pre-6.17 installer (-i)" -i -k "$OLD_UNAME"
  hda_assert_shim_called dkms "install" \
    "the dispatched pre-6.17 installer must actually call 'dkms install'"
}

# ---------------------------------------------------------------------------
# install.cirrus.driver.pre617.sh
# ---------------------------------------------------------------------------

test_pre617_installer_dkms_install_success_exits_zero() {
  hda_shim_clear
  hda_assert_installer_zero install.cirrus.driver.pre617.sh \
    "dkms install succeeded (-i)" -i -k "$OLD_UNAME"
  hda_assert_shim_called dkms "install" \
    "the installer must actually call 'dkms install'"
}

test_pre617_installer_dkms_remove_success_exits_zero() {
  hda_shim_clear
  hda_assert_installer_zero install.cirrus.driver.pre617.sh \
    "dkms remove succeeded (-r)" -r -k "$OLD_UNAME"
  hda_assert_shim_called dkms "remove" \
    "the installer must actually call 'dkms remove'"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

test_dkms_sh_success_exits_zero
test_dkms_sh_remove_success_exits_zero
test_new_installer_dkms_install_success_exits_zero
test_new_installer_dkms_remove_success_exits_zero
test_new_installer_dispatches_old_kernel_to_pre617
test_pre617_installer_dkms_install_success_exits_zero
test_pre617_installer_dkms_remove_success_exits_zero

finish
