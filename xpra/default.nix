# Apps on hal2 as floating VR windows, through xpra over QUIC (udp/14500).
#
# The session (:100) runs on hal2 as the systemd user service xpra-hal2; the client checks
# hal2's self-signed certificate and authenticates with the files in ~/.config/xpra/hal2.
#
#   hal2 <command> [args...]   runs the command in hal2's xpra session (:100),
#                              starting the local client as needed
#
# The client connects to the first of knownHosts and ~/.config/xpra/hal2/hosts that answers,
# or asks for a host (kdialog) when none does; HAL2_HOST=<host[:port]> skips both.
#   hal2-vicinae               toggles a vicinae instance of its own in that session
#
# Windows land on the Steam session's X display (:0), which floats each of them.
{ config, pkgs, ... }:
let
  # gamescope takes xpra's popups (menus, Firefox's autoscroll icon) for SDL fullscreen wrappers
  # because of the child window GDK gives them, and shows them instead of their parent window
  xpra = config.lib.hostGpu.wrap (pkgs.xpra.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./gamescope-popups.patch ];
  }));
  # hal2's certificate is for this name, whichever address the client connects to
  certName = "hal2.home.arpa";
  # tried in order, before the hosts entered in the picker (~/.config/xpra/hal2/hosts)
  knownHosts = [ "10.86.200.234" "hal2.home.arpa" ];
  port = 14500;

  hal2 = pkgs.writeShellApplication {
    name = "hal2";
    runtimeInputs = [ xpra pkgs.procps pkgs.coreutils pkgs.gnugrep pkgs.gawk ];
    text = ''
      creds=$HOME/.config/xpra/hal2
      hostsfile=$creds/hosts
      opts=(--ssl-ca-certs="$creds/cert.pem" --password-file="$creds/password"
            --ssl-server-hostname=${certName})
      run=''${XDG_RUNTIME_DIR:-/tmp}
      log=$run/hal2-xpra.log
      export DISPLAY=:0 GDK_BACKEND=x11

      # host or host:port
      url() { case $1 in *:*) echo "quic://$1/" ;; *) echo "quic://$1:${toString port}/" ;; esac; }

      hosts() {
        printf '%s\n' ${pkgs.lib.escapeShellArgs knownHosts}
        [ -f "$hostsfile" ] && cat "$hostsfile"
      }

      # $HAL2_HOST, else the first known host that answers, else a picker
      pick() {
        if [ -n "''${HAL2_HOST:-}" ]; then url "$HAL2_HOST"; return; fi
        local h list=()
        mapfile -t list < <(hosts | grep -v '^\s*$' | awk '!seen[$0]++')
        for h in "''${list[@]}"; do
          if timeout 3 xpra id "$(url "$h")" "''${opts[@]}" >/dev/null 2>&1; then
            url "$h"; return
          fi
        done
        local other="Other..."
        h=$(kdialog --title hal2 --combobox "hal2 is not reachable at the known hosts. Connect to:" \
              "''${list[@]}" "$other" --default "''${list[0]}") || return 1
        if [ "$h" = "$other" ]; then
          h=$(kdialog --title hal2 --inputbox "Host or host:port of hal2 (port ${toString port} by default):" "") || return 1
          [ -n "$h" ] || return 1
          printf '%s\n' "''${list[@]}" | grep -qxF "$h" || echo "$h" >>"$hostsfile"
        fi
        url "$h"
      }

      session=$(pgrep -af "xpra-wrapped attach quic://" | grep -om1 'quic://[^ ]*' || true)
      if [ -z "$session" ]; then
        session=$(pick) || { echo "hal2: no host selected" >&2; exit 1; }
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
