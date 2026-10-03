# FFmpeg for the Firefox Flatpak on the Frame's V4L2 decoder (qcom-iris).
#
# Firefox's V4L2 path needs DMA-BUF (DRM_PRIME) frames, which upstream
# FFmpeg's *_v4l2m2m decoders don't return (Mozilla bug 1852765).
# Raspberry Pi's fork does; it's FFmpeg 7.1 (libavcodec.so.61), the version
# of the Flatpak runtime (org.freedesktop.Platform 25.08), so Firefox loads
# it in place of the runtime's. iris.patch, two fixes for Iris:
# - placeholder size when the bitstream format is set with 0x0: the 6.18
#   kernel fails VIDIOC_REQBUFS otherwise (fixed in Linux 7.0, 4980721cb97d;
#   then a no-op). From rpi-ffmpeg issue #103.
# - no EOS event at the end of a stream: ENOENT is EOF, not a decode error
#   (which made Firefox switch to software on every seek).
#
# The libraries run inside the Flatpak, against its runtime's glibc and
# libdrm, so this is built with a nixpkgs whose glibc isn't newer than the
# runtime's (pkgsFlatpak, flake.nix), and without external libraries
# (FFmpeg's native codecs only).
{ lib, stdenv, fetchFromGitHub, pkg-config, libdrm
, runtimeGlibc ? "2.42"   # org.freedesktop.Platform 25.08
}:
assert lib.assertMsg (lib.versionAtLeast runtimeGlibc stdenv.cc.libc.version)
  "rpi-ffmpeg: glibc ${stdenv.cc.libc.version} is newer than the Flatpak runtime's ${runtimeGlibc}";
stdenv.mkDerivation {
  pname = "rpi-ffmpeg";
  version = "7.1.5-950ab03";

  src = fetchFromGitHub {
    owner = "jc-kynesim";
    repo = "rpi-ffmpeg";
    rev = "950ab0323334111e1a4cdc6b037eadfaf0524167";   # branch test/7.1.5/main
    hash = "sha256-lPsx9TnSsEkmN+E0OcOrvPkseXY7xFUEtOP3EJiP9B0=";
  };
  patches = [ ./iris.patch ];
  postPatch = "patchShebangs .";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libdrm ];   # headers; the runtime's libdrm.so.2 at run time

  configurePlatforms = [ ];
  setOutputFlags = false;
  configureFlags = [
    "--enable-shared" "--disable-static" "--disable-programs" "--disable-doc"
    "--disable-autodetect" "--enable-pthreads" "--enable-libdrm" "--enable-v4l2-m2m"
    "--disable-v4l2-request" "--disable-libudev" "--disable-mmal"
    "--disable-vout-drm" "--disable-vout-egl" "--disable-epoxy"
  ];
  enableParallelBuilding = true;

  postInstall = "rm -r $out/include $out/share $out/lib/pkgconfig";

  meta.platforms = [ "aarch64-linux" ];
}
