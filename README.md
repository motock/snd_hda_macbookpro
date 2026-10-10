# snd_hda_macbookpro

This is a kernel driver for sound on Macs with Cirrus 8409 HDA chips.
Sound output is now reasonably complete and integrated with Linux.
Sound input still needs work.


It will play audio through Internal speakers or headphones.

The primary audio should be set to Analogue Stereo Output in the Settings Audio dialog. Alternatively, if you want to use the internal microphone, set it to Analogue Stereo Duplex.

Sound recording from internal mike and headset mike is not yet fully interfaced with Linux user side.

The recorded sound level is very low but this is the sound level as returned in OSX.
Amplification will be required eg using something like PulseEffects.


The hardware device sound format is limited to 2/4 channel 44.1 kHz S24_LE S32_LE.
As long as use the default device volume control, other formats, frequencies work.


NOTA BENE: The direct hardware device (hw:0,0) and plughw:0,0 device have NO volume control so will be VERY loud!


Currently this works with MAX98706, SSM3515 and TAS5764L amplifiers.
It will NOT work with other amplifiers as each amplifier requires specific programming.


Power down/sleep completely unknown and untested.
At the moment everything is permanently powered on.


The Apple speaker setup is 4 speakers as a left tweeter, left woofer, right tweeter and right woofer
so this is actually a classic HiFi stereo (ie 2 channel) speaker system.
(These names are listed in the layout files under AppleHDA.kext/Contents/Resources).

The channel order for Linux has been modified to left tweeter, right tweeter and left woofer, right woofer
as this fits in with the Linux way much better.

The driver also has been modified to duplicate a stereo sound source onto the second stereo channel so all
speakers are driven (this essentially replicates the snd_hda_multi_out_analog_prepare function).

This will not sound the same as Apple (which is known to be using specific digital filter effects in CoreAudio).

To create a more Apple-like sound requires creating eg an Alsa pseudo device to channel duplicate a stereo sound
and apply different digital filters to the tweeter and woofer channels.


NOTE. My primary testing kernel is now Ubuntu LTS 24.04 6.8.


NOTA BENE. As of linux kernel 6.17 the sound kernel source directory has been completely re-organized.
           The installation script now works for 6.17 kernel versions (and later when they arrive).
           The old installation script is now called install.cirrus.driver.pre617.sh.
           The new version of the install.cirrus.driver.sh script will detect your kernel version and exec
           the old installation script as needed.
           For older kernel version you can just run the old installation script directly
           ie install.cirrus.driver.pre617.sh.
           Use install.cirrus.driver.sh for kernels 6.17 and later (including 7.x) and
           install.cirrus.driver.pre617.sh for kernels below 6.17. The old script refuses a
           kernel 6.17 or later and tells you to use install.cirrus.driver.sh; both honour -k.
           Note that for kernel version 6.17 new files and directories have been added to the repo
           rather than attempting to update the pre 6.17 versions (as the kernel source changes also
           involved name changes and the new files are more consistent with the new kernel names).


The following installation setup provided by leifliddy.



Compiling and installing driver:
-------------

**fedora package install**
```
dnf install gcc kernel-devel make patch wget
```
**ubuntu package install**  
```
apt install gcc linux-headers-generic make patch wget
```
On Ubuntu and Ubuntu-based distributions (Linux Mint, Pop!_OS) the installers look for the
distribution kernel source package, `/usr/src/linux-source-<version>.tar.bz2`, where `<version>` is
the kernel's `x.y.z` (for example `6.8.0`), so also run `sudo apt install linux-source-<version>`.
What happens without it depends on the installer:

* `install.cirrus.driver.sh` (kernel 6.17 and later) falls back to downloading the verified mainline
  tarball from cdn.kernel.org: the upstream point release reported by `/proc/version_signature`
  (for example `7.0.14`) when it matches the running kernel, and the base `x.y` release only
  otherwise (with a warning, since its struct layouts may differ and the module may oops at load). The package is optional but preferred, since it carries
  Ubuntu's backports (see the kernel 7.0 section below).
* `install.cirrus.driver.pre617.sh` (kernels below 6.17) does not download on Ubuntu; it stops and
  tells you to install `linux-source-<version>`. The package is required.

Fedora, Arch and Void have no such package; the installers always download the mainline tarball.
**arch package install**
```
pacman -S gcc linux-headers make patch wget
```
**void package install**
```
xbps-install -S gcc make linux-headers patch wget
```

**build driver**  
```
git clone https://github.com/motock/snd_hda_macbookpro.git
cd snd_hda_macbookpro/
#the installer writes to /lib/modules, so it must run as root
sudo ./install.cirrus.driver.sh
reboot
```

When the installer has to download the kernel source, it verifies the tarball's
SHA-256 against kernel.org's `sha256sums.asc` before extracting it. A mismatch
aborts the install with a non-zero status and deletes the tarball; a missing,
ambiguous or unreachable checksum also aborts with a non-zero status but leaves
the tarball in place. There is no option to skip this check.

**building for a specific kernel (KERNELDIR / KERNELRELEASE)**

The top level `Makefile` builds and installs for the running kernel by default.
To build for another kernel, pass one of these variables to `make`:

```
# build/install for the kernel named by its release (recommended)
sudo make install KERNELRELEASE=6.8.0-45-generic

# or point at the kernel's modules directory directly
sudo make install KERNELDIR=/lib/modules/6.8.0-45-generic
```

`KERNELRELEASE` selects `/lib/modules/$(KERNELRELEASE)` and wins if both are
given.  If only `KERNELDIR` is overridden, the release is taken from the last
component of that path, so `KERNELDIR=/lib/modules/6.8.0-45-generic` behaves
like `KERNELRELEASE=6.8.0-45-generic`.  With neither set, the running kernel
(`uname -r`) is used.

`make install` runs `depmod -a` against the kernel it built for, so the module
dependency metadata lands in the right `/lib/modules/<release>` tree.  With
neither variable set it keeps the historical bare `depmod -a` (current kernel).

**Deleting driver**
```
# Check your kernel version
uname -a
# delete the ko file; the module may be compressed (.ko.zst, .ko.xz or .ko.gz)
# installed with install.cirrus.driver.sh (kernel 6.17 and later):
sudo rm /lib/modules/{kernel version}/updates/codecs/cirrus/snd-hda-codec-cs8409.ko
# installed with install.cirrus.driver.pre617.sh (kernels below 6.17):
sudo rm /lib/modules/{kernel version}/updates/snd-hda-codec-cs8409.ko
sudo depmod -a {kernel version}
```
If you installed through dkms, do not delete the file by hand; see "remove driver from dkms" below.

Linux Mint and Ubuntu on kernel 7.0:
-------------

**Build-tested** on Linux 7.0, x86-64:

* Ubuntu 24.04 / Linux Mint 22.3 with `linux-headers-7.0.0-38-generic` (HWE kernel)
* Ubuntu 26.04 / Linux Mint 23 with `linux-source-7.0.0`

"Build-tested" means `snd-hda-codec-cs8409.ko` built, its vermagic was
`7.0.0-38-generic`, and it had no unresolved symbols.

On Ubuntu and Mint the installer prefers the distribution's
`/usr/src/linux-source-<version>.tar.bz2` when that package is installed. HWE
kernels usually have no such package. When the file is absent the installer
prints

```
linux-source-<version> not found; using mainline kernel <major>.<minor> sources from cdn.kernel.org instead
(to use the Ubuntu kernel sources instead: sudo apt install linux-source-<version>)
```

then downloads the mainline `<major>.<minor>` release (for example
`linux-7.0.tar.xz`) from cdn.kernel.org and verifies its SHA-256 as described
above. This needs network access and the kernel headers package for the running
kernel (`linux-headers-<release>`). The mainline sources lack Ubuntu's
backports, so the build can fail on some kernels.

The cs8409 patches apply to mainline 6.17, 7.0 and 7.1; on 7.0 the header
patch applies with fuzz.

**Limits**

* `make test` runs the bash tests only. They do not run on real iMac hardware
  and need no kernel headers.
* I have not verified audio on the iMac 2017 on any 7.x kernel. A successful
  build says nothing about whether sound works.

CI
-------------

[![tests](https://github.com/motock/snd_hda_macbookpro/actions/workflows/tests.yml/badge.svg?branch=master)](https://github.com/motock/snd_hda_macbookpro/actions/workflows/tests.yml)
[![build](https://github.com/motock/snd_hda_macbookpro/actions/workflows/build.yml/badge.svg?branch=master)](https://github.com/motock/snd_hda_macbookpro/actions/workflows/build.yml)

Both workflows (`.github/workflows/`) run on every pull request and on pushes to `master`.

**What runs**

* `tests.yml` installs a pinned ShellCheck and runs the whole suite (`bash tests/run.sh`), then
  `tests/ci/gate.sh` over its output. The gate fails the job on any `FAIL`, on any `XPASS`, and on
  any `SKIP` of a test not listed in `tests/ci/allowed-skips.list` (empty by default: CI has the
  toolchain and network, so a skip is a regression). A missing or empty run output also fails.
* `build.yml` compiles `cs8409.o` with `lib/ci_build_check.sh` against the pinned kernels, one
  matrix leg each: `new` (6.17.13) and `7x` (7.1.13). A compiler error fails the leg, and so does any
  change in the warning counts (see **Warning ratchet**).
  The `build-ok` job is the single check to require for branch protection.

**Required checks**

As of master `a8bf1d1`, both workflows conclude `success`, including every matrix leg
([tests run](https://github.com/motock/snd_hda_macbookpro/actions/runs/38022171084),
[build run](https://github.com/motock/snd_hda_macbookpro/actions/runs/38022171147)).
They are ready to be made required checks. Configure exactly these names, as GitHub reports them:

* `tests`
* `build-ok`

Do not require the matrix legs `build (new)` and `build (7x)` separately: `build-ok` fails if either
leg fails, so it covers both and survives adding or renaming a pin.

The warning-count baselines are `tests/ci/build-warning-baseline.new.txt` (6.17.13) and
`tests/ci/build-warning-baseline.7x.txt` (7.1.13); to lower them, see **Warning ratchet** below.

Out of scope: the pre-6.17 installer path (`install.cirrus.driver.pre617.sh`), kernels other than
the pins, and anything that needs real hardware. A green build or test run says nothing about
whether audio works.

**Run the same checks locally**

```
bash tests/run.sh | tee run.out; bash tests/ci/gate.sh run.out
```

Needs bash, GNU patch, xz, gcc, curl and a SHA-256 tool; ShellCheck 0.11.0 for the static-analysis
tests (without it the baseline comparison is skipped with a note, so a clean local run does not
prove the ShellCheck step passes in CI). The suite downloads and
SHA-256-verifies the pinned kernel tarballs on first use; set `HDA_TEST_CACHE` to choose where
they are cached.

```
lib/ci_build_check.sh new     # 6.17.13
lib/ci_build_check.sh 7x      # 7.1.13
```

These need a Linux host (the kernel build requires GNU Make 4.0 or newer; macOS's make 3.81 fails at
`defconfig`) with `build-essential flex bison bc libelf-dev libssl-dev` (Ubuntu names), `xz-utils`,
`patch`, `curl` and `python3`, and take a few minutes. Exit status 0 means `cs8409.o` compiled with
no errors and the warning counts equal the baseline; 1 is a build or verification failure; 2 is a bad invocation.

**Warning ratchet**

The build leg counts compiler warnings per file and warning kind and compares them with
`tests/ci/build-warning-baseline.<pin>.txt` (`<file> <kind> <count>`, sorted). A new, increased or
unknown-kind warning fails; so does a *lower* count, so a fix cannot be silently lost. To lower the
baseline after fixing warnings, run the build with `CI_BUILD_WARNINGS_UPDATE=1`, or edit the lines by
hand, and commit the diff. A missing, empty or malformed baseline fails. The measured total is
printed next to the baseline total in the build log.

**Bump a kernel pin**

Edit `tests/kernel-pins.conf`: set `PIN_<NAME>_VERSION`, `PIN_<NAME>_TARBALL` and
`PIN_<NAME>_SHA256`. Copy the SHA-256 from the signed `sha256sums.asc` in the matching directory of
https://cdn.kernel.org/pub/linux/kernel/ (`v6.x` for 6.x, `v7.x` for 7.x), not from a tarball you
downloaded. The tarball cache key in both workflows hashes that file, so changing it invalidates
the cache automatically. Update the version numbers quoted in this section. If you add a pin, also
add its name to `matrix.pin` in `build.yml` and teach `lib/ci_build_check.sh` and
`tests/lib/kernel_cache.sh` to resolve it.

**Bump ShellCheck**

The version and SHA-256 are the `SHELLCHECK_VERSION` and `SHELLCHECK_SHA256` entries in the `env:`
block of `.github/workflows/tests.yml`. The release publishes no checksum file, so download the
`shellcheck-v<version>.linux.x86_64.tar.xz` asset and compute `sha256sum` yourself (it should match
the digest GitHub shows for the asset). Then run the suite with the new version: new findings must
be fixed, not added to the baseline.

`tests/shellcheck-baseline.txt` lists accepted findings and is a ratchet: it may only shrink.
`tests/test_shell_static.sh` fails on a finding that is not listed and on a listed entry that no
longer fires, so the change that fixes a finding must delete its line.

Dynamic Kernel Module Support (dkms):
-------------

dkms is a framework which allows kernel modules to be dynamically built for each kernel on your system.
See here for more details: https://github.com/dell/dkms
You will need to first install dkms on your system

**install driver via dkms**
```
sudo ./install.cirrus.driver.sh -i
```

**installer options**

`install.cirrus.driver.sh` and `install.cirrus.driver.pre617.sh` accept:

| Flag | Meaning |
|---|---|
| `-i`, `--install` | install via dkms (with `-d`/dkms.conf) |
| `-r`, `--remove` / `-u`, `--uninstall` | remove the driver (the two are aliases) |
| `-k`, `--kernel RELEASE` | kernel release to target (default: the positional `RELEASE`, else `uname -r`) |
| `-d`, `--dkms` | internal, set by `dkms.conf` `PRE_BUILD` |

`dkms.sh` accepts `-r`/`-u` (remove) and `-k RELEASE` (kernel to remove from, default `uname -r`).

An unknown option, an option missing its argument (`-k` alone) or more than one positional
argument prints a `usage:` line to stderr and exits with status **2**. Status 1 still means the
install or removal itself failed.

**remove driver from dkms**
```
sudo ./install.cirrus.driver.sh -r
```
This runs `dkms remove snd_hda_macbookpro/0.1 -k {kernel version}` (the name and version from `dkms.conf`),
which also restores any base kernel module dkms archived. Only the targeted kernel (`-k`, else the
positional release, else `uname -r`) is removed; other kernels keep their dkms build. The dkms module lives in
`/lib/modules/{kernel version}/updates/dkms/`. Afterwards run `sudo depmod -a`.

