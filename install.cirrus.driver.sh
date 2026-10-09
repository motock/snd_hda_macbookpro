#!/bin/bash

# NOTA BENE - this script should be run as root

set -e

# Resolve the checkout once; every build path below is absolute so the
# installer works from any cwd.
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
build_dir="$repo_dir/build"
hda_dir="$build_dir/hda"

# Storing the script arguments before processing them if needed for pre617 script
script_arguments_pre617=("$@")

# Bad invocation: usage to stderr, exit 2 (exit 1 is reserved for a failed install)
usage() {
    echo "usage: $0 [-i|--install | -r|--remove | -u|--uninstall] [-k|--kernel RELEASE] [-d|--dkms] [RELEASE]" >&2
    echo "  -i, --install    install the driver (the default)" >&2
    echo "  -r, --remove     remove the driver (alias of -u)" >&2
    echo "  -u, --uninstall  remove the driver (alias of -r)" >&2
    echo "  -k, --kernel     kernel release to target (default: RELEASE, else uname -r)" >&2
    echo "  -d, --dkms       internal: set by dkms.conf PRE_BUILD" >&2
    exit 2
}

# Initialize empty variable to store the -k flag input safely
TARGET_UNAME=""

while [ $# -gt 0 ]
do
    case $1 in
    -i|--install) dkms_action='install';;
    -k|--kernel) TARGET_UNAME=${2:-}; [[ -z $TARGET_UNAME ]] && echo '-k|--kernel must be followed by a kernel version' >&2 && usage; shift;;
    -r|--remove) dkms_action='remove';;
    -u|--uninstall) dkms_action='remove';;
    -d|--dkms) dkms=true;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; usage;;
    (*) break;;
    esac
    shift
done

[[ $# -gt 1 ]] && usage

# Set UNAME prioritizing -k flag, then positional argument $1, and finally falling back to uname -r
UNAME=${TARGET_UNAME:-${1:-$(uname -r)}}

kernel_version=$(echo "$UNAME" | cut -d '-' -f1)  #ie 5.2.7
major_version=$(echo "$kernel_version" | cut -d '.' -f1)
minor_version=$(echo "$kernel_version" | cut -d '.' -f2)
major_minor=${major_version}${minor_version}

revision=$(echo "$UNAME" | cut -d '.' -f3)
revpart1=$(echo "$revision" | cut -d '-' -f1)
revpart2=$(echo "$revision" | cut -d '-' -f2)
revpart3=$(echo "$revision" | cut -d '-' -f3)

# Numeric per-component comparison: 6.9 < 6.17 and 6.100 > 6.17 (a string
# comparison gets both wrong).
version_lt() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

is_kernel_release() {
	[[ $1 =~ ^[0-9]+\.[0-9]+ ]]
}

if ! is_kernel_release "$UNAME"; then
	echo "error: invalid kernel release '$UNAME' (expected MAJOR.MINOR[.PATCH], eg 6.17.0)" >&2
	exit 1
fi

if version_lt "$kernel_version" 6.17; then

	exec "$repo_dir/install.cirrus.driver.pre617.sh" "${script_arguments_pre617[@]}"
fi

# keeping this code around in case need it for older versions later on
# This installer edits nothing: the tracked dkms.conf already carries the
# >= 6.17 values (BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409",
# BUILT_MODULE_LOCATION[0]="build/hda/codecs/cirrus",
# PRE_BUILD="install.cirrus.driver.sh -k $kernelver --dkms"), so dkms reads it
# in place.  Kernels below 6.17 are handed to install.cirrus.driver.pre617.sh
# (exec'd above), which stages its own edited copy of dkms.conf rather than
# mutating the checkout.
#if [ -e dkms.conf.orig ]; then
#    sed -i 's/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"/' dkms.conf
#else
#    sed -i.orig 's/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"/' dkms.conf
#fi
#sed -i 's/^BUILT_MODULE_LOCATION\[0\].*$/BUILT_MODULE_LOCATION[0]="build\/hda\/codecs\/cirrus"/' dkms.conf
#sed -i 's/^PRE_BUILD.*$/PRE_BUILD="install.cirrus.driver.sh -k $kernelver --dkms"/' dkms.conf

PATCH_CIRRUS=false

# remove a non-dkms cs8409 module from $1, in whichever compression the
# kernel build used, so a stale copy cannot shadow the dkms build
remove_stale_cs8409() {
    local dir=$1 ext
    for ext in ko ko.zst ko.xz ko.gz; do
        if [[ -e $dir/snd-hda-codec-cs8409.$ext ]]; then
            rm "$dir/snd-hda-codec-cs8409.$ext"
            echo "removed $dir/snd-hda-codec-cs8409.$ext"
        fi
    done
}

if [[ $dkms_action == 'install' ]]; then

    # we remove any non-dkms module just in case
    # we can only have one dkms module with same file name prefix under the whole /lib/modules/{kernel version} directory
    update_dir="/lib/modules/${UNAME}/updates/codecs/cirrus"
    remove_stale_cs8409 "$update_dir"

    # run dkms install script
    rc=0
    bash dkms.sh || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "dkms install failed (exit $rc)" >&2
    fi

    # note that Ubuntu, Debian, Fedora and others (see dkms man page) install to updates/dkms
    # and ignore DEST_MODULE_LOCATION
    # we DO want updates so that the original module is not overwritten
    # (although the original module should be copied to under /var/lib/dkms if needed for other distributions)
    update_dir="/lib/modules/${UNAME}/updates/dkms"
    echo -e "\ncontents of $update_dir"
    ls -lA "$update_dir" || true
    exit "$rc"

elif [[ $dkms_action == 'remove' ]]; then

    # we MUST call dkms remove to ensure any archived base kernel module is restored
    # and it also removes the whole dkms module subtree
    rc=0
    bash dkms.sh -r -k "$UNAME" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "dkms remove failed (exit $rc)" >&2
    fi

    exit "$rc"

fi

isdebian=0
isfedora=0
isarch=0
isvoid=0

if [ -d "/usr/src/linux-headers-${UNAME}" ]; then
	# Debian Based Distro
	isdebian=1
	:
elif [ -d "/usr/src/kernels/${UNAME}" ]; then
	# Fedora Based Distro
	isfedora=1
	:
elif [ -d "/usr/lib/modules/${UNAME}" ]; then
	# Arch Based Distro
	isarch=1
	:
elif [ -d "/usr/src/kernel-headers-${UNAME}" ]; then
	# Void Linux
	isvoid=1
	:
else
	echo "linux kernel headers not found:"
	echo "Debian (eg Ubuntu): /usr/src/linux-headers-${UNAME}"
	echo "Fedora: /usr/src/kernels/${UNAME}"
	echo "Arch: /usr/lib/modules/${UNAME}"
	echo "Void: /usr/src/kernel-headers-${UNAME}"
	echo "assuming the linux kernel headers package is not installed"
	echo "please install the appropriate linux kernel headers package:"
	echo "Debian/Ubuntu: sudo apt install linux-headers-${UNAME}"
	echo "Fedora: sudo dnf install kernel-headers"
	echo "Arch (also Manjaro): Linux: sudo pacman -S linux-headers"
	echo "Void Linux: xbps-install -S linux-headers"

	exit 1

fi

# note that the update_dir definition below relies on a symbolic link of /lib to /usr/lib on Arch
cur_dir=$repo_dir
patch_dir="$cur_dir/patch_cirrus"
makefiles_dir="$cur_dir/makefiles"
update_dir="/lib/modules/${UNAME}/updates"

[[ -d $hda_dir ]] && rm -rf "$hda_dir"
[[ ! -d $build_dir ]] && mkdir "$build_dir"

# fedora doesnt seem to install patch by default so need to explicitly install it
if [ $isfedora -ge 1 ]; then
	echo "Ensure the patch package is installed"
	[[ ! $(command -v patch) ]] && dnf install -y patch
fi

isubuntu=0
# HDA_OS_RELEASE overrides the os-release file read below; it exists so tests can
# fake a distribution. Leave it unset in normal use (defaults to /etc/os-release).
os_release=${HDA_OS_RELEASE:-/etc/os-release}
# Check if we are dealing with Ubuntu
if [ "$(grep '^NAME=' "$os_release" | grep -c Ubuntu)" -eq 1 ]; then
        isubuntu=1
# For Unbuntu based distributions like Mint, ubuntu will be mentionned in ID_LIKE
elif [ "$(grep '^ID_LIKE=' "$os_release" | grep -c "ubuntu")" -eq 1 ]; then
        isubuntu=1
# In some other Unbuntu based distributions like Pop OS, we need to check ID
elif [ "$(grep '^ID=' "$os_release" | grep -c "ubuntu")" -eq 1 ]; then
        isubuntu=1
fi

use_ubuntu_source=0
mainline_fallback=0
if [ $isubuntu -ge 1 ]; then
	# NOTE for Ubuntu we prefer the distribution kernel sources as they seem
	# to be significantly modified from the mainline kernel sources generally with backports from later kernels
	# (so far the actual debian kernels seem to be close to mainline kernels)

	# There is no linux-source-... package for Ubuntu hwe kernels (or kernels newer than the LTS one),
	# so when it is absent we fall back to the verified mainline sources below.
	# Those lack the Ubuntu backports, so the build may fail on such kernels.

	if [ -e "/usr/src/linux-source-$kernel_version.tar.bz2" ]; then
		use_ubuntu_source=1
	else
		echo "linux-source-$kernel_version not found; using mainline kernel $major_version.$minor_version sources from cdn.kernel.org instead"
		echo "(to use the Ubuntu kernel sources instead: sudo apt install linux-source-$kernel_version)"
		mainline_fallback=1
		# the full x.y.z tarball is not what we want here, so start from the base x.y release
		kernel_version=$major_version.$minor_version
	fi
fi

if [ $use_ubuntu_source -ge 1 ]; then

	tar --strip-components=2 -xvf "/usr/src/linux-source-$kernel_version.tar.bz2" --directory="$build_dir" "linux-source-$kernel_version/sound/hda"

else
	# here we assume the distribution kernel source is essentially the mainline kernel source

	set +e

	. "$(dirname "$0")/lib/verify_kernel_tarball.sh"

	# a cached tarball is only reused if it verifies; a bad one is deleted so wget -c cannot resume it
	[[ -f $build_dir/linux-$kernel_version.tar.xz ]] && { verify_kernel_tarball "$build_dir/linux-$kernel_version.tar.xz" "$kernel_version" || true; }

	# attempt to download linux-x.x.x.tar.xz kernel
	wget -c "https://cdn.kernel.org/pub/linux/kernel/v$major_version.x/linux-$kernel_version.tar.xz" -P "$build_dir"
	rc=$?

	if [[ $rc -eq 0 ]]; then
		verify_kernel_tarball "$build_dir/linux-$kernel_version.tar.xz" "$kernel_version" || exit 1
	elif [ $mainline_fallback -ge 1 ]; then
		echo "kernel $UNAME: failed to download linux-$kernel_version.tar.xz...exiting" >&2
		exit 1
	else
		echo "Failed to download linux-$kernel_version.tar.xz"
		echo "Trying to download base kernel version linux-$major_version.$minor_version.tar.xz"
		echo "This may lead to build failures as too old"
		echo "If this is an Ubuntu-based distribution this almost certainly will fail to build"
		echo ""
   		# if first attempt fails, attempt to download linux-x.x.tar.xz kernel
   		kernel_version=$major_version.$minor_version
   		[[ -f $build_dir/linux-$kernel_version.tar.xz ]] && { verify_kernel_tarball "$build_dir/linux-$kernel_version.tar.xz" "$kernel_version" || true; }
   		wget -c "https://cdn.kernel.org/pub/linux/kernel/v$major_version.x/linux-$kernel_version.tar.xz" -P "$build_dir"
		rc=$?

		[[ $rc -ne 0 ]] && echo "kernel could not be downloaded...exiting" >&2 && exit 1
		verify_kernel_tarball "$build_dir/linux-$kernel_version.tar.xz" "$kernel_version" || exit 1
	fi

	set -e

	tar --strip-components=2 -xvf "$build_dir/linux-$kernel_version.tar.xz" --directory="$build_dir" "linux-$kernel_version/sound/hda"

fi


mv "$hda_dir/Makefile" "$hda_dir/Makefile.orig"
mv "$hda_dir/common/Makefile" "$hda_dir/common//Makefile.orig"
mv "$hda_dir/codecs/Makefile" "$hda_dir/codecs//Makefile.orig"
mv "$hda_dir/codecs/cirrus/Makefile" "$hda_dir/codecs/cirrus//Makefile.orig"

cp "$makefiles_dir/Makefile" "$hda_dir"
cp "$makefiles_dir/Makefile_common" "$hda_dir/common/Makefile"
cp "$makefiles_dir/Makefile_codecs" "$hda_dir/codecs/Makefile"
cp "$makefiles_dir/Makefile_cirrus" "$hda_dir/codecs/cirrus/Makefile"

# going with explicit file names now

cp "$patch_dir/cirrus_apple.h" "$hda_dir/codecs/cirrus"
cp "$patch_dir/patch_cirrus_boot84.h" "$hda_dir/codecs/cirrus"
cp "$patch_dir/patch_cirrus_new84.h" "$hda_dir/codecs/cirrus"
cp "$patch_dir/patch_cirrus_real84.h" "$hda_dir/codecs/cirrus"
cp "$patch_dir/patch_cirrus_hda_generic_copy.h" "$hda_dir/codecs/cirrus"
cp "$patch_dir/patch_cirrus_real84_i2c.h" "$hda_dir/codecs/cirrus"


pushd "$hda_dir" > /dev/null
# the gate above guarantees kernel_version >= 6.17: 1 is the implemented
# version, 2 is later than that
iscurrent=1
if version_lt 6.17 "$kernel_version"; then
	iscurrent=2
fi

if [ $iscurrent -gt 1 ]; then
	echo "Kernel version later than implemented version - there may be build problems"
fi

if [[ ( $major_version -eq 6 && $minor_version -ge 17 ) || $major_version -ge 7 ]]; then
	if [ $isubuntu -ge 1 ]; then

		patch -b -p1 <../../patch_cs8409.c.diff

		if [ $iscurrent -ge 0 ]; then
			patch -b -p1 <../../patch_cs8409.h.diff
		else
			echo "Error: older version not implmented yet"
                        exit 1
		fi

	else
		patch -b -p1 <../../patch_cs8409.c.diff

		if [ $iscurrent -ge 0 ]; then
			patch -b -p1 <../../patch_cs8409.h.diff
		else
			echo "Error: older version not implmented yet"
                        exit 1
		fi

                # this just redos the above copies - why was it in??
		#cp $patch_dir/Makefile $patch_dir/patch_cirrus_* $hda_dir/

	fi
fi

popd > /dev/null

[[ ! $dkms_action == 'install' ]] && [[ ! -d $update_dir ]] && mkdir "$update_dir"

# Skipping patch installation since dkms will do it
if [[ ! $dkms = true ]]; then

	# The module must exist before it is installed: `make` can exit 0 without
	# producing one (a skipped object, a stale tree), and `make install` would
	# then install nothing while reporting success.  The name comes from the
	# Makefile's object list (makefiles/Makefile_cirrus, patch_cirrus/Makefile);
	# the kernel may leave it uncompressed or compress it with zstd/xz.
	check_module_built() {
		_module_dir="$hda_dir/codecs/cirrus"
		_module_name=snd-hda-codec-cs8409
		for _ext in ko ko.zst ko.xz; do
			if [ -s "$_module_dir/$_module_name.$_ext" ]; then
				return 0
			fi
		done
		echo "error: $_module_name.{ko,ko.zst,ko.xz} not found (or empty) in $_module_dir after build" >&2
		exit 1
	}

	rc=0
	if [ $PATCH_CIRRUS = true ]; then
		make -C "$repo_dir" PATCH_CIRRUS=1 || rc=$?
		check_module_built
		make -C "$repo_dir" install PATCH_CIRRUS=1 || rc=$?

	else
		make -C "$repo_dir" "KERNELRELEASE=$UNAME" || rc=$?
		check_module_built
		make -C "$repo_dir" install "KERNELRELEASE=$UNAME" || rc=$?

	fi
	if [[ $rc -ne 0 ]]; then
		echo "make failed (exit $rc)" >&2
	fi
	echo -e "\ncontents of $update_dir/codecs/cirrus"
	ls -lA "$update_dir/codecs/cirrus" || true
	exit "$rc"
fi
