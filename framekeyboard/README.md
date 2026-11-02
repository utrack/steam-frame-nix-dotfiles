# Full Keyboard

Home Manager installs **Full Keyboard** in the application menu and
`framekeyboard` on PATH. It starts hidden with SteamVR and replaces Steam's
keyboard for supported local-app and Steam text fields. Launch it from the
menu or a terminal to show it manually.

Activation initializes replacement and startup on the first install, then
preserves preferences and custom profiles in `~/.config/framekeyboard/`.
Settings → Integration can disable either option. Settings → Quit Full
Keyboard restores Steam's keyboard until the next SteamVR start.

Frametop's bundled Full Keyboard service is disabled: it shares the same
instance lock and overlay keys, so the two versions cannot run together.
Frametop falls back to its older desktop keyboard. The standalone version
does not have Frametop's desktop typing or hand-touch integration.

The `framekeyboard-release` flake input pins upstream's complete ARM64 release,
including swipe typing, language engines and dictation. Its extracted contents
are verified by the hash in `flake.lock` and kept in the Nix store. A versioned
release directory and `current` symlink satisfy upstream's startup checks.
The launcher
uses SteamOS's libraries, GPU drivers, Python, PipeWire tools, language
dictionaries and `/opt/steamvr`; this package is specifically for Steam Frame,
not other aarch64 Linux systems.

Build and activate from the repository root:

```sh
nix build .#framekeyboard
home-manager switch --flake .#steamos
framekeyboard --version
framekeyboard --check
```

To update, change the release tag and archive filename in `flake.nix` and the
release directory version in `package.nix`, run `nix flake lock`, then run the
Home Manager switch above. Roll back through
Home Manager generations. Use Nix for updates; the app's built-in updater
cannot write to the Nix store.

Home Manager activation installs and refreshes
`~/.config/systemd/user/framekeyboard-autostart.service` as a regular file:
Full Keyboard reconciles it on launch and Settings saves, and rejects a
symlink into the Nix store. Its startup toggle manages the enablement link.
Inspect it with `systemctl --user status framekeyboard-autostart.service`.

Before removing this module, turn off Start with SteamOS and Apply and save,
or stop and disable the service and remove its unit file. To restore Frametop's
keyboard afterward, run
`systemctl --user enable --now frametop-keyboard.service`.

To check replacement in the headset, press Steam's normal keyboard button,
then try harmless text in Steam search and a local app. Close the keyboard
with × and summon it again: × hides it without quitting. Settings → Use Steam
keyboard restores the stock keyboard for the current request.
