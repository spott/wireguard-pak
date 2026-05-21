PAK_NAME := $(shell jq -r .name pak.json)

ARCHITECTURES := arm arm64
PLATFORMS := tg5040

MINUI_LIST_VERSION := 0.11.3
MINUI_PRESENTER_VERSION := 0.7.0
JQ_VERSION := 1.7.1

NIX ?= nix

clean:
	rm -f bin/*/minui-list* || true
	rm -f bin/*/minui-presenter* || true
	rm -f bin/*/jq* || true
	rm -f bin/*/wireguard-go* || true
	rm -f bin/*/wg* || true

bump-version:
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json

build: \
	$(foreach platform,$(PLATFORMS),bin/$(platform)/minui-list bin/$(platform)/minui-presenter) \
	$(foreach arch,$(ARCHITECTURES),bin/$(arch)/jq bin/$(arch)/wireguard-go bin/$(arch)/wg)

bin/%/minui-list:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-list -sSL https://github.com/josegonzalez/minui-list/releases/download/$(MINUI_LIST_VERSION)/minui-list-$*
	chmod +x bin/$*/minui-list

bin/%/minui-presenter:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-presenter -sSL https://github.com/josegonzalez/minui-presenter/releases/download/$(MINUI_PRESENTER_VERSION)/minui-presenter-$*
	chmod +x bin/$*/minui-presenter

bin/arm/jq:
	mkdir -p bin/arm
	curl -f -o bin/arm/jq -sSL https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-armhf
	chmod +x bin/arm/jq
	curl -sSL -o bin/arm/jq.LICENSE "https://github.com/jqlang/jq/raw/refs/heads/master/COPYING"

bin/arm64/jq:
	mkdir -p bin/arm64
	curl -f -o bin/arm64/jq -sSL https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-arm64
	chmod +x bin/arm64/jq
	curl -sSL -o bin/arm64/jq.LICENSE "https://github.com/jqlang/jq/raw/refs/heads/master/COPYING"

bin/arm/wireguard-go:
	mkdir -p bin/arm
	$(NIX) build .#wireguard-go-armv7l -o result-wireguard-go-armv7l
	install -m 0755 result-wireguard-go-armv7l/bin/wireguard-go bin/arm/wireguard-go
	rm -f result-wireguard-go-armv7l
	curl -f -sSL -o bin/arm/wireguard-go.LICENSE "https://git.zx2c4.com/wireguard-go/plain/COPYING"

bin/arm64/wireguard-go:
	mkdir -p bin/arm64
	$(NIX) build .#wireguard-go-aarch64 -o result-wireguard-go-aarch64
	install -m 0755 result-wireguard-go-aarch64/bin/wireguard-go bin/arm64/wireguard-go
	rm -f result-wireguard-go-aarch64
	curl -f -sSL -o bin/arm64/wireguard-go.LICENSE "https://git.zx2c4.com/wireguard-go/plain/COPYING"

bin/arm/wg:
	mkdir -p bin/arm
	$(NIX) build .#wg-armv7l -o result-wg-armv7l
	install -m 0755 result-wg-armv7l/bin/wg bin/arm/wg
	rm -f result-wg-armv7l
	curl -f -sSL -o bin/arm/wg.LICENSE "https://git.zx2c4.com/wireguard-tools/plain/COPYING"

bin/arm64/wg:
	mkdir -p bin/arm64
	$(NIX) build .#wg-aarch64 -o result-wg-aarch64
	install -m 0755 result-wg-aarch64/bin/wg bin/arm64/wg
	rm -f result-wg-aarch64
	curl -f -sSL -o bin/arm64/wg.LICENSE "https://git.zx2c4.com/wireguard-tools/plain/COPYING"

release: build
	mkdir -p dist
	git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
	while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; done < .gitarchiveinclude
	ls -lah dist
