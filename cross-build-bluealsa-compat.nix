# Build bluez-alsa against Debian Jessie (glibc 2.19) for Kobo armv7l.
#
# The standard Nix cross-compilation uses a newer glibc, which makes the
# resulting binary incompatible with devices like the Kobo Clara 2E that
# ship with glibc 2.19. This expression creates a Debian Jessie sysroot
# (glibc 2.19) and builds bluez-alsa against it.
#
# Because the build downloads Debian packages from archive.debian.org, it
# requires network access during the build phase. In Nix this means you
# must build with sandboxing disabled:
#
#   nix-build cross-build-bluealsa-compat.nix --no-out-link --option sandbox false
#
# Or if using flakes:
#
#   nix build .#bluealsa-kobo-compat --no-sandbox
#
# For CI (GitHub Actions), package-for-kobo.sh calls build-bluealsa-compat.sh
# directly, which handles the download and build outside of Nix's sandbox.
let
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
in

pkgs.stdenv.mkDerivation {
  pname = "bluealsa-armv7l-glibc219";
  version = "4.1.1";

  # We don't unpack a traditional source tarball here.
  # The build script downloads everything it needs.
  src = ./build-bluealsa-compat.sh;
  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.curl
    pkgs.gnutar
    pkgs.binutils
    pkgs.gzip
    pkgs.xz
    pkgs.gnugrep
    pkgs.gawk
    pkgs.coreutils
    pkgs.gnumake
    pkgs.autoconf
    pkgs.automake
    pkgs.libtool
    pkgs.pkg-config
    crossPkgs.stdenv.cc
  ];

  buildPhase = ''
    export CC="${crossPkgs.stdenv.cc}/bin/armv7l-unknown-linux-gnueabihf-gcc"
    export CXX="${crossPkgs.stdenv.cc}/bin/armv7l-unknown-linux-gnueabihf-g++"
    export AR="${crossPkgs.stdenv.cc}/bin/armv7l-unknown-linux-gnueabihf-ar"
    export READELF="${crossPkgs.stdenv.cc}/bin/armv7l-unknown-linux-gnueabihf-readelf"
    export STRIP="${crossPkgs.stdenv.cc}/bin/armv7l-unknown-linux-gnueabihf-strip"

    # The script expects to be run from the repo root
    cp $src build-bluealsa-compat.sh
    bash build-bluealsa-compat.sh
  '';

  installPhase = ''
    mkdir -p $out
    cp -r .build-bluealsa-compat/out/* $out/
  '';

  # Required because the build downloads Debian packages on the fly.
  # Without this, Nix's sandbox blocks network access.
  __noChroot = true;

  meta = with pkgs.lib; {
    description = "Bluez-alsa built against glibc 2.19 for Kobo armv7l";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
