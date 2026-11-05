{ lib, stdenvNoCC, fetchFromGitHub, fetchPypi, makeWrapper, python3, noto-fonts
, procps, pulseaudio, pipewire, iproute2, iw, iputils, systemd, libuuid
}:
let
  # Cuff redirects pyopenvr's library loader to SteamVR's ARM64 library.
  # Upstream's Python package otherwise ships only x86 OpenVR binaries.
  openvr = python3.pkgs.buildPythonPackage {
    pname = "openvr";
    version = "2.12.1401";
    pyproject = true;
    src = fetchPypi {
      pname = "openvr";
      version = "2.12.1401";
      hash = "sha256-JFr6ywCLZvELw46rH0gGz2NKcEAMSguvNJKV9hfQ9t8=";
    };
    build-system = [ python3.pkgs.setuptools ];
    postInstall = ''
      find "$out" -type f \( -name '*.so' -o -name '*.dll' -o -name '*.dylib' \) -delete
    '';
    # Importing openvr needs the host's SteamVR, outside the build sandbox.
    doCheck = false;
  };
  python = python3.withPackages (ps: [
    openvr
    ps.pillow
    ps.dbus-python
    ps.onnx-asr
  ] ++ ps.onnx-asr.optional-dependencies.hub);
  runtimePath = lib.makeBinPath [
    procps pulseaudio pipewire iproute2 iw iputils systemd
  ];
in
stdenvNoCC.mkDerivation {
  pname = "cuff";
  version = "1.3.0";

  src = fetchFromGitHub {
    owner = "Brobert-in-aus";
    repo = "cuff";
    rev = "6bdf21eb980556cb4a71342a58fac6d920b8cf77"; # v1.3.0
    hash = "sha256-3q6gJHkq0o0koQf+TL0p6PFFl7EVr6HGMDYqYiPvt+8=";
  };

  nativeBuildInputs = [ makeWrapper ];
  patches = [ ./expand-pages.patch ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    # The sandbox has no SteamOS fonts. Supply Noto Sans for the widget checks.
    mkdir test-fonts
    for weight in Regular Medium Bold; do
      ln -s ${noto-fonts}/share/fonts/noto/NotoSans.ttf "test-fonts/NotoSans-$weight.ttf"
    done
    cat > test-config.toml <<EOF
    [profile]
    font_dir = "$PWD/test-fonts"
    EOF
    CUFF_CONFIG="$PWD/test-config.toml" CUFF_FRAMETOP_SOURCE=${./charms/frametop} \
      PYTHONPATH="$PWD" ${python}/bin/python -m unittest discover -s ${./tests} -v
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/cuff" "$out/bin"
    # Charms and assets are resolved relative to the Python sources.
    cp -r cuff charms VERSION "$out/share/cuff/"
    cp -r ${./charms/frametop} "$out/share/cuff/charms/frametop"
    # Invoke the interpreter directly: python.withPackages' extra binary
    # wrapper would make host-gpu scrub the driver paths before Python runs.
    makeWrapper ${python3.interpreter} "$out/bin/cuff" \
      --prefix PYTHONPATH : "$out/share/cuff:${python}/${python3.sitePackages}" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libuuid ]}" \
      --prefix PATH : "${runtimePath}" \
      --add-flags "-m cuff"
    makeWrapper ${python3.interpreter} "$out/bin/cuff-download-model" \
      --prefix PYTHONPATH : "$out/share/cuff:${python}/${python3.sitePackages}" \
      --add-flags "-m cuff.stt_local --download"
    runHook postInstall
  '';

  meta = {
    description = "Steam Frame wrist panel with status, quick actions and charms";
    homepage = "https://github.com/Brobert-in-aus/cuff";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "cuff";
  };
}
