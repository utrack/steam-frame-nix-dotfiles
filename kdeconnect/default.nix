# KDE Connect in the Steam session, without a desktop: kdeconnectd is a user service on the
# user bus, so the phone's notifications show in VR (vr-notify, with their actions: reply,
# pairing requests, ...). The pairings and the Frame's identity are in ~/.config/kdeconnect.
#
# It runs on Steam's X display (:0) for clipboard sync, the phone as mouse and keyboard, and
# its dialogs (reply, pairing), which open as windows in VR; without X it runs headless.
#
# The nested desktops have their own D-Bus. kdeconnectd must run only once (one identity,
# one set of ports), so the package isn't in the profile: its D-Bus activation file and
# autostart entry would be seen there and start a second daemon. Activation on any bus goes
# through ~/.local/share/dbus-1/services below instead: systemd starts the service on the
# user bus, and elsewhere it fails. kdeconnect-cli, kdeconnect-app (also in the VR "+" menu)
# and kdeconnect-sms always use the user bus, from the nested desktops too.
#
# The firewall's public zone already allows its ports (1714-1764 tcp/udp).
{ config, lib, pkgs, ... }:
let
  kdeconnect = config.lib.hostGpu.wrap pkgs.kdePackages.kdeconnect-kde;
  userBus = ''export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(${pkgs.coreutils}/bin/id -u)/bus'';
  tools = pkgs.runCommand "kdeconnect-tools" { } ''
    mkdir -p $out/bin
    for p in kdeconnect-cli kdeconnect-app kdeconnect-sms; do
      printf '#!%s\n%s\nexec %s "$@"\n' ${pkgs.runtimeShell} ${pkgs.lib.escapeShellArg userBus} \
        ${kdeconnect}/bin/$p > $out/bin/$p
      chmod +x $out/bin/$p
    done
  '';
in {
  home.packages = [ tools ];

  systemd.user.services.kdeconnectd = {
    Unit = {
      Description = "KDE Connect";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" "vr-notifyd.service" ];
    };
    Service = {
      Type = "dbus";
      BusName = "org.kde.kdeconnect";
      Environment = [
        "QT_QPA_PLATFORM=xcb;offscreen"
        # a notification's default action ("Open") starts kdeconnect-app
        "PATH=${tools}/bin:${config.home.profileDirectory}/bin:/usr/local/bin:/usr/bin"
      ];
      ExecStart = "${kdeconnect}/bin/kdeconnectd";
      Restart = "on-failure";
      RestartSec = 5;
      Slice = "session.slice";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  xdg.dataFile."dbus-1/services/org.kde.kdeconnect.service".text = ''
    [D-BUS Service]
    Name=org.kde.kdeconnect
    Exec=${pkgs.coreutils}/bin/false
    SystemdService=kdeconnectd.service
  '';
  # the user bus reads new service files only when told to
  home.activation.reloadUserBus = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${pkgs.dbus}/bin/dbus-send --session --type=method_call --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig || true
  '';

  # in the VR "+" menu; the package's own file name, so it replaces that one where both are seen
  xdg.dataFile."applications/org.kde.kdeconnect.app.desktop".source =
    pkgs.runCommand "kdeconnect-app-launcher" { } ''
      sed -e 's|^Exec=kdeconnect-app|Exec=${tools}/bin/kdeconnect-app|' \
        -e 's|^Icon=.*|Icon=${kdeconnect}/share/icons/hicolor/scalable/apps/kdeconnect.svg|' \
        ${kdeconnect}/share/applications/org.kde.kdeconnect.app.desktop > $out
    '';
}
