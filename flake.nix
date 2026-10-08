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
  };

  outputs = { nixpkgs, nixpkgs-flatpak, home-manager, steam-frame-nix, steamvr-notifyd, ... }:
  let
    # Filled in by install.sh; the defaults match the Steam Frame.
    username = "steamos";
    homeDirectory = "/home/steamos";
    # Steam Frame: "aarch64-linux". Steam Deck: "x86_64-linux".
    system = "aarch64-linux";
  in {
    homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.${system};
      extraSpecialArgs = {
        inherit username homeDirectory;
        pkgsFlatpak = nixpkgs-flatpak.legacyPackages.${system};
      };
      modules = [
        steam-frame-nix.homeManagerModules.default
        steamvr-notifyd.homeManagerModules.default
        ./home.nix
      ];
    };
  };
}
