# Google Chrome Beta (arm64) with WebXR through OpenXR (SteamVR's runtime, see
# ~/.config/openxr/1/active_runtime.json). nixpkgs packages only the stable
# channel, which has no OpenXR WebXR yet: its google-chrome is built from the
# beta .deb instead. Some WebXR/WebGPU apps need flags in chrome://flags too.
#
# Updates by hand: Version and SHA256 of google-chrome-beta in
# https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-arm64/Packages
# (`nix hash convert --hash-algo sha256 --to sri HEX` for the hash).
{ config, pkgs, ... }:
let
  version = "157.0.8103.15";
  hash = "sha256-w+oMsfVzh4J8YYFHRHuAvmI4h+DxUHsvfnZADsZgk7M=";

  # SteamOS's implicit OpenXR layer (/usr/share/openxr/1/api_layers/implicit.d)
  # names its library without a path, and Nix programs don't search /usr/lib:
  # the OpenXR loader fails xrCreateInstance without it (no immersive-vr).
  xrLayers = pkgs.runCommand "steamos-openxr-layers" { } ''
    mkdir -p $out/lib
    ln -s ${config.targets.hostGpu.libDir}/libVkLayer_VALVE_fdm_injection.so $out/lib/
  '';

  chrome-beta = (pkgs.google-chrome.override {
    # TODO: drop --disable-seccomp-filter-sandbox (syscall filters off in all of
    # Chrome's processes; the namespace sandbox stays) once Chrome's XR service
    # seccomp policy (kXrCompositing, M156+) allows getsockopt(SOL_SOCKET,
    # SO_PEERCRED), or SteamVR's vrclient.so stops calling it. Check: without
    # the flag, chrome --enable-logging=stderr on a WebXR page must not log
    # "seccomp-bpf failure in syscall nr=0xd1", and
    # navigator.xr.isSessionSupported("immersive-vr") must resolve true.
    # ANGLE on Vulkan (Turnip) rather than OpenGL through Zink: one translation
    # layer less, and WebGPU gets an adapter (none on the GL backend).
    commandLineArgs = builtins.concatStringsSep " " [
      "--enable-features=OpenXR,Vulkan,VulkanFromANGLE,DefaultANGLEVulkan"
      "--use-angle=vulkan"
      "--disable-seccomp-filter-sandbox"
    ];
    withSymlink = false;
  }).overrideAttrs (old: {
    pname = "google-chrome-beta";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-beta/google-chrome-beta_${version}-1_arm64.deb";
      inherit hash;
    };
    installPhase = builtins.replaceStrings
      [ "appname=chrome\n" "dist=stable\n" "com.google.Chrome.desktop" ]
      [ "appname=chrome-beta\n" "dist=beta\n" "com.google.Chrome.beta.desktop" ]
      old.installPhase;
    # Chrome's GPU process and the others are chrome again, started with its
    # environment: host-gpu's scrub.so has to leave the host's drivers on
    # LD_LIBRARY_PATH for them, as for a wrapper (see host-gpu/scrub.c).
    postInstall = (old.postInstall or "") + ''
      touch $out/share/google/chrome-beta/.chrome-wrapped
      wrapProgram $out/bin/google-chrome-beta --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ xrLayers pkgs.zlib pkgs.zstd ]}
    '';
    meta = old.meta // { mainProgram = "google-chrome-beta"; };
  });
in {
  home.packages = [ (config.lib.hostGpu.wrap chrome-beta) ];
}
