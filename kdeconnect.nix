# KDE Connect in the Frametop desktop.
#
# The Frametop desktop runs Plasma on a private D-Bus (dbus-run-session), with
# its own XDG_CONFIG_HOME (~/.config/frametop), and Plasma there doesn't start
# systemd units. So the daemon starts from that desktop's autostart, not as a
# systemd user service (home-manager's services.kdeconnect), and the desktop's
# KDE Connect config links to the one in ~/.config, so the Frame keeps one
# identity and its pairings.
{ config, pkgs, ... }:
let
  kdeconnect = config.lib.hostGpu.wrap pkgs.kdePackages.kdeconnect-kde;

  # kdeconnectd outlives its session bus, and Frametop keeps programs started
  # in the desktop running past a desktop restart (session/keep-apps.sh). So
  # one daemon at a time, stopped once the bus of the session that started it
  # is gone.
  daemon = pkgs.writeShellScript "kdeconnectd-session" ''
    pidfile=/run/user/$UID/kdeconnectd-session.pid
    if read -r old 2>/dev/null < "$pidfile" && read -rd "" cmd 2>/dev/null < "/proc/$old/cmdline" \
        && [[ $cmd == *kdeconnectd* ]]; then
      kill "$old"
      ${pkgs.coreutils}/bin/sleep 1
    fi
    ${kdeconnect}/bin/kdeconnectd "$@" &
    daemon=$!
    echo "$daemon" > "$pidfile"
    while kill -0 "$daemon" 2>/dev/null; do
      if ! ${pkgs.dbus}/bin/dbus-send --session --dest=org.freedesktop.DBus / org.freedesktop.DBus.Peer.Ping 2>/dev/null; then
        kill "$daemon"
        break
      fi
      ${pkgs.coreutils}/bin/sleep 15
    done
    wait
  '';

  # The session's XDG_DATA_DIRS may not include the Nix profile, so the
  # launcher goes in ~/.local/share/applications, with absolute paths. Same
  # file name as the package's, so it replaces that one where both are seen.
  launcher = pkgs.runCommand "kdeconnect-app-launcher" { } ''
    sed -e 's|^Exec=kdeconnect-app|Exec=${kdeconnect}/bin/kdeconnect-app|' \
      -e 's|^Icon=.*|Icon=${kdeconnect}/share/icons/hicolor/scalable/apps/kdeconnect.svg|' \
      ${kdeconnect}/share/applications/org.kde.kdeconnect.app.desktop > $out
  '';
in {
  home.packages = [ kdeconnect ];

  xdg.configFile."frametop/autostart/kdeconnectd.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=KDE Connect daemon
    Exec=${daemon}
    X-KDE-autostart-phase=1
    NoDisplay=true
  '';
  # The tray icon: Plasma's KDE Connect widget isn't installed on the host.
  xdg.configFile."frametop/autostart/kdeconnect-indicator.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=KDE Connect indicator
    Exec=${kdeconnect}/bin/kdeconnect-indicator
    X-KDE-autostart-phase=2
    NoDisplay=true
  '';
  xdg.configFile."frametop/kdeconnect".source =
    config.lib.file.mkOutOfStoreSymlink "${config.xdg.configHome}/kdeconnect";

  xdg.dataFile."applications/org.kde.kdeconnect.app.desktop".source = launcher;
}
