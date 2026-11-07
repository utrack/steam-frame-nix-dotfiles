# Cuff

Home Manager installs Cuff v1.3.0 and runs `cuff.service` with SteamVR.
The package includes the bundled charms and local dictation dependencies,
and uses SteamOS's SteamVR, fonts and GPU drivers through `host-gpu`.

Settings stay writable in `~/.config/cuff`, including changes made from the
wrist panel. Local dictation downloads its model into the Hugging Face cache
on first use; `cuff-download-model` downloads it ahead of time (about 650 MB).

The optional recorder, privileged panel capture helper, mpv Flatpak and
Windows companion are separate upstream components and are not installed
by this module.

- Logs: `journalctl --user -u cuff -f`
- Restart: `systemctl --user restart cuff`
- Preview without VR: `cuff render /tmp/cuff.png`
- Update: change the version, revision and source hash in `package.nix`,
  then run `home-manager switch --flake .`.

See <https://github.com/Brobert-in-aus/cuff> for the panel's controls and
optional integrations.

## Frametop windows charm

The local **Windows** tab controls individual application windows exported by
our modified Frametop streamer. Tap the computer name to cycle through configured
hosts and **Refresh** to discover windows. Windows appear as a vertical list,
with one small button per row. The page grows to show up to eight windows together;
longer lists have **↑ / ↓** controls.

- **Connect** adds a new window panel using the host's existing verified
  pairing, or reconnects a saved panel and clears its hidden flag.
- The button changes to **Disconnect** when connected. Disconnecting hides the
  panel and stops its stream. It keeps the
  application running on the computer and retains the panel's position and settings.
- Status distinguishes available, disconnected, streaming, retrying, and a stopped
  Frametop desktop. If the host cannot be reached, an error replaces the window list.
  The charm retries discovery every 15 seconds while open, or when you tap **Refresh**.
  The list returns after a successful refresh; saved panel settings are preserved.

Configure and pair the computer in Frametop Remote Displays first. Discovery works
even if its last panel has been removed, as long as a saved pairing still works.
The host needs the direct window sharing service; ordinary Sunshine monitor
streaming does not provide a window list. Start the Frametop desktop to see panels;
commands issued while it is stopped are saved for its next start. Frametop's global
visibility mode, game pause, and input settings still apply.

The charm uses the current Frametop release, then `~/frametop`, then `~/dev/frametop`.
For another location, set `frametop` in `~/.config/cuff/charms/frametop.json`, for example:

```json
{"frametop": "/home/steamos/dev/frametop"}
```

Restart Cuff after changing this file. The bridge uses SteamOS's Python and the
selected tree's `ft_layout` API, including its container launcher and paired window
discovery. Network work runs on a worker thread; taps are serialized, and controls
use window identities rather than list positions.

The small `expand-pages.patch` lets this charm's widget tree determine the page
height. Cuff's existing overlay anchoring and touch mapping handle the taller page;
other charms keep their usual fixed height.

The charm is bundled by `package.nix`, so Home Manager installs it with Cuff and its
declared command/network permissions. Settings stay writable. Apply an update with
`home-manager switch --flake .` from the repository root; if Cuff wasn't restarted
by activation, run `systemctl --user restart cuff`.

Offline checks run during `nix build .#cuff`. To also check against the local
Frametop layout implementation (temporary files, fake compositor and streamer):

```sh
FRAMETOP_TEST_ROOT=/home/steamos/frametop \
  python -m unittest discover -s cuff/tests -v
```

Use Cuff's Python environment for that command (`cuff` and Pillow must be importable).
`cuff render /tmp/cuff-windows.png frametop` previews the wrist page without VR.
For a headset check, browse a paired computer, connect a window, disconnect it,
and reconnect it: the panel should return to its prior position while its host
application stays open.
