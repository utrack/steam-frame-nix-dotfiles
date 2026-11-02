# The upstream ARM64 release includes the swipe and dictation engines. Keep
# its layout intact: helpers, engines and profiles are found relative to the
# executable. These binaries deliberately use SteamOS's loader/libraries and
# /opt/steamvr, including the host's GPU drivers and language dictionaries.
{ lib, runCommand, writeShellApplication, release }:
let
  # Startup reconciliation checks the canonical executable's releases/<name>
  # parent and the current symlink. Copy (not symlink) the release so those
  # checks work while the binaries themselves remain immutable.
  releaseRoot = runCommand "framekeyboard-release" { } ''
    mkdir -p $out/releases
    cp -r ${release} $out/releases/0.14.1
    ln -s releases/0.14.1 $out/current
  '';
in
writeShellApplication {
  name = "framekeyboard";
  derivationArgs.passthru = { inherit releaseRoot; };
  text = ''
    # The release's Python helpers and pw-record use the same SteamOS runtime.
    export PATH="/usr/bin:/bin:$PATH"

    # Match upstream's installed launcher; diagnostic/preview arguments stay
    # unchanged, so --check and --preview never enable keyboard input.
    if [[ $# == 0 || ( $# == 1 && $1 == --vr ) ]]; then
      set -- --vr --input ei --start-enabled
      if [[ -n ''${FRAMEKEYBOARD_TARGET_LANGUAGE:-} ]]; then
        set -- "$@" --target-language "$FRAMEKEYBOARD_TARGET_LANGUAGE"
      fi
    fi
    exec ${releaseRoot}/current/bin/framekeyboard \
      --data-dir ${releaseRoot}/current/share/framekeyboard "$@"
  '';

  meta = {
    description = "Full Keyboard for Steam Frame, using the SteamOS runtime";
    homepage = "https://github.com/TaiKeid/steam-frame-full-keyboard";
    # Project code is MIT; the bundled FUTO Swipe model has its own
    # redistributable model-weights license (included in third_party/).
    license = [ lib.licenses.mit lib.licenses.unfreeRedistributable ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "aarch64-linux" ];
    mainProgram = "framekeyboard";
  };
}
