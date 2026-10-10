#!/usr/bin/env bash
#
# tests/test_build_deb.sh -- packaging/build-deb.sh and the maintainer scripts
# it generates.
#
#   V   version validation: bad versions are refused and leave no output
#   U   usage / environment errors: missing --out, missing vendor/, unusable
#       output directory
#   S   --stage-only tree: exact payload, rewritten dkms.conf, tracked
#       dkms.conf untouched, control fields, DEBIAN scripts parse
#   P   postinst with dkms shimmed (add/install/headers behaviour)
#   R   prerm with and without dkms on PATH
#   B   the real .deb (needs dpkg-deb; exits 77 after everything above when
#       dpkg-deb is missing)
#
# Exit codes: 0 pass, 1 fail, 77 skip.

. "$(dirname "$0")/lib/assert.sh"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT" || exit 1

BUILD=packaging/build-deb.sh
PKG=snd-hda-macbookpro-dkms
SRCDIR=snd_hda_macbookpro
VER=1.2.3
MAINT="Test Packager <packager@example.invalid>"

# run_build <out> [args...] -- run the build script, capture stdout+stderr in
# $OUT and the exit status in $RC.
run_build() {
  OUT=$(bash "$BUILD" "$@" 2>&1)
  RC=$?
}

stage() { # stage <dir> [version]
  run_build --version "${2:-$VER}" --out "$1" --stage-only --maintainer "$MAINT"
}

# --- V: version validation ------------------------------------------------------

for bad in '1.2' 'v1.2.3' '1.2.3; rm -rf /' '' '1.2.3-1' '1.2.3~' '1.2.3 '; do
  d=$(make_tmpdir)/out
  run_build --version "$bad" --out "$d" --stage-only --maintainer "$MAINT"
  assert_ne 0 "$RC" "V rejects version '$bad'"
  assert_eq "" "$(ls -A "$d" 2>/dev/null)" "V version '$bad' leaves no output"
done

for good in 1.2.3 1.2.3~rc1 1.2.3+git.4 0.0.0~ci7; do
  d=$(make_tmpdir)/out
  stage "$d" "$good"
  assert_eq 0 "$RC" "V accepts version '$good'"
done

# --- U: usage and environment errors -------------------------------------------

run_build --version "$VER" --stage-only
assert_eq 2 "$RC" "U missing --out exits 2"
assert_contains "$OUT" "usage" "U missing --out prints usage"

run_build --out "$(make_tmpdir)/o" --stage-only
assert_eq 2 "$RC" "U missing --version exits 2"

run_build --version "$VER" --out "$(make_tmpdir)/o" --bogus
assert_eq 2 "$RC" "U unknown option exits 2"

# a source tree without vendor/
fx=$(make_tmpdir)/src
mkdir -p "$fx/makefiles" "$fx/patch_cirrus" "$fx/patches" "$fx/lib"
for f in install.cirrus.driver.sh install.cirrus.driver.pre617.sh dkms.sh Makefile LICENSE a.diff; do
  : > "$fx/$f"
done
printf 'PACKAGE_VERSION="0.1"\n' > "$fx/dkms.conf"
run_build --version "$VER" --out "$(make_tmpdir)/o" --stage-only --maintainer "$MAINT" --src-dir "$fx"
assert_ne 0 "$RC" "U missing vendor/ fails"
assert_contains "$OUT" "vendor" "U missing vendor/ names the directory"

# an output path below a regular file cannot be created, whoever runs the test
blocker=$(make_tmpdir)/file
: > "$blocker"
run_build --version "$VER" --out "$blocker/sub" --stage-only --maintainer "$MAINT"
assert_ne 0 "$RC" "U unusable output directory fails"

# --- S: staged tree ----------------------------------------------------------------

before=$(cksum < dkms.conf)
stagedir=$(make_tmpdir)/stage
stage "$stagedir"
assert_eq 0 "$RC" "S --stage-only succeeds ($OUT)"
root="$stagedir/usr/src/$SRCDIR-$VER"

expected="LICENSE
Makefile
dkms.conf
dkms.sh
install.cirrus.driver.pre617.sh
install.cirrus.driver.sh
lib
makefiles
patch_cirrus
patches
vendor"
expected="$expected
$(ls ./*.diff | sed 's|^\./||')"
expected=$(printf '%s\n' "$expected" | LC_ALL=C sort)
assert_eq "$expected" "$(ls -A "$root" | LC_ALL=C sort)" "S payload is exactly the DKMS build inputs"

assert_eq "" "$(find "$stagedir" \( -name tests -o -name .git -o -name build -o -name packaging -o -name NOTES.md \) | head -1)" "S no tests/.git/build/packaging/NOTES.md staged"
assert_eq 'PACKAGE_VERSION="1.2.3"' "$(grep '^PACKAGE_VERSION=' "$root/dkms.conf")" "S staged dkms.conf carries the version"
assert_eq "$before" "$(cksum < dkms.conf)" "S tracked dkms.conf is unchanged"
assert_eq "" "$(git status --porcelain -- dkms.conf)" "S git sees no change to dkms.conf"
assert_eq "$(grep -v '^PACKAGE_VERSION=' dkms.conf)" "$(grep -v '^PACKAGE_VERSION=' "$root/dkms.conf")" "S only PACKAGE_VERSION differs in dkms.conf"

ctl="$stagedir/DEBIAN/control"
assert_contains "$(cat "$ctl")" "Package: $PKG" "S control Package"
assert_contains "$(cat "$ctl")" "Version: $VER" "S control Version"
assert_contains "$(cat "$ctl")" "Architecture: all" "S control Architecture"
assert_contains "$(cat "$ctl")" "Section: sound" "S control Section"
assert_contains "$(cat "$ctl")" "Priority: optional" "S control Priority"
assert_contains "$(cat "$ctl")" "Maintainer: $MAINT" "S control Maintainer from --maintainer"
assert_contains "$(cat "$ctl")" "Recommends: wget" "S control Recommends"
assert_contains "$(grep '^Depends:' "$ctl")" "dkms, make, patch, gcc, linux-headers-generic | linux-headers-amd64 | linux-headers" "S control Depends"
assert_contains "$(cat "$ctl")" "iMac18,2" "S description names the verified machine"
assert_contains "$(cat "$ctl")" "CS8409" "S description names the codec"

sh -n "$stagedir/DEBIAN/postinst"
assert_eq 0 $? "S postinst parses with sh -n"
sh -n "$stagedir/DEBIAN/prerm"
assert_eq 0 $? "S prerm parses with sh -n"
assert_eq "#!/bin/sh" "$(head -1 "$stagedir/DEBIAN/postinst")" "S postinst shebang"
assert_eq "#!/bin/sh" "$(head -1 "$stagedir/DEBIAN/prerm")" "S prerm shebang"
assert_contains "$(cat "$stagedir/DEBIAN/postinst")" "$VER" "S postinst names the version"
assert_contains "$(cat "$stagedir/DEBIAN/prerm")" "$VER" "S prerm names the version"

# maintainer falls back to git config; with neither, the build refuses
run_build --version "$VER" --out "$(make_tmpdir)/o" --stage-only
if [ -n "$(git config user.name)" ] && [ -n "$(git config user.email)" ]; then
  assert_eq 0 "$RC" "S maintainer defaults to git config"
fi
nogit=$(make_tmpdir)
OUT=$(cd "$nogit" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$nogit" \
  bash "$REPO_ROOT/$BUILD" --version "$VER" --out "$nogit/o" --stage-only 2>&1)
assert_ne 0 $? "S no maintainer anywhere is refused"
assert_contains "$OUT" "maintainer" "S refusal names --maintainer"

# --- P: postinst --------------------------------------------------------------------

shim=$(make_tmpdir)
sysroot=$(make_tmpdir)
KREL=6.8.0-test
cat > "$shim/uname" <<SH
#!/bin/sh
echo $KREL
SH
cat > "$shim/dkms" <<'SH'
#!/bin/sh
echo "dkms $*" >> "$DKMS_LOG"
case "$1" in
  add)
    case "${DKMS_ADD:-ok}" in
      already) echo "Error! DKMS tree already contains: snd_hda_macbookpro-1.2.3 (already added)" >&2; exit 3;;
      other) echo "Error! something else broke" >&2; exit 4;;
    esac;;
  install)
    [ "${DKMS_INSTALL:-ok}" = fail ] && { echo "Error! Bad return status for module build" >&2; exit 10; };;
  remove)
    [ "${DKMS_REMOVE:-ok}" = notfound ] && { echo "Error! The module/version combo is not located" >&2; exit 3; };;
esac
exit 0
SH
chmod +x "$shim/uname" "$shim/dkms"

# run_script <script> <args...> with env from the caller: sets OUT, RC, LOG
run_script() {
  LOG=$(make_tmpdir)/dkms.log
  : > "$LOG"
  OUT=$(PATH="$shim:$PATH" DKMS_LOG="$LOG" DPKG_ROOT="$sysroot" sh "$@" 2>&1)
  RC=$?
}

mkdir -p "$sysroot/lib/modules/$KREL/build"

run_script "$stagedir/DEBIAN/postinst" configure
assert_eq 0 "$RC" "P happy path exits 0"
assert_contains "$(cat "$LOG")" "dkms add -m $SRCDIR -v $VER" "P adds the module"
assert_contains "$(cat "$LOG")" "dkms install -m $SRCDIR -v $VER -k $KREL" "P installs for the running kernel"

DKMS_ADD=already run_script "$stagedir/DEBIAN/postinst" configure
assert_eq 0 "$RC" "P 'already added' still exits 0"
assert_contains "$(cat "$LOG")" "dkms install" "P 'already added' still installs"

DKMS_ADD=other run_script "$stagedir/DEBIAN/postinst" configure
assert_eq 0 "$RC" "P other add failure exits 0"
assert_contains "$OUT" "something else broke" "P other add failure is reported"
assert_not_contains "$(cat "$LOG")" "dkms install" "P no install after a failed add"

DKMS_INSTALL=fail run_script "$stagedir/DEBIAN/postinst" configure
assert_eq 0 "$RC" "P failed build exits 0"
assert_contains "$OUT" "make.log" "P failed build names the build log"

run_script "$stagedir/DEBIAN/postinst" abort-upgrade
assert_eq 0 "$RC" "P non-configure action exits 0"
assert_eq "" "$(cat "$LOG")" "P non-configure action does nothing"

rm -rf "$sysroot/lib/modules/$KREL/build"
run_script "$stagedir/DEBIAN/postinst" configure
assert_eq 0 "$RC" "P missing headers exits 0"
assert_not_contains "$(cat "$LOG")" "dkms install" "P missing headers: no install attempt"
assert_contains "$(cat "$LOG")" "dkms add" "P missing headers: module is still added"
assert_contains "$OUT" "headers" "P missing headers: says so"

# --- R: prerm --------------------------------------------------------------------------

for action in remove upgrade deconfigure; do
  run_script "$stagedir/DEBIAN/prerm" "$action"
  assert_eq 0 "$RC" "R $action exits 0"
  assert_contains "$(cat "$LOG")" "dkms remove -m $SRCDIR -v $VER --all" "R $action removes every kernel's build"
done

DKMS_REMOVE=notfound run_script "$stagedir/DEBIAN/prerm" remove
assert_eq 0 "$RC" "R 'not found' is tolerated"

run_script "$stagedir/DEBIAN/prerm" failed-upgrade
assert_eq "" "$(cat "$LOG")" "R other actions do nothing"

emptybin=$(make_tmpdir)
OUT=$(PATH="$emptybin" /bin/sh "$stagedir/DEBIAN/prerm" remove 2>&1)
assert_eq 0 $? "R dkms absent from PATH exits 0"

# --- B: the real package ---------------------------------------------------------------

if ! command -v dpkg-deb >/dev/null 2>&1; then
  [ "$HDA_ASSERT_FAILURES" -eq 0 ] && skip "dpkg-deb not found; package-level checks not run"
  finish
fi

outdir=$(make_tmpdir)/out
run_build --version "$VER" --out "$outdir" --maintainer "$MAINT"
assert_eq 0 "$RC" "B build succeeds ($OUT)"
deb="$outdir/${PKG}_${VER}_all.deb"
assert_file_exists "$deb" "B package has the documented file name"

paths=$(dpkg-deb --contents "$deb" | awk '{print $6}')
for want in dkms.conf dkms.sh Makefile LICENSE install.cirrus.driver.sh install.cirrus.driver.pre617.sh makefiles/ patch_cirrus/ patches/ lib/ vendor/; do
  assert_contains "$paths" "./usr/src/$SRCDIR-$VER/$want" "B package contains $want"
done
assert_eq "drwxr-xr-x" "$(dpkg-deb --contents "$deb" | awk '$6 == "./" {print $1}')" "B package root directory is 0755"
assert_not_contains "$paths" "/tests/" "B package has no tests/"
assert_not_contains "$paths" "/.git" "B package has no .git"
assert_not_contains "$paths" "NOTES.md" "B package has no NOTES.md"
assert_not_contains "$paths" "/packaging/" "B package has no packaging/"

assert_eq "$PKG" "$(dpkg-deb --field "$deb" Package)" "B Package field"
assert_eq "$VER" "$(dpkg-deb --field "$deb" Version)" "B Version field"
assert_eq "all" "$(dpkg-deb --field "$deb" Architecture)" "B Architecture field"
inner=$(dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "./usr/src/$SRCDIR-$VER/dkms.conf" | grep '^PACKAGE_VERSION=')
assert_eq 'PACKAGE_VERSION="1.2.3"' "$inner" "B packaged dkms.conf carries the version"
assert_eq "$before" "$(cksum < dkms.conf)" "B tracked dkms.conf is unchanged after a build"

ctrl=$(make_tmpdir)/ctrl
dpkg-deb --control "$deb" "$ctrl"
sh -n "$ctrl/postinst"
assert_eq 0 $? "B packaged postinst parses"
sh -n "$ctrl/prerm"
assert_eq 0 $? "B packaged prerm parses"

# an unwritable --out leaves no package behind
run_build --version "$VER" --out "$blocker/sub" --maintainer "$MAINT"
assert_ne 0 "$RC" "B unusable output directory fails"

finish
