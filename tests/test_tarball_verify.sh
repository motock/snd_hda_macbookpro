#!/usr/bin/env bash
#
# tests/test_tarball_verify.sh -- lib/verify_kernel_tarball.sh and its use by
# the installers (HDA-11, B2).
#
# The kernel tarball must be checked against kernel.org's sha256sums.asc
# before it is extracted, and any problem must fail closed: non-zero status
# and an error on stderr.  Only a hash mismatch deletes the tarball, so that
# `wget -c` cannot resume a poisoned file; every other failure (missing,
# ambiguous or unreachable checksum, no hashing tool, ...) leaves the
# possibly-good tarball in place.
#
# `wget` is replaced by a fake that serves a local fixture sums file for
# `-O <file> <url>` and writes a fixture tarball for `-P <dir> <url>`; `tar`
# is the generic logging shim from tests/lib/shims.sh.  Nothing touches the
# network.
#
# Case 6 drives the real installers.  The kernel-headers probe is a bash
# builtin on an absolute path (see hda_non_dkms_blocker in shims.sh), so the
# sandbox *copy* of each installer has those four probe paths redirected into
# the sandbox; the code under test (download -> verify -> extract) is untouched.

set -u

. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/shims.sh"

REPO=$(cd "$(dirname "$0")/.." && pwd)
VERSION=6.17.1

hda_shims_setup > /dev/null || { echo "cannot build the shim directory" >&2; exit 1; }
FAKE_BIN=$(make_tmpdir)

# fake wget: HDA_FIXTURE_SUMS is served for -O, HDA_FIXTURE_TARBALL for -P.
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

sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi
}

# new_fixture -- fresh work dir with a good tarball; sets WORK, TARBALL, GOOD_SHA.
new_fixture() {
  WORK=$(make_tmpdir)
  mkdir -p "$WORK/build"
  TARBALL="$WORK/build/linux-$VERSION.tar.xz"
  printf 'pretend kernel source\n' > "$TARBALL"
  GOOD_SHA=$(sha_of "$TARBALL")
  HDA_FIXTURE_SUMS="$WORK/sha256sums.asc"
  HDA_FIXTURE_TARBALL="$WORK/pristine.tar.xz"
  HDA_FIXTURE_VERSION=$VERSION
  cp "$TARBALL" "$HDA_FIXTURE_TARBALL"
  export HDA_FIXTURE_SUMS HDA_FIXTURE_TARBALL HDA_FIXTURE_VERSION
  hda_shim_clear
}

# write_sums <line>... -- sums file in clearsigned style, one line per argument.
write_sums() {
  { echo '-----BEGIN PGP SIGNED MESSAGE-----'; echo 'Hash: SHA256'; echo; printf '%s\n' "$@"; echo '-----BEGIN PGP SIGNATURE-----'; } > "$HDA_FIXTURE_SUMS"
}

# run_verify <tarball> <version> -- sets VERIFY_RC and VERIFY_ERR.
run_verify() {
  VERIFY_ERR=$( PATH="$FAKE_BIN:$PATH" bash -c '. "$1/lib/verify_kernel_tarball.sh"; verify_kernel_tarball "$2" "$3"' _ "$REPO" "$1" "$2" 2>&1 >/dev/null )
  VERIFY_RC=$?
}

test_correct_hash_passes() {
  new_fixture
  write_sums "$GOOD_SHA  linux-$VERSION.tar.xz"
  run_verify "$TARBALL" "$VERSION"
  assert_eq 0 "$VERIFY_RC" "a matching hash verifies"
  assert_file_exists "$TARBALL" "a verified tarball is kept"
}

test_flipped_byte_fails_and_deletes_tarball() {
  new_fixture
  write_sums "$GOOD_SHA  linux-$VERSION.tar.xz"
  printf 'pretend kernel sourcf\n' > "$TARBALL"
  run_verify "$TARBALL" "$VERSION"
  assert_eq 1 "$VERIFY_RC" "a corrupted tarball is rejected"
  assert_contains "$VERIFY_ERR" "mismatch" "the error says why"
  assert_contains "$VERIFY_ERR" "${GOOD_SHA:0:12}" "the error shows the first 12 hex chars"
  assert_not_contains "$VERIFY_ERR" "${GOOD_SHA:0:13}" "the error shows no more than 12"
  [ ! -e "$TARBALL" ] && assert_eq 1 1 "the bad tarball was deleted" || assert_eq deleted present "the bad tarball was deleted"
}

test_missing_line_fails() {
  new_fixture
  write_sums "$GOOD_SHA  linux-6.16.9.tar.xz"
  run_verify "$TARBALL" "$VERSION"
  assert_eq 1 "$VERIFY_RC" "no matching line is rejected"
  assert_contains "$VERIFY_ERR" "no checksum" "the error says why"
  assert_file_exists "$TARBALL" "an unverified tarball is not deleted"
}

test_duplicate_line_fails() {
  new_fixture
  write_sums "$GOOD_SHA  linux-$VERSION.tar.xz" "$GOOD_SHA  linux-$VERSION.tar.xz"
  run_verify "$TARBALL" "$VERSION"
  assert_eq 1 "$VERIFY_RC" "two matching lines are rejected"
  assert_contains "$VERIFY_ERR" "expected exactly one" "the error says why"
  assert_file_exists "$TARBALL" "an unverified tarball is not deleted"
}

test_substring_match_fails() {
  new_fixture
  # we ask for linux-6.17.tar.xz; the sums file only lists linux-6.17.1.tar.xz
  mv "$TARBALL" "$WORK/build/linux-6.17.tar.xz"
  write_sums "$GOOD_SHA  linux-6.17.1.tar.xz" "$GOOD_SHA  linux-6.17.tar.xz.sign"
  run_verify "$WORK/build/linux-6.17.tar.xz" 6.17
  assert_eq 1 "$VERIFY_RC" "a substring-only match is rejected"
  assert_file_exists "$WORK/build/linux-6.17.tar.xz" "an unverified tarball is not deleted"
}

test_missing_sums_file_fails() {
  new_fixture
  rm -f "$HDA_FIXTURE_SUMS"
  run_verify "$TARBALL" "$VERSION"
  assert_eq 1 "$VERIFY_RC" "an unreachable sums file is rejected"
  assert_file_exists "$TARBALL" "an unverified tarball is not deleted"
}

# ---- case 6: the installers ------------------------------------------------

# prepare_installer <script> -- sandbox copy with the headers probe redirected.
prepare_installer() {
  hda_sandbox_setup > /dev/null || return 1
  mkdir -p "$HDA_SANDBOX/fake/linux-headers" || return 1
  sed -i.bak "s#/usr/src/linux-headers-\${UNAME}#$HDA_SANDBOX/fake/linux-headers#" "$HDA_SANDBOX/$1" || return 1
  rm -f "$HDA_SANDBOX/$1.bak"
  grep -q "$HDA_SANDBOX/fake/linux-headers" "$HDA_SANDBOX/$1" || { echo "headers probe not redirected in $1" >&2; return 1; }
}

installer_rejects_bad_tarball() {
  _script=$1 _uname=$2
  VERSION=$_uname
  new_fixture
  # the downloaded tarball hashes to something other than the published sum
  write_sums "$(printf '0%.0s' $(seq 64))  linux-$VERSION.tar.xz"
  prepare_installer "$_script" || { assert_eq prepared failed "$_script sandbox"; return; }
  # fake wget ahead of the logging shims; real tar is never reached
  HDA_SHIMS_SAVED=$HDA_SHIMS
  HDA_SHIMS="$FAKE_BIN:$HDA_SHIMS"
  hda_installer_run "$_script" -k "$_uname"
  HDA_SHIMS=$HDA_SHIMS_SAVED
  assert_ne 0 "$HDA_INSTALLER_RC" "$_script exits non-zero when verification fails"
  assert_contains "$HDA_INSTALLER_OUTPUT" "mismatch" "$_script reports the mismatch"
  hda_assert_shim_called wget "-P build" "$_script must actually reach the download"
  assert_eq "" "$(hda_shim_calls tar)" "$_script must not call tar after a failed verification"
  [ ! -e "$HDA_SANDBOX/build/linux-$VERSION.tar.xz" ] && assert_eq 1 1 "tarball deleted" || assert_eq deleted present "$_script tarball deleted"
}

test_new_installer_does_not_extract_unverified_tarball() {
  installer_rejects_bad_tarball install.cirrus.driver.sh 6.17.1
}

test_pre617_installer_does_not_extract_unverified_tarball() {
  installer_rejects_bad_tarball install.cirrus.driver.pre617.sh 5.19.1
}

test_correct_hash_passes
test_flipped_byte_fails_and_deletes_tarball
test_missing_line_fails
test_duplicate_line_fails
test_substring_match_fails
test_missing_sums_file_fails
test_new_installer_does_not_extract_unverified_tarball
test_pre617_installer_does_not_extract_unverified_tarball

finish
