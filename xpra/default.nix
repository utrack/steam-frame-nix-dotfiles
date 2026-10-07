# Apps on hal2 as floating VR windows, through xpra over QUIC (udp/14500).
#
# The session (:100) runs on hal2 as the systemd user service xpra-hal2; the client checks
# hal2's self-signed certificate and authenticates with the files in ~/.config/xpra/hal2.
# The session ends with its last window (--exit-with-windows, which disconnects the client for
# good) and the service starts a fresh one for the next `hal2 <command>`.
#
#   hal2 <command> [args...]   runs the command in hal2's xpra session (:100),
#                              starting the local client as needed
#   hal2-vicinae               toggles a vicinae instance of its own in that session
#
# The client connects to the first of knownHosts and ~/.config/xpra/hal2/hosts that answers,
# or asks for a host (kdialog) when none does; HAL2_HOST=<host[:port]> skips both. It reconnects
# whenever the connection drops (giving up after giveUpSeconds without any host), asks again
# when a `hal2 <command>` comes while no host answers, and switches to a host earlier in the
# list as soon as that one answers. "Disconnect" in xpra's tray menu ends it for good, until the
# next `hal2`. `hal2 <command>` reports its failures with kdialog.
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
  giveUpSeconds = 300;
  # how long the client waits for an unresponsive hal2 before reconnecting
  pingTimeoutSeconds = 10;

  common = ''
    creds=$HOME/.config/xpra/hal2
    opts=(--ssl-ca-certs="$creds/cert.pem" --password-file="$creds/password"
          --ssl-server-hostname=${certName})
    run=''${XDG_RUNTIME_DIR:-/tmp}
    lock=$run/hal2-xpra.lock
    # URL of the current connection, written by hal2-client
    sessionfile=$run/hal2-xpra.session
    # created by hal2 to have a waiting hal2-client ask for a host again
    askfile=$run/hal2-xpra.ask
    export DISPLAY=:0 GDK_BACKEND=x11
  '';

  # keeps one client attached to the best reachable host, for as long as it holds $lock
  hal2-client = pkgs.writeShellApplication {
    name = "hal2-client";
    runtimeInputs = [ xpra pkgs.procps pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.util-linux ];
    text = ''
      ${common}
      hostsfile=$creds/hosts
      exec 9>"$lock"
      flock -n 9 || exit 0
      rm -f "$askfile"
      trap 'rm -f "$sessionfile" "$askfile"' EXIT
      # a client started without hal2-client would show every window a second time
      pkill -f "xpra-wrapped attach quic://" || true

      # host or host:port
      url() { case $1 in *:*) echo "quic://$1/" ;; *) echo "quic://$1:${toString port}/" ;; esac; }
      probe() { timeout 3 xpra id "$(url "$1")" "''${opts[@]}" >/dev/null 2>&1; }

      ask() {
        local h other="Other..."
        h=$(kdialog --title hal2 --combobox "hal2 is not reachable at the known hosts. Connect to:" \
              "''${list[@]}" "$other" --default "''${list[0]}") || return 1
        if [ "$h" = "$other" ]; then
          h=$(kdialog --title hal2 --inputbox "Host or host:port of hal2 (port ${toString port} by default):" "") || return 1
          [ -n "$h" ] || return 1
          printf '%s\n' "''${list[@]}" | grep -qxF "$h" || echo "$h" >>"$hostsfile"
        fi
        echo "$h"
      }

      first=1
      lost=$(date +%s)
      while :; do
        mapfile -t list < <({ printf '%s\n' ${pkgs.lib.escapeShellArgs knownHosts}
                              cat "$hostsfile" 2>/dev/null || true; } | grep -v '^\s*$' | awk '!seen[$0]++')
        [ -n "''${HAL2_HOST:-}" ] && list=("$HAL2_HOST")
        host=""
        for h in "''${list[@]}"; do probe "$h" && { host=$h; break; }; done
        # the first attempt asks; reconnects wait for a known host instead, unless hal2 has a
        # command waiting
        if [ -z "$host" ] && { [ "$first" = 1 ] || [ -e "$askfile" ]; }; then
          rm -f "$askfile"
          host=$(ask) || { echo "hal2-client: host picker cancelled"; exit 1; }
          lost=$(date +%s)
        fi
        first=0
        if [ -z "$host" ]; then
          if (( $(date +%s) - lost > ${toString giveUpSeconds} )); then
            echo "hal2-client: no host reachable for ${toString giveUpSeconds}s, giving up"; exit 1
          fi
          sleep 5; continue
        fi

        rm -f "$askfile"
        echo "hal2-client: connecting to $host"
        url "$host" >"$sessionfile"
        # a dead link only ends the client after XPRA_PING_TIMEOUT (60 s by default), with frozen
        # windows meanwhile
        XPRA_PING_TIMEOUT=${toString pingTimeoutSeconds} \
          xpra attach "$(url "$host")" "''${opts[@]}" --reconnect=no 9>&- &
        client=$!
        better=()
        for h in "''${list[@]}"; do [ "$h" = "$host" ] && break; better+=("$h"); done
        t=0
        while kill -0 "$client" 2>/dev/null; do
          sleep 1
          (( ++t % 15 )) && continue
          for h in "''${better[@]}"; do
            if probe "$h"; then echo "hal2-client: $h answers, switching"; kill "$client"; break; fi
          done
        done
        status=0
        wait "$client" || status=$?
        rm -f "$sessionfile"
        # 0: "Disconnect" in the tray menu, or hal2's session ended
        [ "$status" = 0 ] && exit 0
        echo "hal2-client: client exited with $status, reconnecting"
        lost=$(date +%s)
      done
    '';
  };

  hal2 = pkgs.writeShellApplication {
    name = "hal2";
    runtimeInputs = [ xpra hal2-client pkgs.coreutils pkgs.gnugrep pkgs.util-linux ];
    text = ''
      ${common}
      log=$run/hal2-xpra.log
      running() { ! flock -n "$lock" true; }
      if running; then
        # a client waiting for a host to come back would never pick up this command
        [ $# -gt 0 ] && [ ! -s "$sessionfile" ] && touch "$askfile"
      else
        setsid hal2-client >"$log" 2>&1 &
      fi

      [ $# -eq 0 ] && exit 0
      sleep 1
      # the first connection may wait for the host picker
      for _ in $(seq 120); do
        running || break
        session=$(cat "$sessionfile" 2>/dev/null || true)
        [ -n "$session" ] && xpra control "$session" "''${opts[@]}" start -- "$@" >/dev/null 2>&1 && exit 0
        sleep 1
      done
      reason=$(grep '^hal2-client:' "$log" 2>/dev/null | tail -n 1 || true)
      msg="hal2: could not start '$*' in hal2's session''${reason:+ ($reason)}, see $log"
      echo "$msg" >&2
      # nothing to report when the picker was cancelled on purpose
      case $reason in *"picker cancelled") ;; *) kdialog --title hal2 --error "$msg" >/dev/null 2>&1 & ;; esac
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

  # client settings (the hal2 credentials stay in ~/.config/xpra/hal2, outside this repo)
  xdg.configFile."xpra/xpra.conf".text = ''
    sharing=yes
    desktop-scaling=off
    dpi=192
    # paint with the GPU (Zink on Turnip, through hostGpu.wrap)
    opengl=yes
    # H.264 for moving content: `auto` with a high min-quality picked full-frame WebP, with
    # ~120 ms of encoding latency per 1080p frame on hal2
    encoding=h264
    min-quality=50
    min-speed=0
    # no audio/video lip-sync: hal2 delayed every frame by xpra's estimated audio latency
    # (~275 ms, from hard-coded guesses)
    av-sync=no
  '';

  xdg.desktopEntries.hal2-vicinae = {
    name = "Vicinae (hal2)";
    comment = "Vicinae launcher on hal2";
    exec = "${hal2-vicinae}/bin/hal2-vicinae";
    icon = "system-search";
    terminal = false;
  };
}
