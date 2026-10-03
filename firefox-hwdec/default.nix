# Hardware video decoding (H.264, HEVC 8-bit) in the Firefox Flatpak, on top
# of steamFrame.firefox: Firefox starts with the patched FFmpeg
# (rpi-ffmpeg.nix) on LD_LIBRARY_PATH, ahead of the runtime's. Its store path
# is exposed read-only to the sandbox. Both are `flatpak run` options of the
# launcher, not a Flatpak override: only launches from the desktop entry
# (menus, the "+" menu, links as the default browser) get them.
{ config, lib, pkgsFlatpak, ... }:
let
  ffmpeg = pkgsFlatpak.callPackage ./rpi-ffmpeg.nix { };
in {
  config = lib.mkIf config.steamFrame.firefox.enable {
    steamFrame.launchers."org.mozilla.firefox" = {
      flatpakArgs = [ "--filesystem=${ffmpeg}:ro" ];
      env.LD_LIBRARY_PATH = "${ffmpeg}/lib";
    };
  };
}
