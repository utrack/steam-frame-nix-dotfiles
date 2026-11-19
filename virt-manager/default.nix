# virt-manager for remote libvirt hosts (no local libvirtd): File > Add Connection, e.g.
# QEMU/KVM over SSH, qemu+ssh://user@host/system. Connections are kept in dconf.
#
# libvirt runs SteamOS's ssh (~/.ssh/config, keys, known_hosts). It has no terminal here, so
# host key confirmations and passwords go through ksshaskpass (SteamOS ships no askpass).
# The remote side needs virt-ssh-helper (libvirt >= 9) or nc.
{ config, lib, pkgs, ... }:
let
  askpass = config.lib.hostGpu.wrap pkgs.kdePackages.ksshaskpass;
  virt-manager = config.lib.hostGpu.wrap (pkgs.virt-manager.overrideAttrs (old: {
    preFixup = old.preFixup + ''
      gappsWrapperArgs+=(--set-default SSH_ASKPASS ${askpass}/bin/ksshaskpass
                         --set-default SSH_ASKPASS_REQUIRE prefer)
    '';
  }));
in {
  home.packages = [ virt-manager ];

  # in ~/.local/share/applications with absolute paths (the Frametop desktop's
  # XDG_DATA_DIRS may not include the Nix profile)
  xdg.dataFile."applications/virt-manager.desktop".source =
    pkgs.runCommand "virt-manager-launcher" { } ''
      sed -e 's|^Exec=virt-manager|Exec=${virt-manager}/bin/virt-manager|' \
        -e 's|^Icon=.*|Icon=${virt-manager}/share/icons/hicolor/256x256/apps/virt-manager.png|' \
        ${virt-manager}/share/applications/virt-manager.desktop > $out
    '';
}
