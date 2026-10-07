#!/usr/bin/env bash
#
# tests/test_makefile_depmod.sh -- `make install` must run depmod against the
# kernel the driver was actually built for.  A bare `depmod -a` indexes the
# *running* kernel, so a driver built for another kernel (KERNELRELEASE=...,
# or a KERNELDIR=... override) gets its dependency metadata written into the
# wrong /lib/modules/<release> and is not found until the next boot.
#
# Graded through the public interface only: `make -n install ...` (the command
# make plans to run; nothing is executed, so no kernel headers are needed) and
# `make install ...` with a PATH-shimmed depmod (the argv depmod really gets).
# A real run with nothing overridden would need a writable
# /lib/modules/$(uname -r)/build, so that case is graded by dry run only.
#
# The rule under test is conditional, and the tests enforce the conditions:
#   KERNELRELEASE set   -> depmod -a <KERNELRELEASE>   (wins over KERNELDIR)
#   KERNELRELEASE empty -> old behaviour kept: exactly `depmod -a`
#   only KERNELDIR set  -> depmod -a <notdir KERNELDIR>
#   nothing set         -> exactly `depmod -a`, no stray empty argument and
#                          no trailing whitespace (a naive `depmod -a $(empty)`
#                          leaves a trailing space and is a bug, not a style
#                          choice)

set -u

. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAKEFILE="$REPO_ROOT/Makefile"
README="$REPO_ROOT/README.md"

# Nothing to grade without make: skip rather than fail on a machine that has
# no build toolchain at all.
command -v make > /dev/null 2>&1 || skip "make is not installed"

# dry_plan [make args...] -- the recipe `make -n install` plans to run.
dry_plan() { make -C "$REPO_ROOT" -n install "$@" 2>&1; }

# depmod_line <plan> -- the depmod command inside a dry-run plan, verbatim.
depmod_line() { printf '%s\n' "$1" | grep 'depmod' | tail -n 1; }

# assert_depmod_plan <expected-args> <plan> <msg> -- the planned depmod command
# is `depmod <expected-args>`, byte for byte.  Nothing is stripped from the
# actual output on purpose: a trailing space or a doubled space is exactly the
# stray-empty-argument bug this suite must catch.
assert_depmod_plan() { assert_eq "depmod $1" "$(depmod_line "$2")" "$3"; }

# assert_no_stray_whitespace <plan> <msg> -- the planned depmod command carries
# neither trailing whitespace nor a doubled space (how a stray empty argument
# reaches the shell).
assert_no_stray_whitespace() {
  _got=$(depmod_line "$1")
  case "$_got" in
    *[[:space:]]) _hda_fail "$2 (trailing whitespace in '$_got')"; return 1 ;;
    *[[:space:]][[:space:]]*) _hda_fail "$2 (doubled space in '$_got')"; return 1 ;;
  esac
  return 0
}

# setup_depmod_shim -- a depmod shim recording its argv, one argument per line,
# into $DEPMOD_LOG.  real_install puts it first on PATH.
setup_depmod_shim() {
  SHIM_ROOT=$(make_tmpdir)
  DEPMOD_LOG="$SHIM_ROOT/depmod.argv"
  mkdir -p "$SHIM_ROOT/bin"
  printf '#!/bin/sh\nprintf "%%s\\\\n" "$@" > "%s"\nexit 0\n' "$DEPMOD_LOG" \
    > "$SHIM_ROOT/bin/depmod"
  chmod +x "$SHIM_ROOT/bin/depmod"
}

# stub_kernel <dir> -- make <dir> stand in for /lib/modules/<release>: it gets a
# build/Makefile with a no-op modules_install target so the first recipe line
# of `make install` succeeds and the recipe reaches depmod, without needing
# real kernel headers or a real /lib/modules tree.
stub_kernel() {
  mkdir -p "$1/build"
  printf 'modules_install:\n\t:\n' > "$1/build/Makefile"
}

# real_install <kernel-dir> [make args...] -- run `make install` for real with
# the depmod shim first on PATH.  KERNELDIR is always passed so the build step
# resolves inside the scratch tree.  Leaves the recorded argv in $DEPMOD_LOG.
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
recorded_argv() { cat "$DEPMOD_LOG" 2>/dev/null; }

# _mentions <file> <needle> -- prints 1 when <file> contains <needle>, else 0.
# Used instead of assert_contains so a failure reports a clean yes/no rather
# than dumping the whole README into the failure message.
_mentions() {
  if grep -q -- "$2" "$1" 2>/dev/null; then printf '1'; else printf '0'; fi
}

# 1. KERNELRELEASE selects the release depmod runs for

plan=$(dry_plan KERNELRELEASE=9.9.9-test)
assert_depmod_plan "-a 9.9.9-test" "$plan" \
  "make -n install KERNELRELEASE=9.9.9-test plans 'depmod -a 9.9.9-test'"

# ... and only the depmod line changed: the modules are still installed, into
# the kernel named by KERNELRELEASE (the pre-existing KERNELDIR derivation must
# survive the edit).
assert_contains "$plan" "modules_install" \
  "the install target still plans modules_install"
assert_contains "$plan" "/lib/modules/9.9.9-test" \
  "KERNELRELEASE still selects the directory modules are installed into"

# ---------------------------------------------------------------------------
# 2. negative: nothing set -- the old "current kernel" behaviour, byte for
#    byte.  A naive `depmod -a $(empty)` shows up here as trailing whitespace.
# ---------------------------------------------------------------------------

assert_depmod_plan "-a" "$(dry_plan)" \
  "with nothing set the planned command is exactly 'depmod -a'"
assert_no_stray_whitespace "$(dry_plan)" \
  "with nothing set the planned depmod command has no stray whitespace"

# 3. boundary: KERNELRELEASE given but empty keeps the old behaviour too

assert_depmod_plan "-a" "$(dry_plan KERNELRELEASE=)" \
  "an empty KERNELRELEASE keeps the current-kernel behaviour"
assert_no_stray_whitespace "$(dry_plan KERNELRELEASE=)" \
  "an empty KERNELRELEASE leaves no stray whitespace"

# ---------------------------------------------------------------------------
# 4. derivation rule: no KERNELRELEASE, KERNELDIR overridden -- the release
#    comes from the overridden KERNELDIR
# ---------------------------------------------------------------------------

assert_depmod_plan "-a 1.2.3" "$(dry_plan KERNELDIR=/lib/modules/1.2.3)" \
  "KERNELDIR=/lib/modules/1.2.3 with no KERNELRELEASE plans 'depmod -a 1.2.3'"

# 5. precedence: KERNELRELEASE wins over an overridden KERNELDIR

assert_depmod_plan "-a 9.9.9-test" \
  "$(dry_plan KERNELDIR=/lib/modules/1.2.3 KERNELRELEASE=9.9.9-test)" \
  "KERNELRELEASE wins over an overridden KERNELDIR"

# 6. non-dry run: depmod really is invoked with the release as its argument

setup_depmod_shim

# 6a. explicit KERNELRELEASE: argv is exactly (-a, 9.9.9-test) -- no stray
#     empty argument, nothing quoted away.
real_install "$SHIM_ROOT/lib/modules/5.5.5-stub" KERNELRELEASE=9.9.9-test
assert_file_exists "$DEPMOD_LOG" \
  "make install (real run) reached the depmod shim"
assert_eq "$(printf '%s\n' -a 9.9.9-test)" "$(recorded_argv)" \
  "the real install invokes depmod with exactly -a and the release"

# 6b. derivation, real run: the release comes from the overridden KERNELDIR.
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

# 8. README documents the KERNELDIR / KERNELRELEASE usage (structural only)

assert_eq 1 "$(_mentions "$README" KERNELRELEASE)" \
  "README documents KERNELRELEASE"
assert_eq 1 "$(_mentions "$README" KERNELDIR)" \
  "README documents KERNELDIR"

finish