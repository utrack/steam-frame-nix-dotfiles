{ config, pkgs, ... }:
let
  cuff = config.lib.hostGpu.wrap (pkgs.callPackage ./package.nix { });
in {
  home.packages = [ cuff ];

  systemd.user.services.cuff = {
    Unit = {
      Description = "Cuff (SteamVR wrist panel)";
      After = [ "graphical-session.target" "steamvr.service" ];
      PartOf = [ "steamvr.service" ];
    };
    Service = {
      ExecStart = "${cuff}/bin/cuff";
      Environment = [
        "PYTHONUNBUFFERED=1"
        "PATH=${config.home.profileDirectory}/bin:/usr/local/bin:/usr/bin:/bin"
      ];
      EnvironmentFile = "-/usr/share/deckard/mesavars.sh";
      Restart = "always";
      RestartSec = 10;
    };
    Install.WantedBy = [ "steamvr.service" ];
  };
}
