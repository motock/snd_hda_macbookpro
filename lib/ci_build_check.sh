#!/usr/bin/env bash
#
# lib/ci_build_check.sh -- patch a pinned kernel and compile cs8409.o.
#
#     lib/ci_build_check.sh <new|7x|path/to/tarball>
#
# Stages sound/hda from the kernel tarball the way install.cirrus.driver.sh
# does (repo Makefiles + patch_cirrus headers, then patch -b -p1 with
# patch_cs8409.c.diff and patch_cs8409.h.diff), enables the Cirrus codec
# options, and builds the module out of tree with the Makefile's
# KBUILD_EXTRA_CFLAGS, so CI compiles what users build.
#
# Pins (tests/kernel-pins.conf, fetched and SHA-256 verified through
# tests/lib/kernel_cache.sh, cache root HDA_TEST_CACHE):
#   new   PIN_NEW_*  6.17.x
#   7x    PIN_7X_*   7.x (HDA_KERNEL_MIRROR defaults to the v7.x directory)
# A tarball path is accepted only when its file name is a pinned tarball, and
# is then checked against that pin's SHA-256.
#
# Exit status:
#   0  cs8409.o compiled with no "error:" compiler line and the warning
#      counts equal tests/ci/build-warning-baseline.<pin>.txt
#   1  patch failure, .rej file, compiler error, missing cs8409.o,
#      checksum mismatch, download failure, missing build tool or a warning
#      ratchet failure (lib/ci_build_warnings.sh: more, new or fewer
#      warnings than the baseline; CI_BUILD_WARNINGS_UPDATE=1 rewrites it)
#   2  bad invocation: no argument, unknown pin, missing tarball (usage shown)
#
# Without a full Module.symvers the final modpost step reports the module's
# external symbols as undefined.  That is expected and is the only thing
# tolerated: ci_build_verdict ignores exactly those modpost messages and
# never filters compiler diagnostics.
#
# CONFIG_WERROR is switched off in the scratch .config, as distro kernels do
# (Ubuntu 7.0.0-38 builds this driver with -Werror off and a full warning
# list), and the build log is the complete, uncapped make output: nothing in
# this script or the Makefile limits diagnostics (no -fmax-errors, head or
# tail on the build output).  Set CI_BUILD_LOG_DIR=<dir> to also keep that
# log as <dir>/build-linux-<version>.log for upload as a CI artifact.
#
# Manual check that a compiler error fails the build (about as slow as a real
# run):
#     CI_BUILD_CHECK_INJECT_ERROR=1 lib/ci_build_check.sh new; echo $?
# appends a syntax error to cs8409.c in the scratch copy only; expect exit 1.
#
# The kernel tarball is untrusted: it is unpacked into a scratch directory
# outside the repository, removed on exit, and nothing in it is run except by
# kbuild itself.
#
# Needs: bash, tar, xz, GNU patch, make, gcc, flex, bison, bc, libelf, libssl
# headers (Ubuntu: build-essential flex bison bc libelf-dev libssl-dev).
# Compatible with bash 3.2: no associative arrays, no mapfile.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/ci_build_warnings.sh"

# --- verdict ---------------------------------------------------------------

# Expected modpost output when Module.symvers is absent.
_CBC_MODPOST_OK='^(ERROR|WARNING): modpost: ("[^"]*" \[[^]]*\] undefined!|Symbol info of vmlinux is missing)'

# ci_build_verdict <logfile> <make_rc> <cs8409.o path> -- print the
# diagnostic counts and decide.  Returns 0 only when cs8409.o is non-empty,
# the compiler log has no "error:" line, and a non-zero make
# status is explained by the expected modpost messages alone.
ci_build_verdict() {
  local log=$1 rc=$2 obj=$3 errs warns modpost_ok other verdict=0
  errs=$(grep -c 'error:' "$log")
  warns=$(grep -c 'warning:' "$log")
  modpost_ok=$(grep -Ec "$_CBC_MODPOST_OK" "$log")
  other=$(grep -E '^(ERROR|WARNING): ' "$log" | grep -Evc "$_CBC_MODPOST_OK")
  printf 'errors=%s warnings=%s make_exit=%s expected_modpost_lines=%s\n' \
    "$errs" "$warns" "$rc" "$modpost_ok"
  if [ ! -s "$obj" ]; then
    echo "FAIL: cs8409.o was not produced" >&2
    verdict=1
  fi
  if [ "$errs" -ne 0 ]; then
    echo "FAIL: compiler reported $errs error(s)" >&2
    verdict=1
  fi
  if [ "$other" -ne 0 ]; then
    echo "FAIL: $other unexpected ERROR/WARNING line(s) in the build output" >&2
    verdict=1
  fi
  if [ "$rc" -ne 0 ] && [ "$modpost_ok" -eq 0 ]; then
    echo "FAIL: make exited $rc without the expected modpost messages" >&2
    verdict=1
  fi
  return "$verdict"
}

# --- helpers ---------------------------------------------------------------

cbc_usage() {
  echo "usage: $0 <new|7x|path/to/tarball>" >&2
  echo "  new    build against the pinned 6.17.x kernel (tests/kernel-pins.conf)" >&2
  echo "  7x     build against the pinned 7.x kernel" >&2
  echo "  path   a pinned kernel tarball; its SHA-256 is verified against the pin" >&2
  echo "  -h     show this help (exit 0)" >&2
  echo "env: HDA_TEST_CACHE, HDA_KERNEL_MIRROR, CI_BUILD_LOG_DIR, CI_BUILD_CHECK_INJECT_ERROR=1" >&2
}

cbc_die() {
  printf 'ci_build_check: %s\n' "$*" >&2
  exit 1
}

# cbc_find_patch -- print a GNU patch (patch or gpatch).
cbc_find_patch() {
  local cand
  for cand in patch gpatch; do
    if command -v "$cand" >/dev/null 2>&1 &&
       "$cand" --version 2>/dev/null | head -1 | grep -q 'GNU patch'; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# cbc_load_pin new|7x -- set _KC_VERSION, _KC_TARBALL, _KC_SHA256.
cbc_load_pin() {
  case "$1" in
    new) _kc_load_pins new ;;
    7x)
      local pins
      pins=$(_kc_pins_file)
      [ -f "$pins" ] || { _kc_die "pins file not found: $pins"; return 1; }
      # shellcheck disable=SC1090
      . "$pins" || return 1
      _KC_VERSION=${PIN_7X_VERSION-}
      _KC_TARBALL=${PIN_7X_TARBALL-}
      _KC_SHA256=${PIN_7X_SHA256-}
      if [ -z "$_KC_VERSION" ] || [ -z "$_KC_TARBALL" ] ||
         ! printf '%s' "$_KC_SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
        _kc_die "pins file $pins has no valid 7x pin"
        return 1
      fi
      HDA_KERNEL_MIRROR=${HDA_KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v7.x}
      export HDA_KERNEL_MIRROR
      ;;
  esac
}

# cbc_resolve_tarball <arg> -- set TARBALL (verified) and KVER, or exit.
cbc_resolve_tarball() {
  local arg=$1 base which actual rc
  case "$arg" in
    new|7x)
      cbc_load_pin "$arg" || exit 1
      _kc_ensure_tarball
      rc=$?
      [ "$rc" -eq 0 ] || exit 1
      TARBALL="$(_kc_cache_root)/tarballs/$_KC_TARBALL"
      KVER=$_KC_VERSION
      PIN=$arg
      return 0
      ;;
  esac
  if [ ! -f "$arg" ]; then
    echo "ci_build_check: unknown pin or no such tarball: $arg" >&2
    cbc_usage
    exit 2
  fi
  base=$(basename "$arg")
  for which in new 7x; do
    cbc_load_pin "$which" >/dev/null 2>&1 || continue
    if [ "$base" = "$_KC_TARBALL" ]; then
      actual=$(_kc_sha256 "$arg") || cbc_die "no sha256 tool available"
      [ "$actual" = "$_KC_SHA256" ] ||
        cbc_die "checksum mismatch for $arg: expected $_KC_SHA256, actual $actual"
      TARBALL=$arg
      KVER=$_KC_VERSION
      PIN=$which
      return 0
    fi
  done
  echo "ci_build_check: $base is not a pinned tarball, cannot verify it" >&2
  cbc_usage
  exit 2
}

# cbc_extra_cflags -- the Makefile's KBUILD_EXTRA_CFLAGS, quotes removed.
cbc_extra_cflags() {
  sed -n 's/^KBUILD_EXTRA_CFLAGS *= *"\(.*\)"[[:space:]]*$/\1/p' "$REPO_ROOT/Makefile" | head -n 1
}

cbc_cleanup() {
  [ -n "${SCRATCH:-}" ] && rm -rf -- "$SCRATCH"
}

# cbc_step <name> <logfile> <command...> -- run quietly, dump the log on failure.
cbc_step() {
  local name=$1 log=$2 rc=0
  shift 2
  echo "== $name"
  "$@" >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    tail -n 40 "$log" >&2
    cbc_die "$name failed (exit $rc)"
  fi
}

cbc_main() {
  local arg=${1-} patch_cmd cflags jobs ksrc stage hda start rc=0 cfg o
  case "$arg" in
    -h|--help) cbc_usage; exit 0 ;;
    '') echo "ci_build_check: missing argument" >&2; cbc_usage; exit 2 ;;
  esac
  [ $# -eq 1 ] || { cbc_usage; exit 2; }

  . "$REPO_ROOT/tests/lib/kernel_cache.sh"
  cbc_resolve_tarball "$arg"

  patch_cmd=$(cbc_find_patch) || cbc_die "GNU patch is required"
  cflags=$(cbc_extra_cflags)
  [ -n "$cflags" ] || cbc_die "cannot read KBUILD_EXTRA_CFLAGS from the Makefile"
  jobs=$( (nproc || sysctl -n hw.ncpu) 2>/dev/null | head -n 1)
  jobs=${jobs:-2}

  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/ci-build-check.XXXXXX") || cbc_die "cannot create a scratch dir"
  trap cbc_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ksrc=$SCRATCH/linux
  stage=$SCRATCH/stage
  hda=$stage/hda
  mkdir -p "$ksrc" "$stage" || cbc_die "cannot create scratch subdirectories"
  start=$(date +%s)

  cbc_step "extract linux-$KVER" "$SCRATCH/extract.log" \
    tar -xf "$TARBALL" -C "$ksrc" --strip-components=1 --no-same-owner
  [ -d "$ksrc/sound/hda/codecs/cirrus" ] || cbc_die "linux-$KVER has no sound/hda/codecs/cirrus"

  # stage sound/hda like install.cirrus.driver.sh
  cp -R "$ksrc/sound/hda" "$hda" || cbc_die "cannot stage sound/hda"
  cp "$REPO_ROOT/makefiles/Makefile" "$hda/Makefile" &&
    cp "$REPO_ROOT/makefiles/Makefile_common" "$hda/common/Makefile" &&
    cp "$REPO_ROOT/makefiles/Makefile_codecs" "$hda/codecs/Makefile" &&
    cp "$REPO_ROOT/makefiles/Makefile_cirrus" "$hda/codecs/cirrus/Makefile" ||
    cbc_die "cannot install the repo makefiles"
  for h in cirrus_apple.h patch_cirrus_boot84.h patch_cirrus_new84.h \
           patch_cirrus_real84.h patch_cirrus_hda_generic_copy.h \
           patch_cirrus_real84_i2c.h; do
    cp "$REPO_ROOT/patch_cirrus/$h" "$hda/codecs/cirrus" || cbc_die "cannot copy $h"
  done

  echo "== patch"
  for d in patch_cs8409.c.diff patch_cs8409.h.diff; do
    ( cd "$hda" && "$patch_cmd" --batch -b -p1 <"$REPO_ROOT/$d" ) >"$SCRATCH/patch.log" 2>&1 || {
      cat "$SCRATCH/patch.log" >&2
      cbc_die "$d did not apply to linux-$KVER"
    }
    cat "$SCRATCH/patch.log"
  done
  if [ -n "$(find "$stage" -name '*.rej')" ]; then
    cbc_die "patching left .rej files"
  fi
  if [ "${CI_BUILD_CHECK_INJECT_ERROR:-}" = 1 ]; then
    echo "== injecting a deliberate syntax error into the scratch cs8409.c"
    echo 'int ci_build_check_injected_error = ;' >>"$hda/codecs/cirrus/cs8409.c"
  fi

  cbc_step "defconfig" "$SCRATCH/defconfig.log" make -C "$ksrc" defconfig
  # HDA_INTEL pulls in SND_HDA, which has no prompt of its own
  cfg=$ksrc/.config
  cat >>"$cfg" <<'EOF'
CONFIG_SOUND=y
CONFIG_SND=m
CONFIG_SND_PCI=y
CONFIG_SND_HDA_INTEL=m
CONFIG_SND_HDA_CODEC_CIRRUS=m
CONFIG_SND_HDA_CODEC_CS8409=m
EOF
  # Distro kernels build without -Werror, so warnings never stop their build;
  # mirror that so the full warning list is reported instead of the first
  # fatal one (Ubuntu 7.0.0-38 evidence).
  "$ksrc/scripts/config" --file "$cfg" --disable WERROR ||
    cbc_die "cannot disable CONFIG_WERROR"
  cbc_step "olddefconfig" "$SCRATCH/olddefconfig.log" make -C "$ksrc" olddefconfig
  for o in CONFIG_SND_HDA_CODEC_CIRRUS=m CONFIG_SND_HDA_CODEC_CS8409=m; do
    grep -qx "$o" "$cfg" || cbc_die "$o did not survive olddefconfig"
  done
  ! grep -q '^CONFIG_WERROR=y' "$cfg" || cbc_die "CONFIG_WERROR is still enabled after olddefconfig"
  grep -Eq '^CONFIG_SND_HDA=[my]$' "$cfg" || cbc_die "CONFIG_SND_HDA is not enabled after olddefconfig"
  cbc_step "modules_prepare" "$SCRATCH/prepare.log" make -C "$ksrc" -j"$jobs" modules_prepare

  echo "== build modules (CFLAGS_MODULE=$cflags)"
  make -C "$ksrc" -j"$jobs" "CFLAGS_MODULE=$cflags" "M=$hda" modules >"$SCRATCH/build.log" 2>&1 || rc=$?
  cat "$SCRATCH/build.log"
  if [ -n "${CI_BUILD_LOG_DIR:-}" ]; then
    mkdir -p "$CI_BUILD_LOG_DIR" &&
      cp "$SCRATCH/build.log" "$CI_BUILD_LOG_DIR/build-linux-$KVER.log" ||
      cbc_die "cannot write the build log to $CI_BUILD_LOG_DIR"
  fi

  echo "== verdict (linux-$KVER)"
  o=$hda/codecs/cirrus/cs8409.o
  rc_verdict=0
  ci_build_verdict "$SCRATCH/build.log" "$rc" "$o" || rc_verdict=1
  cbw_check "$SCRATCH/build.log" "$REPO_ROOT/tests/ci/build-warning-baseline.$PIN.txt" || rc_verdict=1
  if [ -s "$o" ]; then
    echo "cs8409.o size: $(wc -c <"$o" | tr -d ' ') bytes"
  fi
  echo "wall-clock: $(( $(date +%s) - start ))s"
  exit "$rc_verdict"
}

# run only when executed, so tests can source this file for ci_build_verdict
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
  cbc_main "$@"
fi
