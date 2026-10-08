#!/usr/bin/env bash
#
# tests/test_installer_stale_module.sh -- the installers must remove a stale
# non-dkms cs8409 module in every compression, not just the bare .ko (HDA-16).
#
# The installers cannot be run whole without root and a kernel tree, so the
# test extracts the remove_stale_cs8409 function from each script and runs it
# against a fixture directory standing in for .../updates/codecs/cirrus.
#
# Exit codes: 0 pass, 1 fail, 77 skip.

set -u

. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODULE=snd-hda-codec-cs8409

# run_removal <installer> <fixture-dir> -- load the function and run it.
run_removal() {
  (
    eval "$(sed -n '/^remove_stale_cs8409() {/,/^}/p' "$REPO_ROOT/$1")"
    remove_stale_cs8409 "$2"
  )
}

check_installer() {
  local script=$1 dir
  dir=$(make_tmpdir)
  touch "$dir/$MODULE.ko" "$dir/$MODULE.ko.zst" "$dir/$MODULE.ko.xz" \
        "$dir/$MODULE.ko.gz" "$dir/other.ko.zst" "$dir/$MODULE-extra.ko.zst"

  assert_contains "$(sed -n '/^remove_stale_cs8409() {/p' "$REPO_ROOT/$script")" \
    "remove_stale_cs8409" "$script defines remove_stale_cs8409"
  local out
  out=$(run_removal "$script" "$dir")

  assert_eq 1 "$([ ! -e "$dir/$MODULE.ko" ] && echo 1 || echo 0)" "$script removes .ko"
  assert_eq 1 "$([ ! -e "$dir/$MODULE.ko.zst" ] && echo 1 || echo 0)" "$script removes .ko.zst"
  assert_eq 1 "$([ ! -e "$dir/$MODULE.ko.xz" ] && echo 1 || echo 0)" "$script removes .ko.xz"
  assert_eq 1 "$([ ! -e "$dir/$MODULE.ko.gz" ] && echo 1 || echo 0)" "$script removes .ko.gz"
  assert_eq 1 "$([ -e "$dir/other.ko.zst" ] && echo 1 || echo 0)" "$script keeps unrelated other.ko.zst"
  assert_eq 1 "$([ -e "$dir/$MODULE-extra.ko.zst" ] && echo 1 || echo 0)" "$script keeps similarly named module"
  assert_contains "$out" "removed $dir/$MODULE.ko.zst" "$script reports the .zst removal"

  # negative: an empty/missing directory is not an error
  run_removal "$script" "$dir/absent" > /dev/null
  assert_eq 0 $? "$script tolerates a missing directory"
}

check_installer install.cirrus.driver.sh
check_installer install.cirrus.driver.pre617.sh

finish
