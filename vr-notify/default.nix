# Desktop notifications (KDE Connect, Firefox, Xpra's from hal2, ...) as clickable panels in
# VR: vr-notifyd serves org.freedesktop.Notifications on the user bus and shows each
# notification as a SteamVR overlay, fixed in the room below and right of where you looked
# when it came in. The laser clicks its buttons (the app gets ActionInvoked), the body (the
# app's default action) or its X. A toast stays while the laser is on it.
#
# It replaces SteamOS's steam_notif_daemon (steam-notif-daemon.service, masked here), which
# hands each notification to Steam with `~/.steam/root/ubuntu12_32/steam steam://...`: an
# x86 program that can't run on the Frame, and a URL this Steam client ignores, so nothing
# showed at all.
#
# Without SteamVR running, notifications wait (up to 50) and show once it starts; vr-notifyd
# never starts SteamVR itself. Apps in the nested desktop have their own D-Bus and Plasma's
# notifications, so this doesn't see theirs.
#
# Placement and size: see `vr-notifyd --help`, set with `args` below.
{ config, pkgs, ... }:
let
  vr-notifyd = pkgs.callPackage ./package.nix { };
  args = [ ];  # e.g. [ "--width" "0.3" "--right" "12" "--down" "18" ]
  # SteamOS's fonts (Noto, with color emoji), DejaVu if there are none
  fonts = pkgs.makeFontsConf { fontDirectories = [ "/usr/share/fonts" pkgs.dejavu_fonts ]; };
in {
  home.packages = [ vr-notifyd ];

  systemd.user.services.vr-notifyd = {
    Unit = {
      Description = "Desktop notifications in VR";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      # takes over its bus name in a running session; masked below for the next ones
      Conflicts = [ "steam-notif-daemon.service" ];
    };
    Service = {
      Environment = [ "FONTCONFIG_FILE=${fonts}" ];
      ExecStart = "${vr-notifyd}/bin/vr-notifyd ${toString args}";
      Restart = "on-failure";
      RestartSec = 3;
      Slice = "session.slice";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  xdg.configFile."systemd/user/steam-notif-daemon.service".source =
    config.lib.file.mkOutOfStoreSymlink "/dev/null";
}
