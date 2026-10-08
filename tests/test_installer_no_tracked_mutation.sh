#!/usr/bin/env bash
#
# tests/test_installer_no_tracked_mutation.sh -- the installers must leave the
# checkout byte-identical (HDA-13, S10).
#
# install.cirrus.driver.pre617.sh rewrote the tracked dkms.conf in place with
# `sed -i` (and, on the first run, `sed -i.orig`, which additionally left an
# untracked dkms.conf.orig behind).  Nothing required that: dkms.sh runs
# `dkms install -c dkms.conf` from its own directory and symlinks that
# directory into /usr/src, so dkms reads dkms.conf in place.  The installer now
# stages a copy of the tree in a temp dir, writes the edited dkms.conf there
# and points dkms at the copy; the temp dir is removed on exit.
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
exit 0
FAKE
chmod +x "$HDA_SHIMS/dkms" || exit 1

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
assert_clean() {
  _label=$1
  _dirty=$(cd "$sandbox" && git status --porcelain)
  assert_eq "" "$_dirty" "$_label: installer must leave the checkout byte-identical"
  assert_eq "$tracked_before" "$(cat "$sandbox/dkms.conf")" \
    "$_label: tracked dkms.conf must be byte-identical after the run"
}

# ---------------------------------------------------------------------------
# case 1: pre-6.17 installer, 5.19 -- module name snd-hda-codec-cs8409
# ---------------------------------------------------------------------------

hda_installer_run install.cirrus.driver.pre617.sh -i -d -k "$OLD_UNAME"

assert_eq 0 "$HDA_INSTALLER_RC" \
  "pre617 installer must exit 0 with all shims succeeding (output: $(hda_installer_output_oneline))"
assert_clean "pre617 5.19"

# A second run in the same checkout must behave identically: the old
# `sed -i.orig` left dkms.conf.orig behind, which flipped the script onto its
# other sed branch on the next run.
hda_installer_run install.cirrus.driver.pre617.sh -i -d -k "$OLD_UNAME"

assert_eq 0 "$HDA_INSTALLER_RC" \
  "pre617 installer must exit 0 on a repeat run (output: $(hda_installer_output_oneline))"
assert_clean "pre617 5.19 (repeat)"

assert_file_exists "$HDA_DKMS_CONF_CAPTURE" "dkms must have been pointed at a dkms.conf"
staged=$(cat "$HDA_DKMS_CONF_CAPTURE" 2>/dev/null || true)
assert_contains "$staged" 'BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"' \
  "staged dkms.conf must carry the 5.19 module name"
assert_contains "$staged" 'BUILT_MODULE_LOCATION[0]="build/hda"' \
  "staged dkms.conf must carry the pre-6.17 module location"
assert_contains "$staged" 'PRE_BUILD="install.cirrus.driver.pre617.sh -k $kernelver --dkms"' \
  "staged dkms.conf must carry the pre-6.17 PRE_BUILD"

staged_path=$(cat "$HDA_DKMS_CONF_PATH" 2>/dev/null || true)
assert_not_contains "$staged_path" "$sandbox" \
  "dkms must be pointed at a staged copy, not the checkout"

# ---------------------------------------------------------------------------
# case 2: pre-6.17 installer, 5.12 -- module name snd-hda-codec-cirrus
# ---------------------------------------------------------------------------

reset_sandbox
: > "$HDA_DKMS_CONF_CAPTURE"
: > "$HDA_DKMS_CONF_PATH"

hda_installer_run install.cirrus.driver.pre617.sh -i -d -k "$ANCIENT_UNAME"

assert_eq 0 "$HDA_INSTALLER_RC" \
  "pre617 installer must exit 0 for 5.12 (output: $(hda_installer_output_oneline))"
assert_clean "pre617 5.12"

staged=$(cat "$HDA_DKMS_CONF_CAPTURE" 2>/dev/null || true)
assert_contains "$staged" 'BUILT_MODULE_NAME[0]="snd-hda-codec-cirrus"' \
  "staged dkms.conf must carry the 5.12 module name"

# ---------------------------------------------------------------------------
# case 3: >= 6.17 installer -- edits nothing, so dkms sees the tracked config
# ---------------------------------------------------------------------------

reset_sandbox
: > "$HDA_DKMS_CONF_CAPTURE"
: > "$HDA_DKMS_CONF_PATH"

hda_installer_run install.cirrus.driver.sh -i -d -k "$NEW_UNAME"

assert_eq 0 "$HDA_INSTALLER_RC" \
  "6.17 installer must exit 0 with all shims succeeding (output: $(hda_installer_output_oneline))"
assert_clean "6.17"

assert_eq "$tracked_before" "$(cat "$HDA_DKMS_CONF_CAPTURE" 2>/dev/null || true)" \
  "6.17 installer must hand dkms the tracked dkms.conf unedited"

# The staging directory must not survive the run (trap ... EXIT).
stale=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'snd-hda-dkms.*' 2>/dev/null | head -1)
assert_eq "" "$stale" "installer must remove its staging directory on exit"

finish
