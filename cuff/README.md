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

## Frametop streams charm

The local **Streams** tab controls full displays and individual application windows
exported by Frametop's custom KWin window receiver. Tap the computer name to cycle
through configured hosts and **Refresh** to discover windows. Configured full displays
appear first, labelled **Display · NAME**, followed by windows, with a Connect/Disconnect
button per row. The page grows to show up to eight entries together;
longer lists have **↑ / ↓** controls.

- **Connect** adds a new window panel using the host's existing verified
  pairing, or reconnects a saved panel and clears its hidden flag. With the
  desktop-free session support, it also starts streaming if no Frametop session
  is running.
- The button changes to **Disconnect** when connected. Disconnecting hides the
  panel and stops its stream. It keeps the
  application running on the computer and retains the panel's position and settings.
- Session control is automatic. Connect starts the standalone session when needed,
  without opening KWin or Plasma. Disconnecting the last connected panel across all
  hosts stops that session. Hidden but connected panels still count, and a full
  Frametop desktop is left running. If a session was stopped elsewhere, Connect
  resumes a saved selection.
- Status distinguishes available, disconnected, streaming, retrying, a session
  starting, and stopped streams. If window discovery fails, an error replaces the
  window rows; the configured full displays remain available.
  The charm retries discovery every 15 seconds while open, or when you tap **Refresh**.
  The list returns after a successful refresh; saved panel settings are preserved.

Configure and pair the computer in Frametop Remote Displays first. Discovery works
even if its last panel has been removed, as long as a saved pairing still works.
Full displays come from that computer's saved Frametop displays: add and pair any
additional monitors in Remote Displays, then refresh Cuff. Cuff reuses their saved
client, port, size and stream settings. Two Sunshine displays named Desktop remain
separate entries because they have different saved display IDs.
The host needs the direct window sharing service; ordinary Sunshine monitor
streaming does not provide a window list. On the Frame, both the custom window
receiver and upstream's `ft-layout streams start|stop` support are needed to stream
windows without the desktop. The upstream DEE-340 merge adds desktop-free sessions
but does **not** include the custom window receiver. A plain experimental build
without `list_window_streams` reports this missing capability in the charm.
Older builds with the window receiver still work through the Frametop desktop,
without automatic session startup or shutdown. Frametop's global visibility mode, game pause,
and input settings still apply.

The charm uses the current Frametop release, then `~/frametop`, then `~/dev/frametop`.
For another location, set `frametop` in `~/.config/cuff/charms/frametop.json`, for example:

```json
{"frametop": "/home/steamos/dev/frametop"}
```

Restart Cuff after changing this file. The bridge uses SteamOS's Python and the
selected tree's `ft_layout` API, including its container launcher and paired window
discovery. Network work runs on a worker thread; taps are serialized, and controls
use window identities and saved display IDs rather than list positions.

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
