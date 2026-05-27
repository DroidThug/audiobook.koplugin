# Cross-compile a static mbrola wrapper for Kobo (armv7l) using musl
# Usage: nix-build cross-build-mbrola-wrapper-musl.nix --no-out-link
let
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform.pkgsStatic;
in

crossPkgs.stdenv.mkDerivation {
  pname = "mbrola-wrapper";
  version = "0.1.0";
  src = ./mbrola-wrapper.c;

  dontUnpack = true;
  dontConfigure = true;

  buildPhase = ''
    cp "$src" mbrola-wrapper.c
    $CC -static -O2 -o mbrola-wrapper mbrola-wrapper.c
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp mbrola-wrapper $out/bin/
  '';
}
