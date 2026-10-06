# hal2's keyboard and mouse in the Steam session, through lan-mouse (udp/4242).
#
# hal2 (KDE, Wayland) captures its input with ~/.config/lan-mouse/config.toml and the user
# service lan-mouse.service there (not managed here, hal2 runs Arch), and sends it to this
# daemon. The cursor goes over hal2's right screen edge; Ctrl+Shift+Meta+Alt (left) gives it
# back to hal2.
#
# Here the input comes out of a uinput mouse and keyboard on the USB bus ("lan-mouse hal2
# mouse|keyboard"), so Frametop's input relay takes them like a plugged-in mouse and keyboard:
# the 3D pointer goes between windows and Steam's controls (XTEST on :0 kept the pointer
# inside one window). lan-mouse has no uinput backend, so it runs with its dummy backend,
# which logs every event, and uinput-bridge.py replays them.
#
# ~/.config/lan-mouse/config.toml isn't managed here: it lists the certificate fingerprints
# accepted for incoming input (hal2's), e.g.
#   port = 4242
#   [authorized_fingerprints]
#   "<sha256 fingerprint, aa:bb:...>" = "hal2"
# A fingerprint: openssl x509 -in ~/.config/lan-mouse/lan-mouse.pem -noout -fingerprint -sha256
# on that machine. This end's certificate is ~/.config/lan-mouse/lan-mouse.pem, created on the
# first start.
{ pkgs, ... }:
let
  # "<name> <code>" for the key names the dummy backend logs, from this lan-mouse's source
  keycodes = pkgs.runCommand "lan-mouse-keycodes" { } ''
    ${pkgs.gawk}/bin/awk '/^pub enum Linux/ { on = 1; next } on && /^}/ { exit }
      on && match($0, /^ *([A-Za-z0-9]+) = ([0-9]+),/, m) { print m[1], m[2] }' \
      ${pkgs.lan-mouse.src}/input-event/src/scancode.rs > $out
    [ "$(wc -l < $out)" -gt 200 ]
  '';
in {
  home.packages = [ pkgs.lan-mouse ];

  systemd.user.services.lan-mouse = {
    Unit = {
      Description = "lan-mouse: hal2's keyboard and mouse in the Steam session";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Environment = [ "RUST_LOG=info" ];
      # receives only: input capture finds no backend in the Steam session and stops (the dummy
      # capture backend would log thousands of lines a second)
      ExecStart = "${pkgs.python3}/bin/python3 -u ${./uinput-bridge.py} ${keycodes} "
        + "${pkgs.lan-mouse}/bin/lan-mouse --emulation-backend dummy daemon";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
