
Which installer to run and which kernels are supported (6.17 and later vs below 6.17) is documented in README.md.

NOTE that the headphone plugin/unplug events use unsolicited responses which under linux seem to be executed concurrently
with other commands.
I have implemented a blocking system to ensure the response verb blocks are done serially (which seems to be how OSX does this).
I do not know enough about the internals of the linux kernel module to know if there are better ways of doing this.
As these verb blocks last multiseconds using simple linux kernel mutex locks (as done in other parts of the sound module
for single commands) dont seem to be the right approach but I could be wrong.
There are still issues with concurrency to be handled eg if you plugin and quickly start something playing - the play setup
verbs still need to be delayed while the plugin block finishes.
Currently I just physically wait a few seconds after eg plugging in before starting to play.
Plugging while playing and then unplugging while playing is known to work.

Input nodes (internal mike, external mike, linein) now setup as per OSX ie using OSX format.
NOT linked to any actual input streams.
SPDIF not implemented.

Power down/sleep completely unknown and untested.



Comments on what OSX seems to be doing.

The 8409 seems to be acting as a simple digital transformation system for speaker sound.
The incoming bit stream is converted to a TDM digital stream and sent to the amplifiers which
do the actual digital analogue conversion.
No processing is done by the 8409 - no parameters are set on the hda output nodes except that
the output node pins (0x24, 0x25) are set to output.
(The node chain is 0x02 -> 0x24, 0x03 -> 0x25 with 0x02 1st 2 channels, 0x03 2nd 2 channels).
All I2C programming and TDM setup is done via the vendor node 0x47 using coef index/coef proc writes/reads.
The MAX98706 amp programming is consistent with the MAX98372 documentation.
It appears the amps programming is fixed so eg gain control is not done on the amps either.

So I think Apple performs all input processing (conversion, volume etc) at higher CoreAudio levels
which ends up as 44.1 kHz, 24 bit 4 channel audio which is output by the 8409 with no additional processing.


Issues:

Because Apple's format is fixed at 44.1 kHz, 24 bit (S24_3LE) 4 channel and the format is set by undocumented vendor node
commands its not clear if other formats can be supported in the 8409 itself.
It appears now that Apples set up can take eg S24_LE format and S32_LE format, and these are the formats the driver
exposes (see README.md).



Where the Apple code is spliced into cs8409.c (HDA-39):

The hooks (patch_cs8409.c.diff, patch_patch_cs8409.c.diff) forward-declare cs8409_apple() / patch_cs8409_apple()
just above the kernel's probe function, call it from the probe path, and `#include` the Apple header after
`module_hda_codec_driver()` - the last of the kernel's own definitions - instead of mid-file.  This is feasible
because the header only needs symbols defined before that point (cs8409_probe, cs8409_remove, the hda_codec_ops
types); it defines nothing the kernel's remaining lines use.  The include is deliberately NOT at the literal end
of the file: 7.x kernels add a MODULE_IMPORT_NS() line after MODULE_DESCRIPTION, and a hunk anchored at end of
file then applies with fuzz or fails.  The patch tests prove the hooks apply cleanly; compiling the patched file
against kernel headers is not done in the test suite and needs hardware validation before merge.


Open items (not done, deliberately):

HDA-26 - jack_present is a single tri-state (0 absent, 1 present, 2 unknown) shared by the headphone and
line-in paths, so the two jacks cannot be told apart.  The planned fix, two booleans (headphone_present /
linein_present), was NOT made.  `jack_present` is declared in patch_cs8409.h.diff, patch_patch_cs8409.h.diff and
patches/patch_patch_cs8409.h.{main.pre519,ubuntu.pre51547}.diff, read in patch_cirrus_new84.h (PCM hooks) and
cirrus_apple.h / patch_cirrus_apple.h (pin sense), and written in patch_cirrus_real84.h, which is where the
value 2 comes from.  Replacing it touches all of those and changes register-adjacent behaviour that cannot be
verified without an iMac, so it needs hardware testing and its own plan (with all five declarations changed
together).  Do it only if hardware testing shows a real jack-detection fault.

HDA-21 - cs_8409_vendor_coef_set_mask() ORs `coef` in unmasked, `(retval & ~mask) | coef`.  Six calls in
patch_cirrus_real84.h depend on it, three with mask 0 whose only effect is that OR.  The conventional
`| (coef & mask)` form was not applied for the same reason; tests/test_driver_coef_mask.sh pins the current
behaviour.

CI warning cleanup - unused-symbol warnings in patch_cirrus_real84.h (18 unused-function, 21 unused-variable per
pinned kernel) and patch_cirrus_real84_i2c.h (11 and 4) are still in tests/ci/build-warning-baseline.*.txt.  Stories
CI-WARN-REAL84 and CI-WARN-REAL84-I2C are parked, for two reasons.  (1) tests/test_spdx_batch3.sh check C9 diffs both
headers against the commit before that test was added and requires exactly one added line (the SPDX comment), so any
later edit to either file fails the suite; C9 must be changed to compare against the commit that added the SPDX line
before these files can be cleaned.  (2) The agents run on macOS and cannot build cs8409.o to measure before/after
counts, and the edits are deletions in a driver that cannot be tested on hardware here.  The ratchet still blocks any
increase.  Redo them when C9 is fixed and a Linux build environment is available, lowering the baselines to the
measured counts.

Hardware validation: nothing in the cleanup (HDA-20 unsolicited-event lock, HDA-39 include move, the real84.h and
installer changes) or the Linux 7.0 work has been run on an iMac.  The cs8409 patches apply to Linux 6.17,
7.0, 7.1 and 7.2, and the module has been built against 7.0 on x86-64; audio, jack events and suspend/resume are
unverified.

Hardware result, 2026-10-10: the driver, built from the linux-7.0.14 mainline sound/hda sources, was installed on
an iMac18,2 (i5-7400) running Ubuntu 7.0.0-38-generic (upstream 7.0.14) and sound output works: the built-in speakers
and the headphone output both play (re-verified after pulling master and rerunning the unmodified installer).
The microphone did not work; whether it worked under macOS is unknown.  NOT checked: headset-mic/jack-event
behaviour, suspend/resume.  The caveats above still apply to those.

The failure that preceded it: a module built from base linux-7.0 sources oopsed at probe (UBSAN
array-index-out-of-bounds in generic.c fill_input_pin_labels, then a general protection fault in strcmp).
Cause: upstream v7.0.10 added share_spdif_kctl to struct hda_multi_out in hda_local.h, which shifts hda_gen_spec
by 8 bytes, so a module built from older sources reads the wrong offsets.  The installer now picks the point
release from /proc/version_signature.  Proof: a throwaway module printing sizeof(struct hda_gen_spec) gave 6000
against the kernel's 6008 (pahole on /sys/kernel/btf/snd_hda_codec_generic).
