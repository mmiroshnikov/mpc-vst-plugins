# Optional: hwremap, remap the hardware buttons (MPC Live, Force)

![MPC Live with hwremap: Pad Bank A–D open the top row of the Mode Menu, + and − open the second row](https://raw.githubusercontent.com/mmiroshnikov/akai_standalone_remap/9d2aa57a570b0c4788f88b04ca242bb82176c380/docs/mpc-live-remapped.jpg)

Open any screen from any button, and add double taps, long presses and Shift layers. The devices have no setting for this, so `hwremap.so` is a small library MPC loads when it starts (`LD_PRELOAD`). It rewrites the controller's MIDI: a press of a chosen button is swallowed and replaced with other buttons, pads or a touchscreen tap, which MPC cannot tell from your own presses. Source, the full rules reference and the hand-made install: [mmiroshnikov/akai_standalone_remap](https://github.com/mmiroshnikov/akai_standalone_remap) (MIT).

**Not part of any plugin release.** `hwremap-patch.sh` is a standalone script you run on the device yourself, if you want it. The installer app lists it in its read-only "Advanced: device patches" step.

Tested by its author on a first-generation MPC Live (Hakai, MPC 3.9.1) and a Force (stock firmware 3.9.0). This script, which installs it, has been tested offline only (see Files and tests).

## What the buttons do

The script installs one of these rule sets as `/sdcard/hwremap.conf`, picked from the controller's name (`--device` overrides it). Hold **Shift** for a button's original function.

MPC Live (`--device mpc-live`). Holding Menu and tapping a pad opens the icon in that cell of the 4×4 Mode Menu, so each button opens whatever icon you put in its cell; rearrange the Mode Menu to choose:

| Button        | Opens (Mode Menu cell) |
|---------------|------------------------|
| Pad Bank A–D  | top row, icons 1–4     |
| `+` / `+` twice | second row, icon 1 / icon 3 |
| `−` / `−` twice | second row, icon 2 / icon 4 |

Pad banks are not reachable while the rules are on (Shift + Pad Bank still gives banks E–H).

Force (`--device force`): Mixer twice = Master; Menu twice = Main Mode; Knobs short = Shift + Knobs, long = plain Knobs, twice = the original long press.

Other devices (`--device none`, the default when the controller is neither): a rules file with no rules, so every button works as usual until you write some. Other models have other button numbers; the [rules reference](https://github.com/mmiroshnikov/akai_standalone_remap#config-reference) says how to find them (`log 1`).

The file is re-read whenever it changes: edit it over SSH and the next button press uses it, no restart. An existing `/sdcard/hwremap.conf` is never overwritten, and uninstall leaves it.

## Use
Copy it to the device and run it as root:
```
scp tools/mpc_patch/hwremap/hwremap-patch.sh root@<device-ip>:/tmp/
ssh root@<device-ip>
sh /tmp/hwremap-patch.sh status        # changes nothing
sh /tmp/hwremap-patch.sh install       # asks you to type PATCH; MPC restarts
sh /tmp/hwremap-patch.sh uninstall     # asks you to type REMOVE; MPC restarts
```
Save your project first: MPC restarts after install and uninstall (`--no-restart` leaves that to you). `status` then says **patched** once MPC has loaded the library, or **partial** if MPC has not restarted yet or a firmware update took the library out of `LD_PRELOAD` (run `install` again).

## What it changes
- `/data/hwremap/`: `hwremap.so` and the patch's state (`VERSION`, `MODE`).
- `/sdcard/hwremap.conf`: the rules, only if there is none.
- MPC's `LD_PRELOAD`, one of two ways:
  - **Hakai MPC:** the launcher `/usr/bin/az01-launch-MPC` sets `LD_PRELOAD` itself (so systemd's is ignored). `hwremap.so` is added after `customBufferSizeMPC.so` on each of its `LD_PRELOAD` lines; the root filesystem is remounted writable for that and restored. A launcher that sets `LD_PRELOAD` some other way is refused.
  - **Elsewhere:** the systemd drop-in shared with the MPC addins (`90-mpc-addins.conf`), written with the addins' own `addin-lib.sh` (embedded), so the firmware's libraries and installed addins stay in the list (see `docs/ADDINS.md`).
- A backup of the launcher and MPC's unit as they were goes to `/data/mpc-vst-plugins/backups/hwremap-*` (small: no projects).

`uninstall` takes `hwremap.so` out of `LD_PRELOAD` (only that entry, in whichever place it was added) and deletes `/data/hwremap/`.

An install made by hand from the akai_standalone_remap README (`/usr/lib/hwremap.so`, or a `hwremap.conf` drop-in) is detected: `status` says so and `install` refuses until it is removed as that README says.

## If MPC does not start
SSH stays up. `sh /tmp/hwremap-patch.sh uninstall` puts everything back. By hand:
1. `systemctl stop acvs`.
2. Hakai MPC: `mount -o remount,rw /`, delete ` /data/hwremap/hwremap.so` from the `LD_PRELOAD` lines of `/usr/bin/az01-launch-MPC` (the backup in `/data/mpc-vst-plugins/backups/hwremap-*` is the file as it was), `mount -o remount,ro /`. Elsewhere: take `/data/hwremap/hwremap.so` out of `/etc/systemd/system/acvs.service.d/90-mpc-addins.conf` (`docs/ADDINS.md`, "When an addin stops MPC from starting"), then `systemctl daemon-reload`.
3. `systemctl start acvs`.

To switch the remapping off without uninstalling, empty `/sdcard/hwremap.conf`: with no rules everything passes through.

## Known limits
- Nothing tells hwremap which screen is showing, so a button cannot toggle between two screens.
- Touch taps (the Force's Main Mode rule) use fixed screen coordinates and break if the icon moves.
- On MPC Live no button note opens Clip Matrix or Clip Editor directly; they are reached through the Mode Menu.

## Files and tests
`src/` holds the two rule sets. `build_script.py <hwremap.so>` writes `hwremap-patch.sh` from `script.template.sh`, `src/`, `tools/release/addin/addin-lib.sh` and a `hwremap.so` built by akai_standalone_remap's `./build.sh` at the commit named in the script (the build is reproducible; the script checks the md5). `tools/test_hwremap_patch.py` runs it against a scratch tree that stands for the device, with a fake `systemctl`: install, status and uninstall through a Hakai launcher (undone byte for byte) and through the shared drop-in (next to an addin), an unknown launcher and a hand-made install refused, the user's rules kept, the typed words, a failed install rolled back, and that the committed script is the build of the library inside it. `HWR_TEST_SH="busybox sh"` with BusyBox's tools first in `PATH` runs it as on the devices.
