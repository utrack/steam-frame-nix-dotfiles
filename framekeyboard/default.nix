{ config, lib, pkgs, framekeyboard, ... }:
let
  current = "${framekeyboard.releaseRoot}/current";
  configDir = "${config.xdg.configHome}/framekeyboard";
  unitDir = "${config.xdg.configHome}/systemd/user";
  unitName = "framekeyboard-autostart.service";

  # Match upstream's mutable unit. The application reconciles it on every VR
  # launch and Settings save, and rejects Home Manager's usual store symlink.
  # Activation refreshes its store path on upgrades; the in-app startup toggle
  # can still disable it. Independent native-fallback helpers must outlive it.
  startupUnit = pkgs.writeText unitName ''
    # Managed by Full Keyboard
    [Unit]
    Description=Full Keyboard background replacement
    After=gamescope-session.service steamvr.service
    PartOf=graphical-session.target steamvr.service
    StartLimitIntervalSec=0
    ConditionPathExists=${current}/bin/framekeyboard

    [Service]
    Type=exec
    NotifyAccess=all
    Environment=FRAMEKEYBOARD_SERVICE=${unitName}
    EnvironmentFile=-/usr/share/deckard/mesavars.sh
    ExecStart="${current}/bin/framekeyboard" --vr --input ei --start-enabled --autostart --data-dir "${current}/share/framekeyboard" --config-dir "${configDir}"
    Restart=always
    RestartPreventExitStatus=3
    SuccessExitStatus=3
    RestartSec=3
    RestartSteps=5
    RestartMaxDelaySec=60
    TimeoutStopSec=5
    # Updater and native-fallback helpers must outlive the parent during handoff.
    KillMode=process

    [Install]
    WantedBy=steamvr.service
  '';
  defaults = pkgs.runCommand "framekeyboard-defaults.json" { } ''
    ${pkgs.jq}/bin/jq \
      '.replace_native_keyboard = true | .start_with_steamos = true' \
      ${current}/share/framekeyboard/config/default.json > $out
  '';
in
{
  home.packages = [ framekeyboard ];

  xdg.desktopEntries.framekeyboard = {
    name = "Full Keyboard";
    comment = "Full-size keyboard for Steam Frame dashboard and local apps";
    exec = "${framekeyboard}/bin/framekeyboard";
    icon = "input-keyboard";
    terminal = false;
    categories = [ "Utility" "Accessibility" ];
  };

  home.activation.framekeyboardReplacement =
    lib.hm.dag.entryAfter [ "reloadSystemd" "steamFrameUserServices" ] ''
      (
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.jq ]}:/usr/bin:/bin
        settings=${lib.escapeShellArg "${configDir}/config.json"}
        unit=${lib.escapeShellArg "${unitDir}/${unitName}"}
        wants=${lib.escapeShellArg "${unitDir}/steamvr.service.wants/${unitName}"}
        if [[ -v DRY_RUN ]]; then
          echo "Would configure Full Keyboard replacement and disable Frametop's keyboard service."
          exit 0
        fi

        # Keep preferences writable and preserve choices made in the UI.
        if [[ ! -e "$settings" ]]; then
          install -Dm600 ${defaults} "$settings"
        fi
        if [[ -L "$unit" ]] ||
           { [[ -e "$unit" ]] && ! grep -qx '# Managed by Full Keyboard' "$unit"; }; then
          echo "Refusing to replace a custom $unit" >&2
          exit 1
        fi

        # Both versions use the same instance lock and overlay keys. Its stop
        # hook also kills framekeyboard by name, so stop it before ours starts.
        if systemctl --user cat frametop-keyboard.service >/dev/null 2>&1; then
          systemctl --user disable --now frametop-keyboard.service
        fi

        if jq -e '.replace_native_keyboard == true and .start_with_steamos == true' \
            "$settings" >/dev/null; then
          changed=false
          if ! cmp -s ${startupUnit} "$unit"; then
            install -Dm644 ${startupUnit} "$unit"
            changed=true
          fi
          mkdir -p "$(dirname "$wants")"
          # Upstream requires this exact relative link, not systemctl enable's
          # absolute one.
          ln -sfn ../${unitName} "$wants"
          systemctl --user daemon-reload
          if systemctl --user is-active --quiet steamvr.service; then
            if $changed && systemctl --user is-active --quiet ${unitName}; then
              systemctl --user restart ${unitName}
            else
              systemctl --user start ${unitName}
            fi
          fi
        elif [[ -f "$unit" ]]; then
          systemctl --user stop ${unitName}
          rm -f "$wants" "$unit"
          systemctl --user daemon-reload
        fi
      )
    '';
}
