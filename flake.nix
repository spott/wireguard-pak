{
  description = "Cross-compiled WireGuard binaries for the TrimUI Brick (tg5040) and similar arm/arm64 MinUI devices.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # wg needs a static C link, which means musl — the nixpkgs glibc
        # cross sets don't ship libc.a.
        wgCross = {
          aarch64 = pkgs.pkgsCross.aarch64-multiplatform-musl;
          armv7l = pkgs.pkgsCross.muslpi;
        };

        # wireguard-go: pure Go with CGO disabled, so we cross-compile using
        # the host's Go toolchain and just override GOOS/GOARCH/GOARM. Using
        # crossPkgs.buildGoModule would force-enable CGO and pull in the cross
        # glibc, producing a binary linked against /nix/store paths that don't
        # exist on the device.
        mkWireguardGo = { goarch, goarm ? null }:
          pkgs.buildGoModule rec {
            pname = "wireguard-go";
            version = "0.0.20230223";

            src = pkgs.fetchgit {
              url = "https://git.zx2c4.com/wireguard-go";
              rev = "12269c2761734b15625017d8565745096325392f";
              hash = "sha256-br7/dwr/e4HvBGJXh+6lWqxBUezt5iZNy9BFqEA1bLk=";
            };

            vendorHash = "sha256-RqZ/3+Xus5N1raiUTUpiKVBs/lrJQcSwr1dJib2ytwc=";

            ldflags = [
              "-s"
              "-w"
              "-X main.Version=${version}"
            ];

            # buildGoModule exports GOOS/GOARCH from stdenv.hostPlatform during
            # its buildPhase setup, which overrides anything set via `env`.
            # preBuild runs after that setup, so it's the right hook for the
            # cross-compile knobs.
            preBuild = ''
              export CGO_ENABLED=0
              export GOOS=linux
              export GOARCH=${goarch}
              ${pkgs.lib.optionalString (goarm != null) "export GOARM=${goarm}"}
            '';

            doCheck = false;

            # Cross-compiling with the host Go puts binaries under
            # $out/bin/$GOOS_$GOARCH/. Hoist back to $out/bin/ and rename
            # "wireguard" (the go.mod module name) to "wireguard-go" so the
            # Makefile and launch.sh can find it.
            postInstall = ''
              mv $out/bin/linux_${goarch}/wireguard $out/bin/wireguard-go
              rmdir $out/bin/linux_${goarch}
            '';

            meta = with pkgs.lib; {
              description = "Userspace Go implementation of WireGuard";
              homepage = "https://git.zx2c4.com/wireguard-go/";
              license = licenses.mit;
            };
          };

        # The wg Makefile picks PLATFORM from `uname -s` — force "linux" so
        # it doesn't try to use Darwin uapi headers when cross-compiling from
        # macOS. Only src/wg ends up in $out/bin; wg-quick/bash-completion/
        # systemd units are off.
        mkWg = crossPkgs:
          crossPkgs.stdenv.mkDerivation rec {
            pname = "wg";
            version = "1.0.20210914";

            src = pkgs.fetchurl {
              url = "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-${version}.tar.xz";
              hash = "sha256-lC7TLR1mMZMsgv+GyRroQo1MkL/sIxoU699sKfBo5gs=";
            };

            enableParallelBuilding = true;

            makeFlags = [
              "-C" "src"
              "PLATFORM=linux"
              "WITH_BASHCOMPLETION=no"
              "WITH_SYSTEMDUNITS=no"
              "WITH_WGQUICK=no"
              "LDFLAGS=-static"
            ];

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp src/wg $out/bin/wg
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "WireGuard userland CLI";
              homepage = "https://git.zx2c4.com/wireguard-tools/";
              license = licenses.gpl2Only;
              platforms = platforms.linux;
            };
          };
      in {
        packages = {
          wireguard-go-aarch64 = mkWireguardGo { goarch = "arm64"; };
          wireguard-go-armv7l = mkWireguardGo { goarch = "arm"; goarm = "7"; };
          wg-aarch64 = mkWg wgCross.aarch64;
          wg-armv7l = mkWg wgCross.armv7l;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ go jq curl gnumake unzip zip ];
        };
      });
}
