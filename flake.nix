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

        crossSets = {
          aarch64 = pkgs.pkgsCross.aarch64-multiplatform;
          armv7l = pkgs.pkgsCross.armv7l-hf-multiplatform;
        };

        # wireguard-go: pure-Go userspace WireGuard implementation. Statically
        # linked aarch64/armv7l binaries land in $out/bin/wireguard-go.
        mkWireguardGo = crossPkgs:
          crossPkgs.buildGoModule rec {
            pname = "wireguard-go";
            version = "0.0.20230223";

            # Pin to a known tag from https://git.zx2c4.com/wireguard-go/refs/.
            # The two hashes below are placeholders -- the first `nix build`
            # will fail and print the real values to substitute in.
            src = pkgs.fetchgit {
              url = "https://git.zx2c4.com/wireguard-go";
              rev = "12269c2761734b15625017d8565745096325392f";
              sha256 = pkgs.lib.fakeSha256;
            };

            vendorHash = pkgs.lib.fakeHash;

            ldflags = [
              "-s"
              "-w"
              "-X main.Version=${version}"
            ];

            # CGO is not needed; produce a fully static binary.
            CGO_ENABLED = 0;

            doCheck = false;

            meta = with pkgs.lib; {
              description = "Userspace Go implementation of WireGuard";
              homepage = "https://git.zx2c4.com/wireguard-go/";
              license = licenses.mit;
            };
          };

        # wg: CLI from wireguard-tools, statically linked against the cross
        # toolchain's libc. We only ship src/wg, not wg-quick.
        mkWg = crossPkgs:
          crossPkgs.stdenv.mkDerivation rec {
            pname = "wg";
            version = "1.0.20210914";

            src = pkgs.fetchurl {
              url = "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-${version}.tar.xz";
              sha256 = pkgs.lib.fakeSha256;
            };

            enableParallelBuilding = true;

            makeFlags = [
              "-C" "src"
              "WITH_BASHCOMPLETION=no"
              "WITH_SYSTEMDUNITS=no"
              "WITH_WGQUICK=no"
              "LDFLAGS=-static"
              "PREFIX=$(out)"
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
          wireguard-go-aarch64 = mkWireguardGo crossSets.aarch64;
          wireguard-go-armv7l = mkWireguardGo crossSets.armv7l;
          wg-aarch64 = mkWg crossSets.aarch64;
          wg-armv7l = mkWg crossSets.armv7l;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ go jq curl gnumake unzip zip ];
        };
      });
}
