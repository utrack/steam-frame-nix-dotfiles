{
  description = "Home Manager configuration for SteamOS (Steam Frame / Steam Deck)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # For libraries loaded inside Flatpaks (firefox-hwdec): glibc no newer
    # than the Flatpak runtime's (org.freedesktop.Platform 25.08: 2.42).
    nixpkgs-flatpak.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Steam Frame fixes (steamFrame.* options).
    steam-frame-nix = {
      url = "github:lhns/steam-frame-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Desktop notifications as clickable panels in VR (services.steamvr-notifyd).
    steamvr-notifyd = {
      url = "github:utrack/steamvr-notifyd";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Full Keyboard's complete Steam Frame release (upstream has no flake).
    framekeyboard-release = {
      url = "https://github.com/TaiKeid/steam-frame-full-keyboard/releases/download/0.14.1/framekeyboard-0.14.1-aarch64.tar.gz";
      flake = false;
    };
  };

  outputs = { nixpkgs, nixpkgs-flatpak, home-manager, steam-frame-nix, steamvr-notifyd, framekeyboard-release, ... }:
  let
    # Filled in by install.sh; the defaults match the Steam Frame.
    username = "steamos";
    homeDirectory = "/home/steamos";
    # Steam Frame: "aarch64-linux". Steam Deck: "x86_64-linux".
    system = "aarch64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = pkg:
        builtins.elem (nixpkgs.lib.getName pkg) [ "framekeyboard" ];
    };
    framekeyboard = pkgs.callPackage ./framekeyboard/package.nix {
      release = framekeyboard-release;
    };
    # Frametop owns the dashboard debugger on loopback port 8089. Upstream
    # hardcodes 8087 in its patches, relays and restart check; that port is
    # also forwarded to the LAN by SteamOS. Keep all clients on Frametop's
    # existing port without changing SteamVR's settings or exposing it.
    steamFrameSource = pkgs.applyPatches {
      name = "steam-frame-nix-frametop";
      src = steam-frame-nix;
      postPatch = ''
        grep -rlZ '8087' modules install.sh |
          xargs -0 sed -i 's/8087/8089/g'
        substituteInPlace modules/cleanup/check.nix \
          --replace-fail '0100007F:1F97' '0100007F:1F99'
      '';
    };
    steamFrameModules = ((import "${steamFrameSource}/flake.nix").outputs
      (steam-frame-nix.inputs // { self = steam-frame-nix; })).homeManagerModules.default;
  in {
    packages.${system} = {
      inherit framekeyboard;
      cuff = pkgs.callPackage ./cuff/package.nix { };
    };
    checks.${system}.steam-frame-cleanup =
      import "${steamFrameSource}/modules/cleanup/check.nix" { inherit pkgs; };

    homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inherit username homeDirectory framekeyboard;
        pkgsFlatpak = nixpkgs-flatpak.legacyPackages.${system};
      };
      modules = [
        steamFrameModules
        steamvr-notifyd.homeManagerModules.default
        ./home.nix
      ];
    };
  };
}
