BOARD ?= pi4
BOARDS := pi4 pi5

.PHONY: help image images raw customize compress vm test-plugin test-image test-trial test release clean

help:
	@echo "make image BOARD=pi4|pi5   build out/opnsense-<board>.img.xz without the bundled drivers"
	@echo "make images                build both boards (without the bundled drivers)"
	@echo "make raw BOARD=..          build out/opnsense-<board>.img (raw, for customize)"
	@echo "make customize BOARD=..    add the bundled drivers to out/*.img (FreeBSD 15.1 aarch64, root)"
	@echo "make compress BOARD=..     out/opnsense-<board>.img -> .img.xz + .sha256"
	@echo "make vm BOARD=pi5|pi4      boot the Pi-shaped test VM (console in this terminal)"
	@echo "make test-plugin BOARD=..  VM test: boot, install os-realtek-re, reboot, check if_re"
	@echo "make test-image BOARD=..   VM test: boot the built image; seed, plugin and driver checks"
	@echo "make test-trial BOARD=..   VM test: reboot-after-minutes reboots the image by itself"
	@echo "make test                  all VM tests for both boards"
	@echo "make release TAG=26.7-1    upload out/* to a GitHub release (needs gh)"

image:
	scripts/build-image.sh $(BOARD)
	scripts/compress.sh $(BOARD)

images:
	@for b in $(BOARDS); do scripts/build-image.sh $$b && scripts/compress.sh $$b || exit 1; done

raw:
	scripts/build-image.sh $(BOARD)

customize:
	sh scripts/customize.sh $(BOARD) out/opnsense-$(BOARD).img

compress:
	scripts/compress.sh $(BOARD)

vm:
	vm/run.sh --$(BOARD)

test-plugin:
	vm/test.sh plugin $(BOARD)

test-image:
	vm/test.sh image $(BOARD)

test-trial:
	vm/test.sh trial $(BOARD)

test:
	@for b in $(BOARDS); do vm/test.sh plugin $$b && vm/test.sh image $$b || exit 1; done

release:
	@test -n "$(TAG)" || { echo "TAG=... required" >&2; exit 2; }
	gh release create "$(TAG)" out/*.img.xz out/*.sha256 $(wildcard out/*.manifest.txt out/*.config.xml) --title "OPNsense Pi $(TAG)" --notes-file RELEASE_NOTES.md

clean:
	rm -rf out .work/vm .work/build-*
