#!/bin/bash

# NOTA BENE - this script should be run as root

#echo "SCRIPT ARGS ${@}"

set -e

# Resolve the checkout once; every build path below is absolute so the
# installer works from any cwd.
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
build_dir="$repo_dir/build"
hda_dir="$build_dir/hda"

# Initialize empty variable to store the -k flag input safely
TARGET_UNAME=""

while [ $# -gt 0 ]
do
    case $1 in
    -i|--install) dkms_action='install';;
    -k|--kernel) TARGET_UNAME=$2; [[ -z $TARGET_UNAME ]] && echo '-k|--kernel must be followed by a kernel version' && exit 1; shift;;
    -r|--remove) dkms_action='remove';;
    -u|--uninstall) dkms_action='remove';;
    -d|--dkms) dkms=true;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 1;;
    (*) break;;
    esac
    shift
done

# Set UNAME prioritizing -k flag, then positional argument $1, and finally falling back to uname -r
UNAME=${TARGET_UNAME:-${1:-$(uname -r)}}

kernel_version=$(echo $UNAME | cut -d '-' -f1)  #ie 5.2.7
major_version=$(echo $kernel_version | cut -d '.' -f1)
minor_version=$(echo $kernel_version | cut -d '.' -f2)
major_minor=${major_version}${minor_version}

revision=$(echo $UNAME | cut -d '.' -f3)
revpart1=$(echo $revision | cut -d '-' -f1)
revpart2=$(echo $revision | cut -d '-' -f2)
revpart3=$(echo $revision | cut -d '-' -f3)

. "$repo_dir/lib/kernel_version.sh"

if ! is_kernel_release "$UNAME"; then
	echo "error: invalid kernel release '$UNAME' (expected MAJOR.MINOR[.PATCH], eg 6.8.0)" >&2
	exit 1
fi

if ! version_lt "$kernel_version" 6.17; then
	echo "error: kernel $UNAME is 6.17 or later - use install.cirrus.driver.sh for kernels >= 6.17" >&2
	exit 1
fi


# The dkms.conf edits that used to be applied here are now applied to a staged
# copy of the tree (see the dkms install branch below), never to the tracked
# $repo/dkms.conf.  dkms.sh runs `dkms install -c dkms.conf` from its own
# directory, so editing the checkout in place dirtied it -- and the first run's
# `sed -i.orig` also left an untracked dkms.conf.orig behind.  Only the module
# name depends on the kernel version.
if [ $major_version -eq 5 -a $minor_version -lt 13 ]; then
    DKMS_BUILT_MODULE_NAME="snd-hda-codec-cirrus"
    PATCH_CIRRUS=true
else
    DKMS_BUILT_MODULE_NAME="snd-hda-codec-cs8409"
    PATCH_CIRRUS=false
fi

# Persistent staged copy of the tree for dkms (see the install branch).  Sits
# next to the /usr/src/snd_hda_macbookpro-0.1 symlink dkms.sh creates.
# SND_HDA_USR_SRC lets the tests redirect /usr/src into a sandbox.
usr_src=${SND_HDA_USR_SRC:-/usr/src}
src_link="$usr_src/snd_hda_macbookpro-0.1"
stage_dir="$usr_src/snd_hda_macbookpro-0.1.src"

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
    update_dir="/lib/modules/${UNAME}/updates"
    remove_stale_cs8409 "$update_dir"

    # dkms.sh runs `dkms install -c dkms.conf` from its own directory and
    # symlinks that directory into /usr/src, so dkms reads dkms.conf in place.
    # Editing the tracked $repo/dkms.conf would dirty the checkout (and the old
    # `sed -i.orig` also left an untracked dkms.conf.orig behind), so stage a
    # copy of the tree dkms needs in a temp dir, edit the copy, and point dkms
    # at the copy.  dkms keeps building from the /usr/src symlink (AUTOINSTALL),
    # so the copy must outlive this script: it is removed only if the install
    # fails or on uninstall, never on a successful exit.
    repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir" || { echo "cannot create a staging directory" >&2; exit 1; }

    for _entry in "$repo_dir"/*; do
        [[ -e $_entry ]] || continue
        case "${_entry##*/}" in
            # build/ is a previous run's output and tests/ is not needed by dkms
            build|tests) continue ;;
        esac
        cp -R "$_entry" "$stage_dir/" || { echo "cannot stage $_entry" >&2; exit 1; }
    done

    sed -i "s/^BUILT_MODULE_NAME\[0\].*$/BUILT_MODULE_NAME[0]=\"$DKMS_BUILT_MODULE_NAME\"/" "$stage_dir/dkms.conf"
    sed -i 's/^BUILT_MODULE_LOCATION\[0\].*$/BUILT_MODULE_LOCATION[0]="build\/hda"/' "$stage_dir/dkms.conf"
    sed -i 's/^PRE_BUILD.*$/PRE_BUILD="install.cirrus.driver.pre617.sh -k $kernelver --dkms"/' "$stage_dir/dkms.conf"

    # run dkms install script against the staged copy
    rc=0
    ( cd "$stage_dir" && bash dkms.sh ) || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "dkms install failed (exit $rc)" >&2
        # leave no half-state behind: the staged copy and the link into it
        rm -rf "$stage_dir"
        [[ -L $src_link && ! -e $src_link ]] && rm -f "$src_link"
    fi

    # note that Ubuntu, Debian, Fedora and others (see dkms man page) install to updates/dkms
    # and ignore DEST_MODULE_LOCATION
    # we DO want updates so that the original module is not overwritten
    # (although the original module should be copied to under /var/lib/dkms if needed for other distributions)
    update_dir="/lib/modules/${UNAME}/updates"
    echo -e "\ncontents of $update_dir"
    ls -lA $update_dir || true
    exit "$rc"

elif [[ $dkms_action == 'remove' ]]; then

    # under ubuntu 6.8 although the dkms manual entry says it archives original modules
    # it doesnt appear to do this
    # at 6.17 dkms DOES archive the original module (logged) and so MUST do dkms remove to re-install it
    # dkms.sh updated to reflect this

    # we MUST call dkms remove to ensure any archived base kernel module is restored
    # and it also removes the whole dkms module subtree
    rc=0
    bash dkms.sh -r || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "dkms remove failed (exit $rc)" >&2
    else
        # dkms.sh -r only removes the link if it resolves; clear the staged
        # copy first, then any link left dangling by it (or by an older install)
        rm -rf "$stage_dir"
        [[ -L $src_link && ! -e $src_link ]] && rm -f "$src_link"
    fi

    exit "$rc"

fi

if [ $major_version == '4' ]; then
	echo "Kernel 4 versions no longer supported"
fi

if [ $major_version -eq 5 -a $minor_version -lt 8 ]; then
	echo "Kernel 5 versions less than 5.8 no longer supported"
fi

isdebian=0
isfedora=0
isarch=0
isvoid=0

if [ -d /usr/src/linux-headers-${UNAME} ]; then
	# Debian Based Distro
	isdebian=1
	:
elif [ -d /usr/src/kernels/${UNAME} ]; then
	# Fedora Based Distro
	isfedora=1
	:
elif [ -d /usr/lib/modules/${UNAME} ]; then
	# Arch Based Distro
	isarch=1
	:
elif [ -d /usr/src/kernel-headers-${UNAME} ]; then
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
update_dir="/lib/modules/${UNAME}/updates"

[[ -d $hda_dir ]] && rm -rf "$hda_dir"
[[ ! -d $build_dir ]] && mkdir "$build_dir"

# fedora doesnt seem to install patch by default so need to explicitly install it
if [ $isfedora -ge 1 ]; then
	echo "Ensure the patch package is installed"
	[[ ! $(command -v patch) ]] && dnf install -y patch
fi

isubuntu=0
# Check if we are dealing with Ubuntu
if [ $(grep '^NAME=' /etc/os-release | grep -c Ubuntu) -eq 1 ]; then
        isubuntu=1
# For Unbuntu based distributions like Mint, ubuntu will be mentionned in ID_LIKE
elif [ $(grep '^ID_LIKE=' /etc/os-release | grep -c "ubuntu") -eq 1 ]; then
        isubuntu=1
# In some other Unbuntu based distributions like Pop OS, we need to check ID
elif [ $(grep '^ID=' /etc/os-release | grep -c "ubuntu") -eq 1 ]; then
        isubuntu=1
fi

if [ $isubuntu -ge 1 ]; then

	# NOTE for Ubuntu we need to use the distribution kernel sources as they seem
	# to be significantly modified from the mainline kernel sources generally with backports from later kernels
	# (so far the actual debian kernels seem to be close to mainline kernels)

	# NOTA BENE this will likely NOT work for Ubuntu hwe kernels which are even more highly
        #           modified with extensive backports from later kernel versions
        #           (and in any case there is no linux-source-... package for hwe kernels)

	if [ ! -e /usr/src/linux-source-$kernel_version.tar.bz2 ]; then

		echo "Ubuntu linux kernel source not found in /usr/src: /usr/src/linux-source-$kernel_version.tar.bz2"
		echo "assuming the linux kernel source package is not installed"
		echo "please install the linux kernel source package:"
		echo "sudo apt install linux-source-$kernel_version"
		echo "if the above doesn't work because some distros don't use LTS Kernel, download the linux-source-$kernel_version .deb file"
		echo "using Archive Manager, Open data.tar.zst, extract /usr/src/linux-source-$kernel_version/linux-source-$kernel_version.tar.bz2"
		echo "NOTE - This does not work for HWE kernels"

		exit 1

	fi

	tar --strip-components=3 -xvf /usr/src/linux-source-$kernel_version.tar.bz2 --directory="$build_dir" linux-source-$kernel_version/sound/pci/hda

else
	# here we assume the distribution kernel source is essentially the mainline kernel source

	set +e

	. "$(dirname "$0")/lib/verify_kernel_tarball.sh"

	# a cached tarball is only reused if it verifies; a bad one is deleted so wget -c cannot resume it
	[[ -f $build_dir/linux-$kernel_version.tar.xz ]] && { verify_kernel_tarball $build_dir/linux-$kernel_version.tar.xz $kernel_version || true; }

	# attempt to download linux-x.x.x.tar.xz kernel
	wget -c https://cdn.kernel.org/pub/linux/kernel/v$major_version.x/linux-$kernel_version.tar.xz -P "$build_dir"
	rc=$?

	if [[ $rc -eq 0 ]]; then
		verify_kernel_tarball $build_dir/linux-$kernel_version.tar.xz $kernel_version || exit 1
	else
		echo "Failed to download linux-$kernel_version.tar.xz"
		echo "Trying to download base kernel version linux-$major_version.$minor_version.tar.xz"
		echo "This may lead to build failures as too old"
		echo "If this is an Ubuntu-based distribution this almost certainly will fail to build"
		echo ""
   		# if first attempt fails, attempt to download linux-x.x.tar.xz kernel
   		kernel_version=$major_version.$minor_version
   		[[ -f $build_dir/linux-$kernel_version.tar.xz ]] && { verify_kernel_tarball $build_dir/linux-$kernel_version.tar.xz $kernel_version || true; }
   		wget -c https://cdn.kernel.org/pub/linux/kernel/v$major_version.x/linux-$kernel_version.tar.xz -P "$build_dir"
		rc=$?

		[[ $rc -ne 0 ]] && echo "kernel could not be downloaded...exiting" >&2 && exit 1
		verify_kernel_tarball $build_dir/linux-$kernel_version.tar.xz $kernel_version || exit 1
	fi

	set -e

	tar --strip-components=3 -xvf "$build_dir"/linux-$kernel_version.tar.xz --directory="$build_dir" linux-$kernel_version/sound/pci/hda

fi

mv $hda_dir/Makefile $hda_dir/Makefile.orig
cp $patch_dir/Makefile $patch_dir/patch_cirrus_* $hda_dir
pushd $hda_dir > /dev/null
# 1 is the implemented version (or newer than the oldest Ubuntu revision that
# works), 2 is later than the newest, -1 is older than the oldest
# for ubuntu allow a range of revisions that work
iscurrent=-1
if [ $isubuntu -ge 1 ]; then
	ubuntu_version=$major_version.$minor_version.$revpart2
	if version_lt 5.15.71 "$ubuntu_version"; then
		iscurrent=2
	elif ! version_lt "$ubuntu_version" 5.15.47; then
		iscurrent=1
	fi
else
	if version_lt 5.19 "$major_version.$minor_version"; then
		iscurrent=2
	elif ! version_lt "$major_version.$minor_version" 5.19; then
		iscurrent=1
	fi
fi

if [ $iscurrent -gt 1 ]; then
	echo "Kernel version later than implemented version - there may be build problems"
fi

if [ $major_version -eq 5 -a $minor_version -lt 13 ]; then
	patch -b -p2 <../../patch_patch_cirrus.c.diff
else
	if [ $isubuntu -ge 1 ]; then

		patch -b -p2 <../../patch_patch_cs8409.c.diff

		if [ $iscurrent -ge 0 ]; then
			patch -b -p2 <../../patch_patch_cs8409.h.diff
		else
			patch -b -p2 <../../patches/patch_patch_cs8409.h.ubuntu.pre51547.diff
		fi

		if [ $iscurrent -ge 0 ]; then
			patch -b -p2 <../../patch_patch_cirrus_apple.h.diff
		fi

	else
		patch -b -p2 <../../patch_patch_cs8409.c.diff

		if [ $iscurrent -ge 0 ]; then
			patch -b -p2 <../../patch_patch_cs8409.h.diff
		else
			patch -b -p2 <../../patches/patch_patch_cs8409.h.main.pre519.diff
		fi

		cp $patch_dir/Makefile $patch_dir/patch_cirrus_* $hda_dir/

		if [ $iscurrent -ge 0 ]; then
			patch -b -p2 <../../patch_patch_cirrus_apple.h.diff
		fi

	fi
fi

popd > /dev/null

[[ ! $dkms_action == 'install' ]] && [[ ! -d $update_dir ]] && mkdir $update_dir

#echo "DKMS VAR IS ${dkms}"

# Skipping patch installation since dkms will do it
if [[ ! $dkms = true ]]; then

	echo "DKMS FALSE DONE"

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
		make -C "$repo_dir" KERNELRELEASE=$UNAME || rc=$?
		check_module_built
		make -C "$repo_dir" install KERNELRELEASE=$UNAME || rc=$?

	fi
	if [[ $rc -ne 0 ]]; then
		echo "make failed (exit $rc)" >&2
	fi
	echo -e "\ncontents of $update_dir"
	ls -lA $update_dir || true
	exit "$rc"
fi
