# Out-of-tree build of the stage 2 probe module against the M3 kernel build
# folder. Output goes to this folder only. Override KSRC and KOUT if needed.
KSRC ?= $(HOME)/m3gpu/src/linux
KOUT ?= $(HOME)/m3gpu/build-linux

all:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(CURDIR) clean
