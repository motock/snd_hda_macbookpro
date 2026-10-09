# debug build flags
#KBUILD_EXTRA_CFLAGS = "-DCONFIG_SND_DEBUG=1 -DMYSOUNDDEBUGFULL -DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS -DCONFIG_SND_HDA_RECONFIG=1"
# normal build flags
KBUILD_EXTRA_CFLAGS = "-DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS -DCONFIG_SND_HDA_RECONFIG=1"
# internal mike only build flags
#KBUILD_EXTRA_CFLAGS = "-DINTERNAL_MIKE_ONLY -DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS -DCONFIG_SND_HDA_RECONFIG=1"


ifdef KERNELRELEASE
	KERNELDIR := /lib/modules/$(KERNELRELEASE)
else
	KERNELDIR := /lib/modules/$(shell uname -r)
endif

KERNELBUILD := $(KERNELDIR)/build

# depmod must index the kernel the module was actually built for.  A bare
# `depmod -a` writes dependency metadata into /lib/modules/$(uname -r), so a
# module built for another kernel (KERNELRELEASE=... or a KERNELDIR=... override)
# is not found until the next boot.  One rule, in priority order:
#   1. KERNELRELEASE given -> use it verbatim (it is the explicit answer).
#   2. KERNELRELEASE empty but KERNELDIR overridden by the caller (command line,
#      environment or override) -> the release is the last path component of
#      that directory, $(notdir $(KERNELDIR)), exactly how KERNELDIR itself is
#      derived from KERNELRELEASE above.
#   3. neither -> keep the historical bare `depmod -a` (current kernel), so the
#      default install is unchanged and no empty argument is ever passed.
ifneq ($(strip $(KERNELRELEASE)),)
DEPMOD_ARGS := $(KERNELRELEASE)
else ifneq ($(filter command line environment override,$(origin KERNELDIR)),)
DEPMOD_ARGS := $(notdir $(KERNELDIR))
endif

all:
	make -C $(KERNELBUILD) CFLAGS_MODULE=$(KBUILD_EXTRA_CFLAGS) M=$(shell pwd)/build/hda modules

clean:
	make -C $(KERNELBUILD) M=$(shell pwd)/build/hda clean

install:
	make INSTALL_MOD_DIR=updates -C $(KERNELBUILD) M=$(shell pwd)/build/hda CONFIG_MODULE_SIG_ALL=n modules_install
ifeq ($(DEPMOD_ARGS),)
	depmod -a
else
	depmod -a $(DEPMOD_ARGS)
endif

test:
	bash tests/run.sh

.PHONY: clean test
