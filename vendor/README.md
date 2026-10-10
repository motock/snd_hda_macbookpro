# vendor/

Pre-extracted kernel sources for building the cs8409 driver without
downloading a ~140 MB kernel tarball.

## What is vendored

For each snapshot `vendor/linux-<version>/`, the files under `sound/hda/`
that the cs8409 build needs: the include closure (`#include "..."`,
resolved inside `sound/hda`) of `codecs/cirrus/cs8409.c`, `cs8409.h` and
`cs8409-tables.c`. That is about 140 KB per version. Paths are the same as
in the kernel tree.

| Snapshot | Used for |
|---|---|
| `linux-6.17.13` | 6.17.0 – 6.17.13 |
| `linux-7.0` | 7.0.0 – 7.0.9 |
| `linux-7.0.14` | 7.0.10 – 7.0.14 |
| `linux-7.1.13` | 7.1.0 – 7.1.13 |

Each snapshot has a `MANIFEST`: the tarball name, the tarball's SHA-256
(verified against kernel.org's `sha256sums.asc`), the layout hash, and the
SHA-256 of every file.

## Licence

The files are unmodified Linux kernel source, licensed GPL-2.0. Each keeps
its own SPDX header and copyright notice. Nothing here is edited by hand;
re-create a snapshot with the tool below instead.

## Layout hash and LAYOUT-TABLE

`tools/layout-hash.sh <sound/hda-root>` prints one SHA-256 over the `.h`
files of the include closure (sorted by path; path and content both
hashed). Two kernels with the same hash have the same struct layouts as far
as this driver is concerned, so one snapshot can stand in for both.

`vendor/LAYOUT-TABLE` has one line per range:

    <first-version> <last-version> <snapshot-dir-name> <layout-hash>

`#` starts a comment. Ranges are inclusive, stay within one series, and do
not overlap. A version is covered only if some range includes it exactly:
`7.0.9` and `7.0.10` are in different ranges because 7.0.10 changed
`struct hda_multi_out`.

The installer (a later change) must use a snapshot only when the table has a
range covering the exact point release being built. Otherwise it keeps
downloading the matching tarball.

## Adding a version

```sh
tools/vendor-kernel-sources.sh 7.1.14            # writes vendor/linux-7.1.14/
tools/layout-hash.sh vendor/linux-7.1.14/sound/hda
```

If the hash equals the range it extends, raise that range's `<last-version>`
and delete the new snapshot (or keep the old one). If it differs, add a new
range with the new snapshot. `HDA_KERNEL_MIRROR` overrides the download
directory and `HDA_VENDOR_CACHE` the tarball cache. `bash tests/run.sh`
checks that the manifests, table and snapshots agree.

To check a release without downloading its tarball, fetch the closure files
from `https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/<path>?h=v<version>`
into a `sound/hda` tree and run `tools/layout-hash.sh` on it.
