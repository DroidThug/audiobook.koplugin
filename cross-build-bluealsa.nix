# Cross-compile bluez-alsa (BlueALSA) for Kobo (armv7l)
# Provides BT audio bridging on BlueZ-based Kobo devices (Libra 2, Io, etc.)
# that lack the MTK mtkbtmwrpcaudiosink GStreamer plugin.
#
# Bundled output:
#   bin/bluealsa          -- daemon (manages A2DP/HFP profiles via BlueZ D-Bus)
#   lib/alsa-lib/         -- ALSA PCM + CTL plugins (loaded by system aplay)
#   etc/alsa/conf.d/      -- ALSA config defining the "bluealsa" PCM device
#   share/dbus-1/system.d -- D-Bus policy (root can use org.bluealsa)
#
# Usage: nix-build cross-build-bluealsa.nix --no-out-link
let
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
in
(crossPkgs.bluez-alsa.override {
  # No AAC -- SBC is sufficient for BT audio on Kobo and avoids
  # pulling in fdk-aac (large, patent-encumbered).
  aacSupport = false;
}).overrideAttrs (old: {
  # The upstream nixpkgs derivation puts glib only in buildInputs
  # (target arch).  During cross-compilation gdbus-codegen (a glib
  # build tool) must run on the build host, so we add the native
  # (x86_64) glib to nativeBuildInputs.
  nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.glib ];
  # Kobo has no systemd; disable hcitop/rfcomm to trim deps.
  configureFlags = (old.configureFlags or []) ++ [
    "--disable-systemd"
    "--disable-hcitop"
    "--disable-rfcomm"
  ];
})
