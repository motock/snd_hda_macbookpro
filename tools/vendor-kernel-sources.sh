#!/usr/bin/env bash
#
# tools/vendor-kernel-sources.sh -- vendor the cs8409 build inputs of one kernel.
#
#     vendor-kernel-sources.sh <version> [--out vendor]
#
# Fetches linux-<version>.tar.xz from kernel.org, verifies it against the
# published SHA-256 (lib/verify_kernel_tarball.sh; a mismatch is fatal), and
# copies the include closure of codecs/cirrus/cs8409{.c,.h,-tables.c} (see
# tools/layout-hash.sh) into <out>/linux-<version>/sound/hda/..., together
# with a MANIFEST.  Nothing from the tarball is executed.
#
# Environment:
#   HDA_KERNEL_MIRROR  directory URL holding the tarball
#                      (default https://cdn.kernel.org/pub/linux/kernel/v<major>.x)
#   HDA_VENDOR_CACHE   cache root; tarballs live in $HDA_VENDOR_CACHE/tarballs
#                      (default ${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-vendor)

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

die() {
	echo "vendor-kernel-sources: $*" >&2
	exit 1
}

sha256_of() {
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

version=""
out="$repo/vendor"
while [[ $# -gt 0 ]]; do
	case $1 in
	--out)
		[[ $# -ge 2 ]] || die "--out needs a directory"
		out=$2
		shift 2
		;;
	-*) die "unknown option: $1" ;;
	*)
		[[ -z $version ]] || die "unexpected argument: $1"
		version=$1
		shift
		;;
	esac
done

[[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "invalid kernel version '$version' (want e.g. 7.0 or 7.0.14)"
[[ $(id -u) -ne 0 ]] || die "refusing to run as root"

# shellcheck source=lib/verify_kernel_tarball.sh
. "$repo/lib/verify_kernel_tarball.sh"

major=${version%%.*}
name="linux-$version.tar.xz"
mirror=${HDA_KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v$major.x}
cache="${HDA_VENDOR_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/snd_hda_macbookpro-vendor}/tarballs"
tarball="$cache/$name"

work=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$cache" || die "cannot create $cache"
if [[ ! -f $tarball ]]; then
	wget -q -O "$work/download" "${mirror%/}/$name" || die "cannot download ${mirror%/}/$name"
	mv -f -- "$work/download" "$tarball" || die "cannot store $tarball"
fi
# always verified, cached or not; a mismatch deletes the file
verify_kernel_tarball "$tarball" "$version" || die "tarball verification failed"
tarball_sha=$(sha256_of "$tarball")

# refuse the whole archive if any member path is absolute or climbs out
members=$(tar -tf "$tarball") || die "cannot list $name"
while IFS= read -r member; do
	case $member in
	/* | .. | ../* | */.. | */../*) die "unsafe member path in $name: $member" ;;
	esac
done <<< "$members"

tree="$work/tree"
mkdir "$tree"
tar -xf "$tarball" -C "$tree" --strip-components=1 --no-same-owner "linux-$version/sound/hda" \
	|| die "cannot extract sound/hda from $name"
[[ -z $(find "$tree" ! -type d ! -type f) ]] || die "$name contains links or special files under sound/hda"

hda="$tree/sound/hda"
closure=$(bash "$here/layout-hash.sh" --files "$hda") || die "include closure failed"

snap="$work/linux-$version"
mkdir -p "$snap"
while IFS= read -r f; do
	mkdir -p "$snap/sound/hda/$(dirname "$f")"
	cp -- "$hda/$f" "$snap/sound/hda/$f"
done <<< "$closure"

layout=$(bash "$here/layout-hash.sh" "$snap/sound/hda") || die "layout hash failed"
{
	echo "tarball $name"
	echo "tarball-sha256 $tarball_sha"
	echo "layout-hash $layout"
	(cd "$snap" && find sound -type f | LC_ALL=C sort | while IFS= read -r f; do
		printf '%s  %s\n' "$(sha256_of "$f")" "$f"
	done)
} > "$snap/MANIFEST"

mkdir -p "$out" || die "cannot create $out"
rm -rf -- "${out:?}/linux-$version"
mv -- "$snap" "$out/linux-$version" || die "cannot install snapshot into $out"
echo "vendored $name -> $out/linux-$version (layout hash $layout)"
