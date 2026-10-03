# Nix GUI apps on the host's own GPU drivers, without Nix's Mesa or root.
#
#   home.packages = [ (config.lib.hostGpu.wrap pkgs.someApp) ];
#
# The wrapped package's programs start through run.sh, which points them at
# the host's Mesa (see there). Desktop files and D-Bus services that name the
# package's programs by path are pointed at the wrappers.
{ config, lib, pkgs, ... }:
let
  cfg = config.targets.hostGpu;

  scrub = pkgs.runCommandCC "host-gpu-scrub" { } ''
    mkdir -p $out/lib
    $CC -O2 -shared -fPIC -o $out/lib/libhost-gpu-scrub.so ${./scrub.c}
  '';

  run = pkgs.writeShellScript "host-gpu-run" (''
    tools=${pkgs.symlinkJoin { name = "host-gpu-tools"; paths = with pkgs; [ coreutils gawk gnused ]; }}
    host_lib=${lib.escapeShellArg cfg.libDir}
    icd_dir=${lib.escapeShellArg cfg.vulkanIcdDir}
    nix_glibc=${pkgs.stdenv.cc.libc.version}
    scrub=${scrub}/lib/libhost-gpu-scrub.so
  '' + builtins.readFile ./run.sh);

  # name, file: every library in the package's closure
  index = pkg: pkgs.runCommand "${pkg.name}-host-gpu-index" {
    closure = pkgs.closureInfo { rootPaths = [ pkg ]; };
  } ''
    while read -r p; do
      for f in "$p"/lib/*.so.*; do
        if [ -f "$f" ]; then printf '%s\t%s\n' "''${f##*/}" "$(readlink -f "$f")"; fi
      done
    done < "$closure/store-paths" > $out
  '';

  wrap = pkg: pkgs.symlinkJoin {
    name = "${pkg.name}-host-gpu";
    paths = [ pkg ];
    passthru.unwrapped = pkg;
    postBuild = ''
      for f in ${pkg}/bin/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        w=$out/bin/''${f##*/}
        rm "$w"
        printf '#!%s\nexec %s %s %s "$@"\n' ${pkgs.runtimeShell} ${run} ${index pkg} "$f" > "$w"
        chmod +x "$w"
      done
      for f in $out/share/applications/*.desktop $out/share/dbus-1/services/*.service \
          $out/etc/xdg/autostart/*.desktop $out/share/systemd/user/*.service; do
        [ -L "$f" ] && grep -q ${pkg}/bin "$f" || continue
        sed "s|${pkg}/bin|$out/bin|g" "$(readlink -f "$f")" > "$f.new"
        mv "$f.new" "$f"
      done
    '';
  };
in {
  options.targets.hostGpu = {
    libDir = lib.mkOption {
      type = lib.types.str;
      default = "/usr/lib";
      description = "Where the host's Mesa (libEGL_mesa.so.0, libgallium) lives.";
    };
    vulkanIcdDir = lib.mkOption {
      type = lib.types.str;
      default = "/usr/share/vulkan/icd.d";
      description = "The host's Vulkan driver manifests.";
    };
  };

  config.lib.hostGpu = { inherit wrap; };
}
