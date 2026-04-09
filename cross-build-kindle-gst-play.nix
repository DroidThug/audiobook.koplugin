# Cross-compile kindle-gst-play for Kindle (armv7l)
#
# Minimal GStreamer WAV player that uses dlopen -- no GStreamer headers
# or libraries needed at build time, only the cross-toolchain's libc/libdl.
#
# Usage: nix-build cross-build-kindle-gst-play.nix --no-out-link
# Then:  ls $(nix-build cross-build-kindle-gst-play.nix --no-out-link)/bin/
let
  # Same pinned nixpkgs as espeak/bluealsa builds
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
in
crossPkgs.stdenv.mkDerivation {
  pname = "kindle-gst-play";
  version = "0.1.0";
  src = ./kindle;

  # No external dependencies -- dlopen loads GStreamer at runtime
  buildInputs = [];

  buildPhase = ''
    $CC -O2 -Wall -Wextra -Wno-unused-parameter \
        -Wl,-E -Wl,--version-script=glibc_compat.map \
        -o gst-play gst-play.c -ldl
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp gst-play $out/bin/
  '';

  # Strip is handled by Nix stdenv automatically

  meta = with pkgs.lib; {
    description = "Minimal GStreamer WAV player for Kindle via mixersink (dlopen, no headers)";
    license = licenses.agpl3Only;
    platforms = [ "armv7l-linux" ];
  };
}
