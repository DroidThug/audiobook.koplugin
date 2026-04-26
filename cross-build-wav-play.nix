# Cross-compile wav-play for armv7l (PocketBook / generic ALSA devices)
# Minimal WAV player using ALSA -- replaces aplay on devices that have
# libasound but no alsa-utils installed.
#
# Usage: nix-build cross-build-wav-play.nix --no-out-link
# Result: $out/bin/wav-play
let
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {
    overlays = [
      # libadwaita's test-preferences-group test crashes with SIGTRAP in
      # headless CI environments (no display server). It is pulled in
      # transitively via alsa-plugins -> ffmpeg -> sdl3 -> zenity.
      (self: super: {
        libadwaita = super.libadwaita.overrideAttrs (old: {
          doCheck = false;
        });
      })
    ];
  };
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
in
crossPkgs.stdenv.mkDerivation {
  pname = "wav-play";
  version = "1.0.0";
  src = ./wav-play.c;
  dontUnpack = true;
  buildInputs = [ crossPkgs.alsa-lib ];
  buildPhase = ''
    $CC -O2 -o wav-play $src -lasound
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp wav-play $out/bin/
  '';
}
