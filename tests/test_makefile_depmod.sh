#!/usr/bin/env bash
#
# tests/test_makefile_depmod.sh -- `make install` must run depmod against the
# kernel the driver was actually built for.
#
# The install target used to run a bare `depmod -a`, which generates module
# dependency metadata for the *running* kernel.  Build the driver for another
# kernel (KERNELRELEASE=..., or a KERNELDIR=... override) and that metadata
# lands in the wrong /lib/modules/<release> directory, so the freshly installed
# module is not found until the next boot.
#
# Everything is graded through the public interface only:
#   * `make -n install ...`  -- the depmod command make plans to run (dry run,
#     nothing is executed, so no kernel headers are needed)
#   * `make install ...` with a PATH-shimmed depmod -- the argv depmod really
#     receives when the recipe runs for real
#
# Not testable here: a *real* (non-dry) run with nothing overridden would need a
# writable /lib/modules/$(uname -r)/build, so the plain "current kernel" case
# is graded by dry run only.
#
# Requirements covered, one assertion each:
#   1. KERNELRELEASE=9.9.9-test          -> depmod -a 9.9.9-test
#   2. nothing set                       -> depmod -a, byte for byte: no stray
#                                          empty argument, no trailing space
#   3. KERNELRELEASE= (empty, boundary)  -> depmod -a, old behaviour kept
#   4. KERNELDIR=/lib/modules/1.2.3 and no KERNELRELEASE
#                                        -> depmod -a 1.2.3 (release derived
#                                          from the overridden KERNELDIR)
#   5. both given                        -> KERNELRELEASE wins
#   6. the modules_install step of the install target is still planned
#   7. the chosen rule is documented in a Makefile comment (structural: the
#      comment must mention KERNELRELEASE; its wording is free)
#   8. README documents KERNELDIR / KERNELRELEASE (structural, wording free)
#   9. real run: the shimmed depmod is invoked with the release as its argument

set -u

. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAKEFILE="$REPO_ROOT/Makefile"
README="$REPO_ROOT/README.md"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# dry_plan [make args...] -- the full recipe `make -n install` plans to run.
dry_plan() {
  make -C "$REPO_ROOT" -n install "$@" 2>&1
}

# depmod_line <plan> -- the depmod command inside a dry-run plan.
depmod_line() {
  printf '%s\n' "$1" | grep 'depmod' | tail -n 1
}

# setup_depmod_shim -- create a depmod shim that records its argv, one
# argument per line, into $DEPMOD_LOG.  It is put first on PATH by real_install.
setup_depmod_shim() {
  SHIM_ROOT=$(make_tmpdir)
  DEPMOD_LOG="$SHIM_ROOT/depmod.argv"
  mkdir -p "$SHIM_ROOT/bin"
  cat > "$SHIM_ROOT/bin/depmod" <<SHIM
#!/bin/sh
printf '%s\n' "\$@" > "$DEPMOD_LOG"
exit 0
SHIM
  chmod +x "$SHIM_ROOT/bin/depmod"
}

# stub_kernel <dir> -- make <dir> stand in for /lib/modules/<release>: it gets
# a build/Makefile with a no-op modules_install target so the first recipe
# line of `make install` succeeds and the recipe reaches depmod, without
# needing real kernel headers or a real /lib/modules tree.
stub_kernel() {
  mkdir -p "$1/build"
  printf 'modules_install:\n\t:\n' > "$1/build/Makefile"
}

# real_install <kernel-dir> [make args...] -- run `make install` for real with
# the depmod shim first on PATH.  Leaves the recorded argv in $DEPMOD_LOG and
# the make output in $SHIM_ROOT/make.out.
real_install() {
  _kdir=$1
  shift
  rm -f "$DEPMOD_LOG"
  stub_kernel "$_kdir"
  PATH="$SHIM_ROOT/bin:$PATH" \
    make -C "$REPO_ROOT" install KERNELDIR="$_kdir" "$@" \
    > "$SHIM_ROOT/make.out" 2>&1
  if [ ! -f "$DEPMOD_LOG" ]; then
    printf 'make install never reached depmod; its output was:\n' >&2
    sed -n '1,20p' "$SHIM_ROOT/make.out" >&2
  fi
}

# recorded_argv -- what the shimmed depmod was called with, one arg per line.
recorded_argv() {
  cat "$DEPMOD_LOG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. KERNELRELEASE selects the release depmod runs for
# ---------------------------------------------------------------------------

plan=$(dry_plan KERNELRELEASE=9.9.9-test)
assert_eq "depmod -a 9.9.9-test" "$(depmod_line "$plan")" \
  "make -n install KERNELRELEASE=9.9.9-test plans 'depmod -a 9.9.9-test'"

# 6. ... and only the depmod line changed: the modules are still installed.
assert_contains "$plan" "modules_install" \
  "the install target still plans modules_install"

# ---------------------------------------------------------------------------
# 2. negative: nothing set -- the old "current kernel" behaviour, byte for
#    byte.  An accidental `depmod -a $(empty)` shows up here as a trailing
#    space or an empty argument.
# ---------------------------------------------------------------------------

assert_eq "depmod -a" "$(depmod_line "$(dry_plan)")" \
  "with nothing set the planned command is exactly 'depmod -a'"

# ---------------------------------------------------------------------------
# 3. boundary: KERNELRELEASE given but empty keeps the old behaviour too
# ---------------------------------------------------------------------------

assert_eq "depmod -a" "$(depmod_line "$(dry_plan KERNELRELEASE=)")" \
  "an empty KERNELRELEASE keeps the current-kernel behaviour"

# ---------------------------------------------------------------------------
# 4. derivation rule: no KERNELRELEASE, KERNELDIR overridden -- the release
#    comes from the overridden KERNELDIR
# ---------------------------------------------------------------------------

assert_eq "depmod -a 1.2.3" "$(depmod_line "$(dry_plan KERNELDIR=/lib/modules/1.2.3)")" \
  "KERNELDIR=/lib/modules/1.2.3 with no KERNELRELEASE plans 'depmod -a 1.2.3'"

# ---------------------------------------------------------------------------
# 5. precedence: KERNELRELEASE wins over an overridden KERNELDIR
# ---------------------------------------------------------------------------

assert_eq "depmod -a 9.9.9-test" \
  "$(depmod_line "$(dry_plan KERNELDIR=/lib/modules/1.2.3 KERNELRELEASE=9.9.9-test)")" \
  "KERNELRELEASE wins over an overridden KERNELDIR"

# ---------------------------------------------------------------------------
# 9. non-dry run: depmod really is invoked with the release as its argument
# ---------------------------------------------------------------------------

setup_depmod_shim

# 9a. explicit KERNELRELEASE: argv is exactly (-a, 9.9.9-test) -- no stray
#     empty argument, nothing quoted away.
real_install "$SHIM_ROOT/lib/modules/5.5.5-stub" KERNELRELEASE=9.9.9-test
assert_file_exists "$DEPMOD_LOG" \
  "make install (real run) reached the depmod shim"
assert_eq "$(printf '%s\n' -a 9.9.9-test)" "$(recorded_argv)" \
  "the real install invokes depmod with exactly -a and the release"

# 9b. derivation, real run: the release comes from the overridden KERNELDIR.
#     (Contains rather than equals: only the basename, not the path shape, is
#     specified by the story.)
real_install "$SHIM_ROOT/lib/modules/8.8.8-stub"
assert_file_exists "$DEPMOD_LOG" \
  "make install (real run, derived release) reached the depmod shim"
assert_contains "$(recorded_argv)" "8.8.8-stub" \
  "the real install passes the release derived from KERNELDIR to depmod"

# ---------------------------------------------------------------------------
# 7. the chosen rule is documented in a Makefile comment that explains WHY.
#    Structural only: some comment line must mention KERNELRELEASE.  The
#    wording itself is the implementer's and is deliberately not pinned.
# ---------------------------------------------------------------------------

_rule_documented=0
while IFS= read -r _line || [ -n "$_line" ]; do
  _line=${_line#"${_line%%[![:space:]]*}"}
  case "$_line" in
    '#'*KERNELRELEASE*) _rule_documented=1 ;;
  esac
done < "$MAKEFILE"
assert_eq 1 "$_rule_documented" \
  "the Makefile documents the rule in a comment mentioning KERNELRELEASE"

# ---------------------------------------------------------------------------
# 8. README documents the KERNELDIR / KERNELRELEASE usage (structural only)
# ---------------------------------------------------------------------------

assert_contains "$(cat "$README" 2>/dev/null)" "KERNELRELEASE" \
  "README documents KERNELRELEASE"
assert_contains "$(cat "$README" 2>/dev/null)" "KERNELDIR" \
  "README documents KERNELDIR"

finish