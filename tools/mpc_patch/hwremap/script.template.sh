#!/bin/sh
# hwremap-patch.sh: remap the hardware buttons of an MPC Live or Force (open any screen from any button, double taps, long
# presses, Shift layers). Installs hwremap.so, a small library MPC loads at start (LD_PRELOAD), and its rules file.
#
#   sh hwremap-patch.sh status                                       what state the device is in (changes nothing)
#   sh hwremap-patch.sh install [--device mpc-live|force|none] [--confirmed] [--no-restart]
#                                                                    install it (asks you to type PATCH first)
#   sh hwremap-patch.sh uninstall [--confirmed] [--no-restart]       remove it (asks you to type REMOVE first)
#   sh hwremap-patch.sh help
# Run it ON the device as root (ssh root@<device-ip>), after copying the file there (scp).
#
# What it does: hwremap.so sits between the controller and MPC and rewrites the controller's MIDI: a press of a chosen button
# is swallowed and replaced with other buttons, pads or a touchscreen tap. The rules are in /sdcard/hwremap.conf, re-read
# whenever the file changes (no restart). Shift held = the original function. The rules installed by default:
#   MPC Live: Pad Bank A-D open the top row of the Mode Menu; + and - (and their double taps) open the second row.
#   Force:    Mixer x2 = Master; Menu x2 = Main Mode; Knobs short = Shift + Knobs, long = Knobs.
#   other devices (--device none): an empty rules file, so nothing changes until you write rules.
# An existing /sdcard/hwremap.conf is never overwritten, and uninstall leaves it (delete it yourself if you like).
#
# Where it goes:
#   /data/hwremap/                 hwremap.so and this patch's state (VERSION, MODE)
#   LD_PRELOAD of MPC              on a Hakai MPC, the launcher /usr/bin/az01-launch-MPC sets it: hwremap.so is added after
#                                  customBufferSizeMPC.so (the root filesystem is remounted writable for a moment and restored);
#                                  elsewhere, the systemd drop-in shared with the MPC addins (90-mpc-addins.conf, docs/ADDINS.md),
#                                  so libraries the firmware or other addins preload stay.
#   /data/mpc-vst-plugins/backups  the launcher and MPC's unit as they were (small: no projects)
# MPC restarts after install and uninstall (save your project first), unless --no-restart.
#
# WARNINGS
#  - hwremap.so runs inside MPC as root. The source is public (https://github.com/mmiroshnikov/akai_standalone_remap, commit
#    @@SOURCE_COMMIT@@); the library embedded below is that commit's build (md5 @@SO_MD5@@).
#  - Tested by its author on a first-generation MPC Live (Hakai, MPC 3.9.1) and a Force (stock firmware 3.9.0). Other models
#    have other button numbers: use --device none and write your own rules.
#  - A firmware update may replace the launcher or the unit: run status, and install again if it says so.
#  - If MPC stops starting, `sh /tmp/hwremap-patch.sh uninstall` over SSH puts everything back; the guide also lists the
#    steps by hand.
#  - Not affiliated with Akai Professional / inMusic.
#
# Version @@VERSION@@. Source: tools/mpc_patch/hwremap of the repository this came from.
VERSION=@@VERSION@@
SO_MD5=@@SO_MD5@@
P=${HWREMAP_PREFIX:-}                # tests only: a folder that stands for / (files); systemctl and pidof come from PATH
DIR=$P/data/hwremap
SO=/data/hwremap/hwremap.so          # the path MPC loads, also in tests
CONF=$P/sdcard/hwremap.conf
LAUNCHER=$P/usr/bin/az01-launch-MPC
BK_ROOT=$P/data/mpc-vst-plugins/backups
die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --- the addin installer's LD_PRELOAD functions (tools/release/addin/addin-lib.sh), so this patch and the addins share one list
ADDIN_INSTALL_TEST=; SYSTEMD_ROOT=$P
@@ADDIN_LIB@@
# --- end of addin-lib.sh

write_so() {   # $1 = file: hwremap.so, written byte by byte (no base64 or xxd on these devices)
    {
@@SO_PRINTF@@
    } > "$1"
}
write_conf() {   # $1 = device kind, $2 = file
    case "$1" in
        mpc-live) cat > "$2" <<'HWR_EOF_MPC_LIVE'
@@CONF_MPC_LIVE@@HWR_EOF_MPC_LIVE
        ;;
        force) cat > "$2" <<'HWR_EOF_FORCE'
@@CONF_FORCE@@HWR_EOF_FORCE
        ;;
        *) printf '%s\n' '# hwremap rules (see the guide). No rules: every button works as usual.' 'log 0' > "$2" ;;
    esac
}

# --- arguments (after the command)
CMD=${1:-help}; [ $# -gt 0 ] && shift
DEVICE=; CONFIRMED=0; RESTART=1
while [ $# -gt 0 ]; do
    case "$1" in
        --device) case "${2:-}" in mpc-live|force|none) DEVICE=$2; shift 2 ;; *) die "--device needs mpc-live, force or none" ;; esac ;;
        --confirmed) CONFIRMED=1; shift ;;
        --no-restart) RESTART=0; shift ;;
        *) usage 1 ;;
    esac
done

TOOLS="systemctl sed grep awk md5sum dd od"
need_device() {   # root, the architecture and the tools; tests (HWREMAP_PREFIX set) skip root and the architecture
    if [ -z "$P" ]; then
        [ "$(id -u)" = 0 ] || die "run as root on the device"
        case "$(uname -m)" in armv7*) ;; *) die "this is for 32-bit ARM MPC OS devices; this one is $(uname -m)" ;; esac
    fi
    for c in $TOOLS; do command -v "$c" >/dev/null || die "missing tool: $c"; done
}
device_kind() {   # the rules to install: --device, else the controller's name in the sound cards
    if [ -n "$DEVICE" ]; then echo "$DEVICE"; return; fi
    cards=$(cat "$P/proc/asound/cards" 2>/dev/null)
    case "$cards" in
        *[Ff]orce*) echo force ;;
        *"MPC Live"*|*"MPC LIVE"*) echo mpc-live ;;
        *) echo none ;;
    esac
}
installed_version() { [ -f "$DIR/VERSION" ] && cat "$DIR/VERSION"; }
backup_present() { ls -d "$BK_ROOT"/hwremap-* >/dev/null 2>&1; }
launcher_sets_preload() { [ -f "$LAUNCHER" ] && grep -q 'LD_PRELOAD=' "$LAUNCHER"; }
launcher_known() {   # every LD_PRELOAD line of the launcher has customBufferSizeMPC.so, where hwremap.so goes (Hakai)
    [ -z "$(grep 'LD_PRELOAD=' "$LAUNCHER" | grep -v 'customBufferSizeMPC\.so')" ]
}
wiring_mode() { if launcher_sets_preload; then echo launcher; else echo systemd; fi; }
svc_files() {   # MPC's unit and its drop-ins, wherever they are
    for d in $UNIT_DIRS; do ls "$P$d/$1.service" "$P$d/$1.service.d/"*.conf 2>/dev/null; done
}
wired() {   # is hwremap.so in the LD_PRELOAD that MPC will get?
    case "$1" in
        launcher) grep 'LD_PRELOAD=' "$LAUNCHER" 2>/dev/null | grep -qF "$SO" ;;
        *) for f in $(svc_files "$(mpc_service)"); do grep '^Environment=.*LD_PRELOAD=' "$f" | grep -qF "$SO" && return 0; done; return 1 ;;
    esac
}
loaded() {   # is hwremap.so mapped into the running MPC?
    if [ -n "${HWREMAP_MAPS:-}" ]; then grep -qF "$SO" "$HWREMAP_MAPS"; return; fi
    for pid in $(pidof MPC 2>/dev/null); do grep -qF "$SO" "/proc/$pid/maps" 2>/dev/null && return 0; done
    return 1
}
manual_install() {   # a hand-made install from the akai_standalone_remap README (not this patch): print where, succeed
    found=1
    [ -e "$P/usr/lib/hwremap.so" ] && { echo "  $P/usr/lib/hwremap.so"; found=0; }
    if [ -f "$LAUNCHER" ] && grep -q 'hwremap\.so' "$LAUNCHER" && ! { [ -f "$DIR/VERSION" ] && [ "$(cat "$DIR/MODE" 2>/dev/null)" = launcher ]; }; then
        echo "  $LAUNCHER lists hwremap.so"; found=0
    fi
    for f in "$P"/etc/systemd/system/*.service.d/hwremap.conf; do [ -f "$f" ] && { echo "  $f"; found=0; }; done
    if [ -e "$DIR/hwremap.so" ] && [ ! -f "$DIR/VERSION" ]; then echo "  $DIR/hwremap.so"; found=0; fi
    return $found
}

ROOT_WAS_RO=0
root_rw() {   # the launcher is on the read-only root filesystem
    [ -z "$P" ] || return 0
    if awk '$2 == "/" { split($4, o, ","); ro = (o[1] == "ro") } END { exit !ro }' /proc/mounts; then
        mount -o remount,rw / || die "cannot remount / writable"
        ROOT_WAS_RO=1
    fi
}
root_restore() { sync; [ "$ROOT_WAS_RO" = 0 ] || { mount -o remount,ro / || echo "warning: / is still writable" >&2; ROOT_WAS_RO=0; }; }
launcher_edit() {   # add | remove: hwremap.so on every LD_PRELOAD line of the launcher, staged and syntax-checked first
    if [ "$1" = add ]; then sed "/LD_PRELOAD=/s#customBufferSizeMPC\.so#& $SO#" "$LAUNCHER" > "$LAUNCHER.new"
    else sed "/LD_PRELOAD=/s# $SO##g" "$LAUNCHER" > "$LAUNCHER.new"; fi
    sh -n "$LAUNCHER.new" || { rm -f "$LAUNCHER.new"; return 1; }
    chmod 755 "$LAUNCHER.new" && mv "$LAUNCHER.new" "$LAUNCHER"
}
restart_mpc() {
    if [ "$RESTART" = 1 ]; then echo "Restarting MPC..."; systemctl restart "$(mpc_service)"
    else echo "MPC was not restarted: the change applies at its next start (systemctl restart $(mpc_service))."; fi
}

# the last line is for programs (the installer app): state=stock|patched|partial|unsupported supported=0|1 backup=0|1 [reason=<token>]
state_line() { echo "STATE state=$1 supported=$2 backup=$(backup_present && echo 1 || echo 0)${3:+ reason=$3}"; }

cmd_status() {
    if [ -z "$P" ]; then
        if [ "$(id -u)" != 0 ]; then echo "Not root: run this on the device as root."; state_line unsupported 0 not-root; return; fi
        case "$(uname -m)" in armv7*) ;; *) echo "This is for 32-bit ARM MPC OS devices; this one is $(uname -m)."; state_line unsupported 0 arch; return ;; esac
    fi
    for c in $TOOLS; do command -v "$c" >/dev/null || { echo "Missing tool: $c"; state_line unsupported 0 tools; return; }; done
    if v=$(installed_version); then
        if [ "$v" != "$VERSION" ]; then
            echo "Another version of this patch is installed ($v; this script is $VERSION): remove it with that version's uninstall first."
            state_line unsupported 0 other-version; return
        fi
        mode=$(cat "$DIR/MODE" 2>/dev/null)
        echo "Installed ($VERSION, LD_PRELOAD set by the $mode). Rules: $CONF$( [ -f "$CONF" ] || echo ' (missing: every button works as usual)')."
        if ! wired "$mode"; then
            echo "But hwremap.so is no longer in MPC's LD_PRELOAD (a firmware update?): run install again."
            state_line partial 1 not-wired; return
        fi
        if loaded; then echo "Loaded in MPC."; state_line patched 1
        else echo "Not loaded in MPC yet: restart MPC (systemctl restart $(mpc_service))."; state_line partial 1 not-loaded; fi
        return
    fi
    if out=$(manual_install); then
        echo "hwremap was installed by hand (not with this patch):"; echo "$out"
        echo "Remove that install first (the akai_standalone_remap README, Uninstall), then install with this patch."
        state_line unsupported 0 manual-install; return
    fi
    if launcher_sets_preload && ! launcher_known; then
        echo "MPC's launcher ($LAUNCHER) sets LD_PRELOAD in a way this patch does not know: not installing."
        state_line unsupported 0 launcher; return
    fi
    echo "Not installed. It would set LD_PRELOAD through the $(wiring_mode) and install the $(device_kind) rules."
    state_line stock 1
}

cmd_install() {
    need_device
    v=$(installed_version) && [ "$v" != "$VERSION" ] && die "version $v of this patch is installed: remove it with that version's uninstall first"
    if out=$(manual_install); then echo "$out"; die "hwremap was installed by hand: remove that install first (the akai_standalone_remap README, Uninstall)"; fi
    mode=$(wiring_mode)
    if [ "$mode" = launcher ]; then launcher_known || die "MPC's launcher ($LAUNCHER) sets LD_PRELOAD in a way this patch does not know"
    else check_lib "$(mpc_service)"; fi
    kind=$(device_kind)
    echo "Installing hwremap ($VERSION):"
    echo "  library: $SO"
    if [ "$mode" = launcher ]; then echo "  LD_PRELOAD: $LAUNCHER gains it after customBufferSizeMPC.so (/ is remounted writable for a moment)"
    else echo "  LD_PRELOAD: MPC's systemd service ($(mpc_service)), shared with the MPC addins"; fi
    if [ -f "$CONF" ]; then echo "  rules: $CONF (yours, kept)"; else echo "  rules: $CONF ($kind)"; fi
    [ "$RESTART" = 1 ] && echo "  then MPC restarts: save your project first"
    if [ "$CONFIRMED" = 0 ]; then
        printf "\nType PATCH to continue: "
        if [ -n "$P" ]; then read -r a; else read -r a < /dev/tty 2>/dev/null || read -r a; fi
        [ "$a" = PATCH ] || die "cancelled; nothing was changed"
    fi
    BACKUP=$BK_ROOT/hwremap-$VERSION-$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP" && chmod 700 "$BACKUP" || die "cannot create $BACKUP"
    [ ! -f "$LAUNCHER" ] || cp "$LAUNCHER" "$BACKUP/az01-launch-MPC"
    systemctl cat "$(mpc_service)" > "$BACKUP/mpc-service.before" 2>&1 || true
    printf '%s\n' 'Patch-only backup: the MPC launcher and service as they were before hwremap was installed.' > "$BACKUP/README.txt"
    FAILED=1; NEWCONF=0
    rollback() {
        [ "$FAILED" = 1 ] || return 0
        echo "Installation failed: rolling back"
        if [ "$mode" = launcher ]; then root_rw; wired launcher && launcher_edit remove; root_restore
        else preload_remove "$(mpc_service)" "$SO"; systemctl daemon-reload; fi
        rm -f "$DIR/hwremap.so" "$DIR/hwremap.so.new" "$DIR/VERSION" "$DIR/MODE"; rmdir "$DIR" 2>/dev/null
        [ "$NEWCONF" = 0 ] || rm -f "$CONF"
    }
    trap rollback EXIT
    mkdir -p "$DIR" || exit 1
    write_so "$DIR/hwremap.so.new" || exit 1
    [ "$(md5sum < "$DIR/hwremap.so.new" | cut -d' ' -f1)" = "$SO_MD5" ] || die "the library did not write correctly (checksum)"
    ADDIN_SO=hwremap.so; check_so "$DIR/hwremap.so.new"
    chmod 644 "$DIR/hwremap.so.new" && mv "$DIR/hwremap.so.new" "$DIR/hwremap.so" || exit 1
    if [ ! -f "$CONF" ]; then mkdir -p "$(dirname "$CONF")" && write_conf "$kind" "$CONF" || exit 1; NEWCONF=1; fi
    if [ "$mode" = launcher ]; then
        if ! wired launcher; then root_rw; launcher_edit add || { root_restore; die "editing $LAUNCHER failed"; }; root_restore; fi
    else
        svc=$(mpc_service)
        preload_add "$svc" "$(unit_with_preload "$svc" "$(ours "$svc")")" "$SO"
        systemctl daemon-reload || exit 1
    fi
    wired "$mode" || die "hwremap.so did not get into MPC's LD_PRELOAD"
    printf '%s\n' "$VERSION" > "$DIR/VERSION" && printf '%s\n' "$mode" > "$DIR/MODE" || exit 1
    FAILED=0; trap - EXIT
    sync
    echo "hwremap $VERSION installed. Backup: $BACKUP"
    restart_mpc
    echo "Edit $CONF to change what the buttons do (the guide lists the rules); edits apply on the next button press."
}

cmd_uninstall() {
    need_device
    v=$(installed_version) || { echo "Not installed. Nothing to do."; exit 0; }
    [ "$v" = "$VERSION" ] || die "version $v is installed: use that version's uninstall"
    mode=$(cat "$DIR/MODE" 2>/dev/null)
    case "$mode" in launcher|systemd) ;; *) die "$DIR/MODE is missing or damaged: see the guide to remove it by hand" ;; esac
    if [ "$CONFIRMED" = 0 ]; then
        echo "This takes hwremap.so out of MPC's LD_PRELOAD and deletes $DIR.$( [ "$RESTART" = 1 ] && echo ' MPC restarts: save your project first.')"
        printf "Type REMOVE to continue: "
        if [ -n "$P" ]; then read -r a; else read -r a < /dev/tty 2>/dev/null || read -r a; fi
        [ "$a" = REMOVE ] || die "cancelled; nothing was changed"
    fi
    if [ "$mode" = launcher ]; then
        if wired launcher; then root_rw; launcher_edit remove || { root_restore; die "editing $LAUNCHER failed; nothing was removed"; }; root_restore; fi
    else
        preload_remove "$(mpc_service)" "$SO"
        systemctl daemon-reload
    fi
    ! wired "$mode" || die "hwremap.so is still in MPC's LD_PRELOAD; nothing was deleted"
    rm -f "$DIR/hwremap.so" "$DIR/VERSION" "$DIR/MODE"
    rmdir "$DIR" 2>/dev/null || echo "kept $DIR: it holds files the patch did not install"
    sync
    echo "hwremap removed.$( [ -f "$CONF" ] && echo " $CONF is kept (delete it if you like).")"
    restart_mpc
}

case "$CMD" in
    status) cmd_status ;;
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) usage 0 ;;
    *) usage 1 ;;
esac
