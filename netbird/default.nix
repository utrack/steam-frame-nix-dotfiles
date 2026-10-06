# NetBird: the daemon as a system service, the desktop app (Wails) for both sessions.
#
#   netbird-service-install   (once, and after updates; asks for the sudo password) puts the
#                             client into the root profile /nix/var/nix/profiles/netbird and
#                             installs, enables and (re)starts /etc/systemd/system/netbird.service
#   netbird-app               starts the desktop app and shows its window
#   netbird ...               the CLI (talks to the daemon's socket)
#
# The daemon needs root (WireGuard interface, routes, DNS, firewall), so Home Manager can't run
# it; the root profile keeps it out of the user-writable Nix profile and alive across garbage
# collections, and /etc (an overlay on SteamOS) keeps the unit across updates. The app and the
# daemon have to be the same version: activation warns while the installed one differs.
#
# The app's main window starts hidden behind its tray icon, and the Steam session has no tray:
# netbird-app starts the app as needed and raises the window through the app's single-instance
# D-Bus call (one instance per session bus; the Frametop desktop has a bus of its own).
{ config, lib, pkgs, ... }:
let
  client = pkgs.netbird;
  ui = config.lib.hostGpu.wrap pkgs.netbird-ui;

  profile = "/nix/var/nix/profiles/netbird";
  stateDir = "/var/lib/netbird";
  socket = "unix:///var/run/netbird/sock";

  unit = pkgs.writeText "netbird.service" ''
    [Unit]
    Description=NetBird mesh VPN client (installed by netbird-service-install, Home Manager)
    Documentation=https://docs.netbird.io/
    Wants=network-online.target
    After=network-online.target
    StartLimitIntervalSec=5
    StartLimitBurst=10

    [Service]
    ExecStart=${profile}/bin/netbird service run
    Restart=always
    RuntimeDirectory=netbird
    RuntimeDirectoryMode=0755
    StateDirectory=netbird
    StateDirectoryMode=0700
    ConfigurationDirectory=netbird
    WorkingDirectory=${stateDir}
    Environment=NB_STATE_DIR=${stateDir}
    Environment=NB_CONFIG=${stateDir}/config.json
    Environment=NB_DAEMON_ADDR=${socket}
    Environment=NB_LOG_FILE=console
    Environment=NB_SERVICE=netbird
    # the debug bundle collects this unit's journal
    Environment=SYSTEMD_UNIT=netbird.service

    [Install]
    WantedBy=multi-user.target
  '';

  netbird-service-install = pkgs.writeShellApplication {
    name = "netbird-service-install";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      sudo=/usr/bin/sudo
      echo "Installing ${client} as ${profile} and /etc/systemd/system/netbird.service"
      $sudo /nix/var/nix/profiles/default/bin/nix-env --profile ${profile} --set ${client}
      $sudo install -m 644 ${unit} /etc/systemd/system/netbird.service
      $sudo systemctl daemon-reload
      $sudo systemctl enable netbird.service
      $sudo systemctl restart netbird.service
      echo "Done. Connect with netbird-app (or: netbird up)."
    '';
  };

  netbird-app = pkgs.writeShellApplication {
    name = "netbird-app";
    runtimeInputs = [ ui pkgs.dbus pkgs.gnugrep pkgs.coreutils pkgs.util-linux ];
    text = ''
      name=org.wails_app_io_netbird_ui.SingleInstance
      running() {
        dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
          org.freedesktop.DBus.NameHasOwner string:$name 2>/dev/null | grep -q 'boolean true'
      }
      export WEBKIT_DISABLE_DMABUF_RENDERER=1
      # The app's windows have fixed sizes in px; the Steam session's Xft.dpi (144) zooms their
      # pages by 1.5 and cuts them off (Xlib merges $XENVIRONMENT over the server's resources)
      export XENVIRONMENT=${pkgs.writeText "netbird-ui-xresources" "Xft.dpi: 96\n"}
      export LOCALE_ARCHIVE=''${LOCALE_ARCHIVE:-${pkgs.glibcLocales}/lib/locale/locale-archive}
      if ! running; then
        setsid netbird-ui --daemon-addr=${socket} >"''${XDG_RUNTIME_DIR:-/tmp}/netbird-ui.log" 2>&1 &
        for _ in $(seq 100); do running && break; sleep 0.2; done
        # the name is taken before the app can show windows
        sleep 2
      fi
      # a second instance makes the running one show its window, then exits
      exec netbird-ui --daemon-addr=${socket}
    '';
  };

  icon = "${pkgs.netbird-ui}/share/icons/hicolor/256x256/apps/netbird.png";
in {
  home.packages = [ client ui netbird-app netbird-service-install ];

  # Same desktop ID as the package's entry, in ~/.local/share/applications with absolute
  # paths (the Frametop desktop's XDG_DATA_DIRS may not include the Nix profile).
  xdg.dataFile."applications/netbird.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=NetBird
    Comment=NetBird VPN
    Exec=${netbird-app}/bin/netbird-app
    Icon=${icon}
    Terminal=false
    Categories=Network;
    Keywords=netbird;vpn;wireguard;
    StartupWMClass=org.wails.netbird
  '';

  home.activation.netbirdServiceCheck = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ "$(readlink -f ${profile} 2>/dev/null)" != "${client}" ]; then
      warnEcho "NetBird: the system daemon is missing or not ${client.version} like the app; run: netbird-service-install"
    fi
  '';
}
