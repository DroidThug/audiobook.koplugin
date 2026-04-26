# Cross-compile a minimal espeak-ng for Kobo (armv7l)
# Usage: nix-build cross-build-espeak.nix --no-out-link
# Then: ls $(nix-build cross-build-espeak.nix --no-out-link)/bin/
let
  # Pin nixpkgs to a known-good commit (nixpkgs-unstable, 2026-03-22)
  # to avoid CI breakage from channel updates
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
(crossPkgs.espeak-ng.override {
  # Disable all the heavy/failing optional dependencies
  pcaudiolibSupport = false;   # No audio output lib (we write to wav files)
  sonicSupport = false;        # No sonic speed adjustment
  mbrolaSupport = false;       # No MBROLA voice support
}).overrideAttrs (old: {
  # Remove the postInstall that wraps with alsa-plugins (fails cross-compile
  # and unnecessary for Kobo where we only use --stdout / -w file.wav)
  postInstall = "";
})
