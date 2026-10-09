#!/bin/bash

src_dir='/usr/src/snd_hda_macbookpro-0.1'
module_name='snd-hda-codec-cs8409'
dkms_name='snd_hda_macbookpro/0.1'
var_dkms_dir='/var/lib/dkms/snd_hda_macbookpro'
cur_dir=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)

usage() {
    echo "usage: $0 [-r | -u] [-k KERNEL_RELEASE]" >&2
    echo "  -r  remove the dkms module (restores the original kernel module)" >&2
    echo "  -u  same as -r" >&2
    echo "  -k  kernel release to remove it from (default: uname -r); only with -r/-u" >&2
    echo "  no option: install the dkms module" >&2
    exit 2
}

kernel=""

# specify uninstall with the -r or -u argument
while getopts :ruk: arg
do
    case "${arg}" in
        r) dkms_remove=true;;
        u) dkms_remove=true;;
        k) kernel=$OPTARG;;
        \?|:) usage;;
    esac
done
shift $((OPTIND-1))
[[ $# -eq 0 ]] || usage

if [[ $dkms_remove = true ]]; then

    # we need this to ensure the original kernel module is restored
    # before we remove the whole /var/lib/dkms/snd_hda_macbookpro directory tree below
    # (which we dont need to do if we do the dkms remove)
    # remove only the kernel the installer targets; --all would also strip
    # the module from every other kernel that has it built
    dkms remove "$dkms_name" -k "${kernel:-$(uname -r)}"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "dkms remove failed for $dkms_name (exit $rc)" >&2
        exit "$rc"
    fi

    # we dont need this if we do the above - the whole dkms module tree is removed by the above command
    # (in addition to restoring the original module)
    #[[ -e $var_dkms_dir ]] && rm -rf $var_dkms_dir && echo "removed $var_dkms_dir"

    # we do need to remove the symbolic link created manually below
    [[ -e $src_dir ]] && rm -f "$src_dir" && echo "removed $src_dir"

    exit 0
fi

pushd "$cur_dir" > /dev/null
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "cannot enter $cur_dir (exit $rc)" >&2
    exit "$rc"
fi

# create the symbolic link for source dkms seems to require
[[ ! -e $src_dir ]] && ln -sfn "$cur_dir" "$src_dir"

# note that this will store the original base kernel module under  /var/lib/dkms
# and needs dkms remove to be called to restore that original module back to the base kernel modules
dkms install -c dkms.conf --force -m "$dkms_name"
rc=$?

popd > /dev/null

if [[ $rc -ne 0 ]]; then
    echo "dkms install failed for $dkms_name (exit $rc)" >&2
fi

exit "$rc"
