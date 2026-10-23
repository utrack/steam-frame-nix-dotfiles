# Chromium 157 (arm64) built for the Steam Frame: WebXR through OpenXR
# (SteamVR's runtime), hardware video decoding on the Frame's V4L2 decoder
# (Qualcomm iris: H.264, HEVC, VP9). Upstream Chromium has no arm64 Linux
# binaries and nixpkgs' chromium (V4L2 decoding, no OpenXR before 156) fails on
# iris: it's cross-compiled on an x86_64 machine with the patch in
# ~/steamframe-chromium/patches there (build.sh, see its header), no Google
# API keys (no sync or other Google services).
#
# The tarball isn't downloadable; the build fails until it's in the store:
#   nix-store --add-fixed sha256 ~/.local/share/steamframe-chromium/chromium-<version>-arm64.tar.zst
# New build: copy it there, add it, update version and hash.
{ config, lib, pkgs, ... }:
let
  version = "157.0.8103.15";
  hash = "sha256-UvW3QoDAZHjmCu/9tWUU9m6Wya9M8Efu6muitTv3Uwc=";
  tarball = "chromium-${version}-arm64.tar.zst";

  # SteamOS's implicit OpenXR layer (/usr/share/openxr/1/api_layers/implicit.d)
  # names its library without a path, and Nix programs don't search /usr/lib:
  # the OpenXR loader fails xrCreateInstance without it (no immersive-vr).
  xrLayers = pkgs.runCommand "steamos-openxr-layers" { } ''
    mkdir -p $out/lib
    ln -s ${config.targets.hostGpu.libDir}/libVkLayer_VALVE_fdm_injection.so $out/lib/
  '';

  flags = [
    # OpenXR: WebXR; AcceleratedVideoDecode*: V4L2 decoding, frames used
    # in place (NV12 dma-bufs) on ANGLE's OpenGL backend.
    "--enable-features=OpenXR,AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL"
    # ANGLE on OpenGL (Zink on Turnip), not on Vulkan (--use-angle=vulkan,
    # features Vulkan,VulkanFromANGLE,DefaultANGLEVulkan), although Vulkan
    # skips the Zink layer and gives WebGPU an adapter (none on GL): on
    # Vulkan, hardware-decoded frames can't be copied into WebGL textures,
    # which is how WebXR players draw video. texImage2D(video) fails with
    # GL_INVALID_OPERATION and the GPU process logs "Importing textures with
    # external sampling into GL is not possible" (angle_vulkan_image_backing),
    # so video in WebXR stays black; <video> and 2D canvas still work. Check
    # again on updates: a page doing texImage2D(video) + readPixels must get
    # the frame's pixels on Vulkan too.
    "--use-angle=gl"
    # TODO: drop --disable-seccomp-filter-sandbox (syscall filters off in all
    # of Chromium's processes; the namespace sandbox stays) once the XR
    # service's seccomp policy (kXrCompositing, M156+) allows
    # getsockopt(SOL_SOCKET, SO_PEERCRED), or SteamVR's vrclient.so stops
    # calling it. Check: without the flag, --enable-logging=stderr on a WebXR
    # page must not log "seccomp-bpf failure in syscall nr=0xd1", and
    # navigator.xr.isSessionSupported("immersive-vr") must resolve true.
    "--disable-seccomp-filter-sandbox"
  ];

  # nixpkgs' google-chrome for its runtime library and tool paths (rpath,
  # binpath) and wrapper environment; the install is Chromium's own.
  chromium = (pkgs.google-chrome.override { withSymlink = false; }).overrideAttrs (old: {
    pname = "chromium-steamframe";
    inherit version;
    src = pkgs.requireFile {
      name = tarball;
      inherit hash;
      meta.license = lib.licenses.bsd3;  # requireFile's default: unfree
      message = ''
        ${tarball} is built on the x86_64 machine (~/steamframe-chromium/build.sh).
        Copy it to ~/.local/share/steamframe-chromium/ and run
          nix-store --add-fixed sha256 ~/.local/share/steamframe-chromium/${tarball}
      '';
    };
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.zstd ];
    unpackPhase = ''
      runHook preUnpack
      tar --zstd -xf $src
      runHook postUnpack
    '';
    installPhase = ''
      runHook preInstall

      dir=$out/libexec/chromium
      exe=$out/bin/chromium-steamframe
      mkdir -p $out/bin $out/libexec
      cp -a chromium-${version}-arm64 $dir
      mv $dir/icons icons

      # replace bundled vulkan-loader
      rm $dir/libvulkan.so.1
      ln -s ${lib.getLib pkgs.vulkan-loader}/lib/libvulkan.so.1 $dir/

      for elf in $dir/{chrome,chrome-sandbox,chrome_crashpad_handler}; do
        patchelf --set-rpath $rpath --set-interpreter ${pkgs.bintools.dynamicLinker} $elf
      done
      # Chromium's GPU process and the others are chrome again, started with
      # its environment: host-gpu's scrub.so has to leave the host's drivers
      # on LD_LIBRARY_PATH for them, as for a wrapper (see host-gpu/scrub.c).
      touch $dir/.chrome-wrapped

      for s in 24 48 64 128 256; do
        install -Dm644 icons/product_logo_$s.png $out/share/icons/hicolor/''${s}x''${s}/apps/chromium-steamframe.png
      done

      makeWrapper $dir/chrome $exe \
        --prefix LD_LIBRARY_PATH : "$rpath:${lib.makeLibraryPath [ xrLayers pkgs.zlib pkgs.zstd ]}" \
        --prefix PATH            : "$binpath" \
        --suffix PATH            : "${lib.makeBinPath [ pkgs.xdg-utils ]}" \
        --prefix XDG_DATA_DIRS   : "$XDG_ICON_DIRS:$GSETTINGS_SCHEMAS_PATH" \
        --set CHROME_WRAPPER chromium-steamframe \
        --set GOOGLE_API_KEY no \
        --set GOOGLE_DEFAULT_CLIENT_ID no \
        --set GOOGLE_DEFAULT_CLIENT_SECRET no \
        --add-flags ${lib.escapeShellArg (lib.concatStringsSep " " flags)}

      runHook postInstall
    '';
    postInstall = "";
    doInstallCheck = false;
    passthru = { };
    meta = old.meta // {
      description = "Chromium for the Steam Frame (WebXR, V4L2 video decoding)";
      homepage = "https://www.chromium.org/";
      license = lib.licenses.bsd3;
      mainProgram = "chromium-steamframe";
    };
  });
  wrapped = config.lib.hostGpu.wrap chromium;
in {
  home.packages = [ wrapped ];
  xdg.desktopEntries.chromium-steamframe = {
    name = "Chromium";
    genericName = "Web Browser";
    exec = "${wrapped}/bin/chromium-steamframe %U";
    icon = "chromium-steamframe";
    terminal = false;
    categories = [ "Network" "WebBrowser" ];
    mimeType = [ "text/html" "x-scheme-handler/http" "x-scheme-handler/https" ];
    actions.new-incognito = {
      name = "New Incognito Window";
      exec = "${wrapped}/bin/chromium-steamframe --incognito";
    };
  };
}
