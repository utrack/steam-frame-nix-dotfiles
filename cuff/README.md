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

## Notifications charm

The **Notices** tab controls `steamvr-notifyd` directly on the headset's user
bus. It includes KDE Connect's forwarded notifications.

- **Do not disturb** hides current popups and silences new ones while keeping
  their history. This includes critical notifications. Turning it off does
  not replay the backlog.
- Unread notifications have blue title buttons and contribute to the tab
  badge. Tap a title to read the full message and mark it read. Long messages
  have previous/next page controls.
- **Mark all read** marks the notifications in the current snapshot.
  **Clear** removes one notification; **Clear all** asks for confirmation
  before removing the saved history and dismissing live popups.
- A **Do not disturb** button is also available in **Settings > Quick**.
  Add it to any quick-row slot; it displays `DND` and lights up when enabled.

The daemon stores the latest 200 notifications and the DND setting across
restarts in `~/.local/state/vr-notifyd/history.ini` (or under `XDG_STATE_HOME`).
It collects notifications even when Cuff is stopped. History starts when the
updated daemon is installed; older discarded notifications are unavailable.

The charm needs the daemon's `org.steamvr.Notifyd1` D-Bus interface. It reports
an unavailable or outdated service in the page and retries automatically.
It never starts another notification daemon.

The flake currently pins a commit on `cuff-notifications` in the local
`~/repos/steamvr-notifyd` Git repository. That checkout is needed when fetching
the input on a fresh Nix store. Once the commit is published, the input URL can
be switched back to GitHub and locked to the published revision.

Preview with `cuff render /tmp/cuff-notifications.png notifications`.
The package build runs control and layout checks. To also exercise the charm
against the real daemon on a private bus, use Cuff's Python environment:

```sh
CUFF_NOTIFYD_TEST_BINARY="$(command -v vr-notifyd)" \
  dbus-run-session -- python -m unittest discover -s cuff/tests -p test_notifications.py -v
```

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
