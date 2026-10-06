# Apps on hal2 as floating VR windows, through xpra over QUIC (udp/14500).
#
# The session (:100) runs on hal2 as the systemd user service xpra-hal2; the client checks
# hal2's self-signed certificate and authenticates with the files in ~/.config/xpra/hal2.
#
#   hal2 <command> [args...]   runs the command in hal2's xpra session (:100),
#                              starting the local client as needed
#   hal2-vicinae               toggles a vicinae instance of its own in that session
#
# Windows land on the Steam session's X display (:0), which floats each of them.
{ config, pkgs, ... }:
let
  xpra = config.lib.hostGpu.wrap pkgs.xpra;
  session = "quic://hal2.home.arpa:14500/";

  hal2 = pkgs.writeShellApplication {
    name = "hal2";
    runtimeInputs = [ xpra pkgs.procps ];
    text = ''
      session=${session}
      creds=$HOME/.config/xpra/hal2
      opts=(--ssl-ca-certs="$creds/cert.pem" --password-file="$creds/password")
      log=''${XDG_RUNTIME_DIR:-/tmp}/hal2-xpra.log
      export DISPLAY=:0 GDK_BACKEND=x11

      if ! pgrep -f "xpra-wrapped attach $session" >/dev/null; then
        setsid xpra attach "$session" "''${opts[@]}" >"$log" 2>&1 &
      fi

      [ $# -eq 0 ] && exit 0
      for _ in $(seq 30); do
        xpra control "$session" "''${opts[@]}" start -- "$@" >/dev/null 2>&1 && exit 0
        sleep 1
      done
      echo "hal2: could not start '$*' in $session, see $log" >&2
      exit 1
    '';
  };

  # vicinae's IPC socket is always $XDG_RUNTIME_DIR/vicinae/vicinae.sock, so this instance gets
  # a runtime dir of its own (linking the rest, except the Wayland sockets of hal2's desktop),
  # and leaves the desktop's instance alone
  hal2-vicinae = pkgs.writeShellApplication {
    name = "hal2-vicinae";
    runtimeInputs = [ hal2 ];
    text = ''
      # shellcheck disable=SC2016
      exec hal2 sh -c '
        rt=$XDG_RUNTIME_DIR/xpra-vicinae
        mkdir -p -m 700 "$rt/vicinae"
        for f in "$XDG_RUNTIME_DIR"/*; do
          case ''${f##*/} in xpra-vicinae|vicinae|wayland-*) ;; *) ln -sfn "$f" "$rt/" ;; esac
        done
        export XDG_RUNTIME_DIR=$rt
        vicinae ping >/dev/null 2>&1 && exec vicinae toggle
        exec vicinae server --open
      '
    '';
  };
in {
  home.packages = [ xpra hal2 hal2-vicinae ];

  xdg.desktopEntries.hal2-vicinae = {
    name = "Vicinae (hal2)";
    comment = "Vicinae launcher on hal2";
    exec = "${hal2-vicinae}/bin/hal2-vicinae";
    icon = "system-search";
    terminal = false;
  };
}
