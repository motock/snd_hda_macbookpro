#!/usr/bin/env bash
#
# tests/test_pre617_version_gate.sh -- which installer accepts which kernel.
#
#   install.cirrus.driver.pre617.sh  accepts kernels strictly below 6.17 and
#                                    points everything else at
#                                    install.cirrus.driver.sh
#   install.cirrus.driver.sh         handles >= 6.17 itself and hands anything
#                                    older to install.cirrus.driver.pre617.sh
#
# Both gate on the requested release (-k, else the positional argument, else
# `uname -r`) with version_lt (lib/kernel_version.sh).  The uname shim
# (HDA_SHIM_UNAME_R) supplies the release; one row also uses -k.
#
# An accepted row is one that gets past the gate: the output carries neither
# the pointer message nor the invalid-release message.  What the installer does
# afterwards (kernel headers probe, build) is covered elsewhere.
#
# Numeric comparison matters: 6.9 is below 6.17 and 6.100 is above it, but a
# naive string comparison gets both backwards ("6.9" > "6.17" because '9' > '1',
# and "6.100" < "6.17" because '0' < '7').
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
hda_sandbox_setup > /dev/null || { echo "cannot build the sandbox" >&2; exit 1; }

# The pre-6.17 installer stages its dkms tree under /usr/src; keep it in the sandbox.
SND_HDA_USR_SRC=$(make_tmpdir) || { echo "cannot build the staging dir" >&2; exit 1; }
export SND_HDA_USR_SRC

POINTER="use install.cirrus.driver.sh"
INVALID="invalid kernel release"

# run_gate <script> <uname-release> -- the shimmed `uname -r` reports the release.
run_gate() {
  hda_shim_clear
  HDA_SHIM_UNAME_R=$2 hda_installer_run "$1"
}

assert_accepts() {
  run_gate "$1" "$2"
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "$POINTER" "$1 $2: must not be pointed elsewhere"
  assert_not_contains "$HDA_INSTALLER_OUTPUT" "$INVALID" "$1 $2: must not be called invalid"
}

assert_rejects_with_pointer() {
  run_gate "$1" "$2"
  assert_ne 0 "$HDA_INSTALLER_RC" "$1 $2: must exit non-zero"
  assert_contains "$HDA_INSTALLER_OUTPUT" "$POINTER" "$1 $2: must name the other installer"
}

assert_rejects_as_invalid() {
  run_gate "$1" "$2"
  assert_ne 0 "$HDA_INSTALLER_RC" "$1 $2: must exit non-zero"
  assert_contains "$HDA_INSTALLER_OUTPUT" "$INVALID" "$1 $2: must say the release is invalid"
}

OLD=install.cirrus.driver.pre617.sh
NEW=install.cirrus.driver.sh

# --- pre-6.17 installer -----------------------------------------------------

test_pre617_should_accept_5_15_0() { assert_accepts $OLD 5.15.0; }
test_pre617_should_accept_ubuntu_6_8_0_45_generic() { assert_accepts $OLD 6.8.0-45-generic; }
test_pre617_should_accept_6_16_9() { assert_accepts $OLD 6.16.9; }
test_pre617_should_accept_two_part_6_9() { assert_accepts $OLD 6.9; }
test_pre617_should_reject_6_17_0_with_pointer() { assert_rejects_with_pointer $OLD 6.17.0; }
test_pre617_should_reject_6_17_1() { assert_rejects_with_pointer $OLD 6.17.1; }
test_pre617_should_reject_7_0_1() { assert_rejects_with_pointer $OLD 7.0.1; }
test_pre617_should_reject_6_100_numerically() { assert_rejects_with_pointer $OLD 6.100.0; }
test_pre617_should_reject_garbage_release() { assert_rejects_as_invalid $OLD abc; }

test_pre617_should_gate_on_the_k_override() {
  hda_shim_clear
  HDA_SHIM_UNAME_R=5.15.0 hda_installer_run $OLD -k 6.17.0
  assert_ne 0 "$HDA_INSTALLER_RC" "-k 6.17.0 must be rejected although uname says 5.15.0"
  assert_contains "$HDA_INSTALLER_OUTPUT" "$POINTER" "-k 6.17.0 must name the other installer"
}

# --- >= 6.17 installer ------------------------------------------------------

test_new_should_accept_6_17_0() { assert_accepts $NEW 6.17.0; }
test_new_should_accept_6_17_1() { assert_accepts $NEW 6.17.1; }
test_new_should_accept_7_0_1() { assert_accepts $NEW 7.0.1; }
test_new_should_accept_6_100_numerically() { assert_accepts $NEW 6.100.0; }
test_new_should_reject_garbage_release() { assert_rejects_as_invalid $NEW abc; }

# Older kernels are handed to the pre-6.17 installer, which must accept them
# (not bounce them back).
test_new_should_hand_5_15_0_to_pre617() { assert_accepts $NEW 5.15.0; }
test_new_should_hand_two_part_6_9_to_pre617() { assert_accepts $NEW 6.9; }
test_new_should_hand_6_16_9_to_pre617() { assert_accepts $NEW 6.16.9; }

test_pre617_should_accept_5_15_0
test_pre617_should_accept_ubuntu_6_8_0_45_generic
test_pre617_should_accept_6_16_9
test_pre617_should_accept_two_part_6_9
test_pre617_should_reject_6_17_0_with_pointer
test_pre617_should_reject_6_17_1
test_pre617_should_reject_7_0_1
test_pre617_should_reject_6_100_numerically
test_pre617_should_reject_garbage_release
test_pre617_should_gate_on_the_k_override
test_new_should_accept_6_17_0
test_new_should_accept_6_17_1
test_new_should_accept_7_0_1
test_new_should_accept_6_100_numerically
test_new_should_reject_garbage_release
test_new_should_hand_5_15_0_to_pre617
test_new_should_hand_two_part_6_9_to_pre617
test_new_should_hand_6_16_9_to_pre617

finish
