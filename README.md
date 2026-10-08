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
git clone https://github.com/davidjo/snd_hda_macbookpro.git
cd snd_hda_macbookpro/
#run the following command as root or with sudo
./install.cirrus.driver.sh
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
# delete the ko file
sudo rm /lib/modules/{kernel version}/updates/snd-hda-codec-cs8409.ko*
sudo depmod -a
```

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

The cs8409 patches apply to mainline 6.17, 7.0, 7.1 and 7.2; on 7.0 the header
patch applies with fuzz.

**Limits**

* `make test` runs the bash tests only. They do not run on real iMac hardware
  and need no kernel headers.
* I have not verified audio on the iMac 2017 on any 7.x kernel. A successful
  build says nothing about whether sound works.

Dynamic Kernel Module Support (dkms):
-------------

dkms is a framework which allows kernel modules to be dynamically built for each kernel on your system.
See here for more details: https://github.com/dell/dkms
You will need to first install dkms on your system

**install driver via dkms**
```
sudo ./install.cirrus.driver.sh -i
```

**remove driver from dkms**
```
sudo ./install.cirrus.driver.sh -r
```

