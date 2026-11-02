BOARD ?= pi4
BOARDS := pi4 pi5

.PHONY: help image images vm test-plugin test-image test release clean

help:
	@echo "make image BOARD=pi4|pi5   build out/opnsense-<board>.img.xz"
	@echo "make images                build both boards"
	@echo "make vm BOARD=pi5|pi4      boot the Pi-shaped test VM (console in this terminal)"
	@echo "make test-plugin BOARD=..  VM test: boot, install os-realtek-re, reboot, check if_re"
	@echo "make test-image BOARD=..   VM test: boot the built image to the web GUI"
	@echo "make test                  all VM tests for both boards"
	@echo "make release TAG=26.7-1    upload out/* to a GitHub release (needs gh)"

image:
	scripts/build-image.sh $(BOARD)

images:
	@for b in $(BOARDS); do scripts/build-image.sh $$b || exit 1; done

vm:
	vm/run.sh --$(BOARD)

test-plugin:
	vm/test.sh plugin $(BOARD)

test-image:
	vm/test.sh image $(BOARD)

test:
	@for b in $(BOARDS); do vm/test.sh plugin $$b && vm/test.sh image $$b || exit 1; done

release:
	@test -n "$(TAG)" || { echo "TAG=... required" >&2; exit 2; }
	gh release create "$(TAG)" out/*.img.xz out/*.sha256 --title "OPNsense Pi $(TAG)" --notes-file RELEASE_NOTES.md

clean:
	rm -rf out .work/vm .work/build-*
