{ lib, stdenv, pkg-config, wrapGAppsNoGuiHook, openvr, sdbus-cpp_2, cairo, pango, librsvg, gdk-pixbuf
, systemdLibs, libglvnd, libx11, libuuid }:
stdenv.mkDerivation {
  pname = "vr-notifyd";
  version = "0.1";
  src = ./src;
  nativeBuildInputs = [ pkg-config wrapGAppsNoGuiHook ];
  buildInputs = [ openvr sdbus-cpp_2 systemdLibs cairo pango librsvg gdk-pixbuf libglvnd libx11 libuuid ];
  enableParallelBuilding = true;
  makeFlags = [ "PREFIX=${placeholder "out"}" ];
  meta = {
    description = "Desktop notifications as clickable SteamVR overlays";
    platforms = lib.platforms.linux;
    mainProgram = "vr-notifyd";
  };
}
