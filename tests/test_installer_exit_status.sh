#!/usr/bin/env bash
#
# tests/test_installer_exit_status.sh -- the installers must report failure.
#
# This file is listed in tests/xfail.list: every case below fails today, on
# purpose.  It is the red half of HDA-05; B1 (HDA-10) is the fix that turns it
# green, and the xfail entry must be deleted in that same change.
#
# What is wrong
# -------------
# All three scripts run under `set -e`, but each one ends a failure path with a
# bare `exit` (or with a command that cannot fail), so a failed install is
# reported to the caller as success:
#
#   dkms.sh:42-44                  `dkms install ...` then `popd > /dev/null`;
#                                  popd's status is the script's status, so a
#                                  failed dkms install exits 0.
#   install.cirrus.driver.sh:73-74 `ls -lA $update_dir` then a bare `exit`;
#                                  the dkms branch exits with ls's status.
#   install.cirrus.driver.pre617.sh:77-78  the same.
#   install.cirrus.driver.sh:203   `[[ $? -ne 0 ]] && echo ... && exit`; the
#                                  bare `exit` after a successful echo is 0.
#   install.cirrus.driver.pre617.sh:219  the same.
#
# A user who runs the installer, sees it fail and then checks `$?` is told the
# install worked.  That is the defect these tests pin down.
#
# How the scripts are driven
# ---------------------------
# See tests/lib/shims.sh.  Each script runs in a throwaway copy of the
# repository with a directory of fake commands first on PATH; the fakes log
# their argv and exit with a status the test chooses.  No root, no kernel tree,
# no network, and the real tree is never touched.
#
# One test function per case, one PASS/FAIL line per case, one outcome per
# test: a case that is blocked on this machine prints BLOCKED and does not
# count as a pass.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

# The kernel releases the shims report.  6.17 is the first release the >= 6.17
# installer handles itself; 5.19 is the newest release the pre-6.17 installer
# claims to implement (install.cirrus.driver.pre617.sh:233-237).
NEW_UNAME=6.17.0
OLD_UNAME=5.19.0

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
hda_sandbox_setup > /dev/null || { echo "cannot build the sandbox" >&2; exit 1; }

# ---------------------------------------------------------------------------
# case 1 -- dkms.sh must not swallow a failed `dkms install`
# ---------------------------------------------------------------------------

# dkms.sh's last command is `popd > /dev/null` (line 44), so the script exits
# with popd's status no matter what `dkms install` did.
test_dkms_sh_dkms_install_failure_exits_nonzero() {
  hda_shim_clear
  hda_shim_rc dkms 1
  hda_assert_installer_nonzero dkms.sh "dkms install failed"
  hda_assert_shim_called dkms "install" \
    "dkms.sh must actually reach the failing 'dkms install'"
  hda_shim_rc_clear dkms
}

# ---------------------------------------------------------------------------
# case 4 -- the installers' dkms branches must not swallow it either
# ---------------------------------------------------------------------------

# install.cirrus.driver.sh:65-74 -- `bash dkms.sh` fails, then the branch ends
# with `ls -lA $update_dir` and a bare `exit`.  The ls shim succeeds (that
# directory exists on a real install), so the status under test is the
# installer's own, not ls's.
test_new_installer_dkms_install_failure_exits_nonzero() {
  hda_shim_clear
  hda_shim_rc dkms 1
  hda_assert_installer_nonzero install.cirrus.driver.sh \
    "dkms install failed (-i)" -i -k "$NEW_UNAME"
  hda_assert_shim_called dkms "install" \
    "the installer must actually reach the failing 'dkms install'"
  hda_shim_rc_clear dkms
}

# install.cirrus.driver.pre617.sh:69-78 -- the same shape.
test_pre617_installer_dkms_install_failure_exits_nonzero() {
  hda_shim_clear
  hda_shim_rc dkms 1
  hda_assert_installer_nonzero install.cirrus.driver.pre617.sh \
    "dkms install failed (-i)" -i -k "$OLD_UNAME"
  hda_assert_shim_called dkms "install" \
    "the installer must actually reach the failing 'dkms install'"
  hda_shim_rc_clear dkms
}

# The remove branches have the same defect: `bash dkms.sh -r` fails, then a
# bare `exit` (install.cirrus.driver.sh:80-88, pre617:89-97).  A failed
# uninstall leaves the user's original kernel module un-restored and still
# reports success.
test_new_installer_dkms_remove_failure_exits_nonzero() {
  hda_shim_clear
  hda_shim_rc dkms 1
  hda_assert_installer_nonzero install.cirrus.driver.sh \
    "dkms remove failed (-r)" -r -k "$NEW_UNAME"
  hda_assert_shim_called dkms "remove" \
    "the installer must actually reach the failing 'dkms remove'"
  hda_shim_rc_clear dkms
}

test_pre617_installer_dkms_remove_failure_exits_nonzero() {
  hda_shim_clear
  hda_shim_rc dkms 1
  hda_assert_installer_nonzero install.cirrus.driver.pre617.sh \
    "dkms remove failed (-r)" -r -k "$OLD_UNAME"
  hda_assert_shim_called dkms "remove" \
    "the installer must actually reach the failing 'dkms remove'"
  hda_shim_rc_clear dkms
}

# ---------------------------------------------------------------------------
# cases 2, 3, 6 -- the non-dkms path
# ---------------------------------------------------------------------------

# The non-dkms path is where `make install` (install.cirrus.driver.sh:314,
# pre617:...) and the `wget`/`tar` kernel-source download (lines 191-208 /
# 207-224) run.  It cannot be reached on this machine: the kernel-headers
# probe at install.cirrus.driver.sh:97-128 (pre617:114-145) is a bash builtin
# on an absolute path, so no PATH shim can influence it, and /usr/src is not
# writable here.  The probe therefore exits 1 before any code under test, and
# an assertion on the exit status would pass for the wrong reason.
#
# The cases are still written out, and run whenever the probe would succeed
# (a Linux box with kernel headers installed), so the coverage appears the
# moment the environment allows it.  No test seam was added to production for
# this story.

# case 2 -- install.cirrus.driver.sh, non-dkms, `make install` fails.
# Current behaviour: `make install` fails, `set -e` is active, but the script
# is inside the `if [[ ! $dkms = true ]]` block whose last command is
# `ls -lA $update_dir` (line 318) -- and the bare `exit` at line 203 is on the
# download path, after an `echo` that succeeds.
test_new_installer_make_install_failure_exits_nonzero() {
  _blocker=$(hda_non_dkms_blocker "$NEW_UNAME")
  if [ -n "$_blocker" ]; then
    hda_blocked "install.cirrus.driver.sh non-dkms, make install failed" "$_blocker"
    return 0
  fi
  hda_shim_clear
  hda_shim_rc make 1
  hda_assert_installer_nonzero install.cirrus.driver.sh \
    "make install failed (non-dkms)" -k "$NEW_UNAME"
  hda_assert_shim_called make "install" \
    "the installer must actually reach the failing 'make install'"
  hda_shim_rc_clear make
}

# case 3 -- install.cirrus.driver.pre617.sh, non-dkms, `make install` fails.
test_pre617_installer_make_install_failure_exits_nonzero() {
  _blocker=$(hda_non_dkms_blocker "$OLD_UNAME")
  if [ -n "$_blocker" ]; then
    hda_blocked "install.cirrus.driver.pre617.sh non-dkms, make install failed" "$_blocker"
    return 0
  fi
  hda_shim_clear
  hda_shim_rc make 1
  hda_assert_installer_nonzero install.cirrus.driver.pre617.sh \
    "make install failed (non-dkms)" -k "$OLD_UNAME"
  hda_assert_shim_called make "install" \
    "the installer must actually reach the failing 'make install'"
  hda_shim_rc_clear make
}

# case 6a -- the kernel-source download fails twice: `wget` fails, then the
# retry fails, and the script takes the `exit` at install.cirrus.driver.sh:203
# (pre617:219).  That `exit` is bare, but it follows `echo ... && exit`, and
# the echo succeeds, so the script exits 0.
test_new_installer_wget_failure_exits_nonzero() {
  _blocker=$(hda_non_dkms_blocker "$NEW_UNAME")
  if [ -n "$_blocker" ]; then
    hda_blocked "install.cirrus.driver.sh non-dkms, wget failed" "$_blocker"
    return 0
  fi
  hda_shim_clear
  hda_shim_rc wget 1
  hda_assert_installer_nonzero install.cirrus.driver.sh \
    "wget failed (kernel source download)" -k "$NEW_UNAME"
  hda_assert_shim_called wget "linux-" \
    "the installer must actually reach the failing 'wget'"
  hda_shim_rc_clear wget
}

test_pre617_installer_wget_failure_exits_nonzero() {
  _blocker=$(hda_non_dkms_blocker "$OLD_UNAME")
  if [ -n "$_blocker" ]; then
    hda_blocked "install.cirrus.driver.pre617.sh non-dkms, wget failed" "$_blocker"
    return 0
  fi
  hda_shim_clear
  hda_shim_rc wget 1
  hda_assert_installer_nonzero install.cirrus.driver.pre617.sh \
    "wget failed (kernel source download)" -k "$OLD_UNAME"
  hda_assert_shim_called wget "linux-" \
    "the installer must actually reach the failing 'wget'"
  hda_shim_rc_clear wget
}

# case 6b -- the download succeeds but the archive cannot be unpacked: `tar`
# fails at install.cirrus.driver.sh:208 (pre617:224) with `set -e` active, so
# this one is expected to exit non-zero today.  It is here as the negative
# control for the wget case above: it shows the harness can observe a failure
# the installer does report, which is what makes the wget case's exit 0
# meaningful rather than an artefact of the sandbox.
test_new_installer_tar_failure_exits_nonzero() {
  _blocker=$(hda_non_dkms_blocker "$NEW_UNAME")
  if [ -n "$_blocker" ]; then
    hda_blocked "install.cirrus.driver.sh non-dkms, tar failed" "$_blocker"
    return 0
  fi
  hda_shim_clear
  hda_shim_rc tar 1
  hda_assert_installer_nonzero install.cirrus.driver.sh \
    "tar failed (kernel source unpack)" -k "$NEW_UNAME"
  hda_assert_shim_called tar "linux-" \
    "the installer must actually reach the failing 'tar'"
  hda_shim_rc_clear tar
}

test_pre617_installer_tar_failure_exits_nonzero() {
  _blocker=$(hda_non_dkms_blocker "$OLD_UNAME")
  if [ -n "$_blocker" ]; then
    hda_blocked "install.cirrus.driver.pre617.sh non-dkms, tar failed" "$_blocker"
    return 0
  fi
  hda_shim_clear
  hda_shim_rc tar 1
  hda_assert_installer_nonzero install.cirrus.driver.pre617.sh \
    "tar failed (kernel source unpack)" -k "$OLD_UNAME"
  hda_assert_shim_called tar "linux-" \
    "the installer must actually reach the failing 'tar'"
  hda_shim_rc_clear tar
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

test_dkms_sh_dkms_install_failure_exits_nonzero
test_new_installer_dkms_install_failure_exits_nonzero
test_pre617_installer_dkms_install_failure_exits_nonzero
test_new_installer_dkms_remove_failure_exits_nonzero
test_pre617_installer_dkms_remove_failure_exits_nonzero
test_new_installer_make_install_failure_exits_nonzero
test_pre617_installer_make_install_failure_exits_nonzero
test_new_installer_wget_failure_exits_nonzero
test_pre617_installer_wget_failure_exits_nonzero
test_new_installer_tar_failure_exits_nonzero
test_pre617_installer_tar_failure_exits_nonzero

hda_blocked_summary

finish
