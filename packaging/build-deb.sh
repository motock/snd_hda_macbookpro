#!/usr/bin/env bash
#
# packaging/build-deb.sh -- build the snd-hda-macbookpro-dkms .deb.
#
# usage: build-deb.sh --version X.Y.Z --out DIR [--maintainer "Name <mail>"]
#                     [--stage-only] [--src-dir DIR]
#
#   --version     package version; ^[0-9]+\.[0-9]+\.[0-9]+([~+][0-9A-Za-z.]+)?$
#   --out         directory the .deb is written to (created if missing).  With
#                 --stage-only it is the staging root instead and no .deb is
#                 built (dpkg-deb is not needed).
#   --maintainer  control Maintainer field; default: git config user.name and
#                 user.email of the invoking directory.
#   --src-dir     tree to package (default: the repository this script is in).
#
# The staged tree holds exactly what a DKMS build needs under
# usr/src/snd_hda_macbookpro-<version>/; dkms.conf is rewritten in the staged
# copy only, the tracked file is never modified.
#
# Exit status: 0 ok, 1 failure, 2 usage error.

set -eu

NAME=snd_hda_macbookpro
PACKAGE=snd-hda-macbookpro-dkms
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+([~+][0-9A-Za-z.]+)?$'

usage() {
  printf 'usage: %s --version X.Y.Z --out DIR [--maintainer "Name <mail>"] [--stage-only] [--src-dir DIR]\n' "$0" >&2
  exit 2
}

die() {
  printf 'build-deb.sh: %s\n' "$*" >&2
  exit 1
}

version=
out=
maintainer=
stage_only=0
src_dir=$(cd "$(dirname "$0")/.." && pwd)

while [ "$#" -gt 0 ]; do
  case $1 in
    --version | --out | --maintainer | --src-dir)
      [ "$#" -ge 2 ] || usage
      case $1 in
        --version) version=$2 ;;
        --out) out=$2 ;;
        --maintainer) maintainer=$2 ;;
        --src-dir) src_dir=$2 ;;
      esac
      shift 2 ;;
    --stage-only) stage_only=1; shift ;;
    *) usage ;;
  esac
done

[ -n "$out" ] || usage
[ -n "$version" ] || usage
printf '%s\n' "$version" | grep -Eq "$VERSION_RE" || die "invalid version '$version' (expected X.Y.Z[~+suffix])"

if [ -z "$maintainer" ]; then
  git_name=$(git config user.name 2>/dev/null || true)
  git_email=$(git config user.email 2>/dev/null || true)
  [ -n "$git_name" ] && [ -n "$git_email" ] || die "no maintainer: pass --maintainer or set git config user.name and user.email"
  maintainer="$git_name <$git_email>"
fi

for f in install.cirrus.driver.sh install.cirrus.driver.pre617.sh dkms.sh dkms.conf Makefile LICENSE; do
  [ -f "$src_dir/$f" ] || die "missing $f in $src_dir"
done
for d in makefiles patch_cirrus patches lib vendor; do
  [ -d "$src_dir/$d" ] || die "missing directory $d/ in $src_dir"
done
ls "$src_dir"/*.diff >/dev/null 2>&1 || die "no *.diff patch files in $src_dir"

if [ "$stage_only" -eq 1 ]; then
  stage=$out
  mkdir -p "$stage" || die "cannot create $stage"
else
  command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found"
  mkdir -p "$out" || die "cannot create $out"
  [ -w "$out" ] || die "$out is not writable"
  stage=$(mktemp -d "${TMPDIR:-/tmp}/build-deb.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  chmod 0755 "$stage" # mktemp -d is 0700 and would become the mode of /
fi

payload="$stage/usr/src/$NAME-$version"
mkdir -p "$payload" "$stage/DEBIAN" "$stage/usr/share/doc/$PACKAGE"

for f in install.cirrus.driver.sh install.cirrus.driver.pre617.sh dkms.sh Makefile LICENSE; do
  cp "$src_dir/$f" "$payload/$f"
done
cp "$src_dir"/*.diff "$payload/"
for d in makefiles patch_cirrus patches lib vendor; do
  cp -R "$src_dir/$d" "$payload/$d"
done

# Rewrite PACKAGE_VERSION in the staged copy only. The version matched
# VERSION_RE, so it is safe inside a sed replacement.
sed "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$version\"/" "$src_dir/dkms.conf" > "$payload/dkms.conf"
if cmp -s "$src_dir/dkms.conf" "$payload/dkms.conf"; then
  die "dkms.conf PACKAGE_VERSION was not changed to $version"
fi
grep -qx "PACKAGE_VERSION=\"$version\"" "$payload/dkms.conf" || die "dkms.conf PACKAGE_VERSION rewrite failed"

# Debian policy 12.5 wants a copyright file; the licence text stays in the
# source tree.
cat > "$stage/usr/share/doc/$PACKAGE/copyright" <<COPYRIGHT
snd_hda_macbookpro is licensed under the GNU General Public License,
version 2. The full text is in
/usr/src/$NAME-$version/LICENSE and
/usr/share/common-licenses/GPL-2 on Debian systems.
COPYRIGHT

installed_size=$(du -sk "$stage/usr" | cut -f1)
cat > "$stage/DEBIAN/control" <<CONTROL
Package: $PACKAGE
Version: $version
Architecture: all
Maintainer: $maintainer
Section: sound
Priority: optional
Installed-Size: $installed_size
Depends: dkms, make, patch, gcc, linux-headers-generic | linux-headers-amd64 | linux-headers
Recommends: wget
Description: Cirrus CS8409 HDA audio driver for Apple Macs (DKMS source)
 Installs the sources of the snd_hda_macbookpro driver for the Cirrus
 CS8409 HDA codec found in Apple Macs and registers them with DKMS, so
 the module is rebuilt automatically for each new kernel. It was
 verified only on an iMac18,2 (iMac 2017); other Macs and kernels are
 untested. Kernels without a vendored snapshot make DKMS download the
 kernel source, which needs network access.
CONTROL

cat > "$stage/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
# Registers the module with DKMS and builds it for the running kernel when
# its headers are present. A failed build is reported but never fails the
# package operation; the module is retried on the next kernel install
# (AUTOINSTALL).
set -e

NAME=snd_hda_macbookpro
VERSION="__VERSION__"

[ "$1" = configure ] || exit 0

if ! command -v dkms >/dev/null 2>&1; then
  echo "$NAME: dkms not found; the module was not registered." >&2
  exit 0
fi

if ! add_out=$(dkms add -m "$NAME" -v "$VERSION" 2>&1); then
  case $add_out in
    *"already added"* | *"already contains"* | *"more than once"*) ;;
    *)
      echo "$NAME: 'dkms add' failed:" >&2
      echo "$add_out" >&2
      echo "$NAME: run 'dkms add -m $NAME -v $VERSION' to see the error again." >&2
      exit 0 ;;
  esac
fi

kernel=$(uname -r)
if [ ! -d "${DPKG_ROOT:-}/lib/modules/$kernel/build" ]; then
  echo "$NAME: headers for the running kernel $kernel are not installed;" >&2
  echo "$NAME: the module will be built when a kernel with headers is installed." >&2
  exit 0
fi

if ! dkms install -m "$NAME" -v "$VERSION" -k "$kernel"; then
  echo "$NAME: the module build for $kernel failed; the package stays installed." >&2
  echo "$NAME: see /var/lib/dkms/$NAME/$VERSION/build/make.log or run 'dkms status'." >&2
fi
exit 0
POSTINST

cat > "$stage/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
# Removes every DKMS build of this version before the sources go away.
# A missing dkms or an unknown module never blocks removal.
set -e

NAME=snd_hda_macbookpro
VERSION="__VERSION__"

case "$1" in
  remove | upgrade | deconfigure) ;;
  *) exit 0 ;;
esac

if ! command -v dkms >/dev/null 2>&1; then
  echo "$NAME: dkms not found; nothing to remove." >&2
  exit 0
fi

if ! dkms remove -m "$NAME" -v "$VERSION" --all; then
  echo "$NAME: 'dkms remove' reported an error (continuing; is the module already removed?)." >&2
fi
exit 0
PRERM

for s in postinst prerm; do
  sed "s/__VERSION__/$version/" "$stage/DEBIAN/$s" > "$stage/DEBIAN/$s.tmp"
  mv "$stage/DEBIAN/$s.tmp" "$stage/DEBIAN/$s"
  chmod 0755 "$stage/DEBIAN/$s"
done

[ "$stage_only" -eq 0 ] || exit 0

compress=xz
command -v xz >/dev/null 2>&1 || compress=gzip
deb="$out/${PACKAGE}_${version}_all.deb"
dpkg-deb --root-owner-group "-Z$compress" --build "$stage" "$deb" >/dev/null || { rm -f "$deb"; die "dpkg-deb failed"; }
printf '%s\n' "$deb"
