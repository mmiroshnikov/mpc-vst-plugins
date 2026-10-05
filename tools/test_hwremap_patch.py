#!/usr/bin/env python3
"""Tests for tools/mpc_patch/hwremap/hwremap-patch.sh (docs/PATCHES.md) on a scratch tree that stands for the device's /
(HWREMAP_PREFIX), with a fake systemctl and pidof: both ways LD_PRELOAD is set (a Hakai launcher, or the systemd drop-in
shared with the addins), sharing that drop-in with an addin, rollback of a failed install, the refusals, the typed words, and
that the committed script is what build_script.py makes from its own embedded library. No device; run it as a normal user
(as root the read-only unit folder of the scratch tree is writable, which the devices' is not).

  python3 tools/test_hwremap_patch.py
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PDIR = os.path.join(ROOT, "tools", "mpc_patch", "hwremap")
SCRIPT = os.path.join(PDIR, "hwremap-patch.sh")
SH = os.environ.get("HWR_TEST_SH") or shutil.which("dash") or shutil.which("sh")   # HWR_TEST_SH="busybox sh": as on the devices
SO = "/data/hwremap/hwremap.so"
HAKAI = '''#!/bin/sh
CURSOR_SO=""
if [ -f /data/cursor ]; then
    LD_PRELOAD="/usr/lib/customBufferSizeMPC.so $CURSOR_SO" /usr/bin/MPC --fullscreen "$@"
else
    LD_PRELOAD="/usr/lib/customBufferSizeMPC.so $CURSOR_SO" /usr/bin/MPC "$@"
fi
'''
STOCK_LAUNCHER = '#!/bin/sh\nexec /usr/bin/MPC "$@"\n'
FORCE_UNIT = '[Unit]\nDescription=MPC\n\n[Service]\nEnvironment="LD_PRELOAD=/usr/lib/libforce_cursor.so"\nExecStart=/usr/bin/az01-launch-MPC\n'
FAKE_SYSTEMCTL = '''#!/bin/sh
echo "$*" >> "$HWR_LOG"
[ "$1" = daemon-reload ] && [ -n "${HWR_FAIL_RELOAD:-}" ] && exit 1
[ "$1" = cat ] && { [ -f "$HWREMAP_PREFIX/usr/lib/systemd/system/$2.service" ] || exit 1; cat "$HWREMAP_PREFIX/usr/lib/systemd/system/$2.service"; }
exit 0
'''


def rfile(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def wfile(path, body, mode="w"):
    with open(path, mode) as f:
        f.write(body)


def embedded_so(script_text):
    body = re.search(r"write_so\(\) \{.*?\{\n(.*?)\n    \} > \"\$1\"", script_text, re.S).group(1)
    out = bytearray()
    for l in body.splitlines():
        out += bytes(int(o, 8) for o in re.findall(r"\\([0-7]{3})", l))
    return bytes(out)


class HwremapPatch(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.root = os.path.join(self.t, "root")
        self.bin = os.path.join(self.t, "bin")
        self.log = os.path.join(self.t, "systemctl.log")
        os.makedirs(self.bin)
        for name, body in (("systemctl", FAKE_SYSTEMCTL), ("pidof", "#!/bin/sh\nexit 1\n")):
            p = os.path.join(self.bin, name)
            wfile(p, body)
            os.chmod(p, 0o755)
        self.put("usr/bin/az01-launch-MPC", STOCK_LAUNCHER)
        self.put("usr/lib/systemd/system/acvs.service", FORCE_UNIT)
        self.put("proc/asound/cards", " 0 [Force          ]: USB-Audio - Akai Pro Force\n")
        os.makedirs(os.path.join(self.root, "sdcard"))
        os.makedirs(os.path.join(self.root, "etc/systemd/system"))
        os.chmod(self.path("usr/lib/systemd/system"), 0o555)   # the unit sits on the read-only root, as on the devices

    def tearDown(self):
        os.chmod(self.path("usr/lib/systemd/system"), 0o755)
        shutil.rmtree(self.t, ignore_errors=True)

    def path(self, rel):
        return os.path.join(self.root, rel)

    def put(self, rel, body):
        os.makedirs(os.path.dirname(self.path(rel)), exist_ok=True)
        wfile(self.path(rel), body)

    def read(self, rel):
        return rfile(self.path(rel))

    def run_script(self, *args, stdin="", **env):
        e = dict(os.environ, HWREMAP_PREFIX=self.root, HWR_LOG=self.log, PATH=self.bin + os.pathsep + os.environ["PATH"], **env)
        r = subprocess.run([*SH.split(), SCRIPT, *args], env=e, input=stdin, capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout + r.stderr

    def state(self, **env):
        code, out = self.run_script("status", **env)
        self.assertEqual(code, 0, out)
        return out.strip().splitlines()[-1]

    def calls(self):
        return rfile(self.log) if os.path.exists(self.log) else ""

    def tree(self):
        out = {}
        for d, _, files in os.walk(self.root):
            for f in files:
                p = os.path.join(d, f)
                out[os.path.relpath(p, self.root)] = rfile(p, "rb")
        return out

    def test_systemd_install_status_uninstall(self):
        self.assertEqual(self.state(), "STATE state=stock supported=1 backup=0")
        code, out = self.run_script("install", "--confirmed")
        self.assertEqual(code, 0, out)
        so = rfile(self.path("data/hwremap/hwremap.so"), "rb")
        self.assertEqual(so[:4], b"\x7fELF")
        dropin = self.read("etc/systemd/system/acvs.service.d/90-mpc-addins.conf")
        self.assertIn("Environment=LD_PRELOAD=/usr/lib/libforce_cursor.so:" + SO, dropin)
        self.assertIn("dbl 11 b5", self.read("sdcard/hwremap.conf"), "the Force rules")
        self.assertIn("daemon-reload", self.calls())
        self.assertIn("restart acvs", self.calls())
        self.assertEqual(self.state(), "STATE state=partial supported=1 backup=1 reason=not-loaded")
        maps = os.path.join(self.t, "maps")
        wfile(maps, "b6f00000-b6f04000 r-xp 00000000 b3:02 1234 " + SO + "\n")
        self.assertEqual(self.state(HWREMAP_MAPS=maps), "STATE state=patched supported=1 backup=1")
        code, out = self.run_script("uninstall", "--confirmed")
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.exists(self.path("etc/systemd/system/acvs.service.d")), "the shared drop-in goes with the last entry")
        self.assertFalse(os.path.exists(self.path("data/hwremap")))
        self.assertTrue(os.path.exists(self.path("sdcard/hwremap.conf")), "the user's rules stay")
        self.assertEqual(self.state(), "STATE state=stock supported=1 backup=1")

    def test_shares_the_drop_in_with_an_addin(self):
        addin = "/data/mpc-addins/remote/remote.so"
        self.put("etc/systemd/system/acvs.service.d/90-mpc-addins.conf",
                 "[Service]\n# lib: 2\n# base: /usr/lib/libforce_cursor.so\nEnvironment=LD_PRELOAD=/usr/lib/libforce_cursor.so:%s\n" % addin)
        self.assertEqual(self.run_script("install", "--confirmed")[0], 0)
        dropin = self.read("etc/systemd/system/acvs.service.d/90-mpc-addins.conf")
        self.assertIn("Environment=LD_PRELOAD=/usr/lib/libforce_cursor.so:%s:%s" % (addin, SO), dropin)
        self.assertEqual(self.run_script("uninstall", "--confirmed")[0], 0)
        dropin = self.read("etc/systemd/system/acvs.service.d/90-mpc-addins.conf")
        self.assertIn("Environment=LD_PRELOAD=/usr/lib/libforce_cursor.so:%s\n" % addin, dropin)
        self.assertNotIn("hwremap", dropin)

    def test_hakai_launcher_install_and_exact_undo(self):
        self.put("usr/bin/az01-launch-MPC", HAKAI)
        self.put("proc/asound/cards", " 1 [Controller     ]: USB-Audio - MPC Live Controller\n")
        self.assertIn("through the launcher", self.run_script("status")[1])
        code, out = self.run_script("install", "--confirmed")
        self.assertEqual(code, 0, out)
        lines = [l for l in self.read("usr/bin/az01-launch-MPC").splitlines() if "LD_PRELOAD=" in l]
        self.assertEqual(len(lines), 2)
        for l in lines:
            self.assertIn("customBufferSizeMPC.so %s $CURSOR_SO" % SO, l)
        self.assertFalse(os.path.exists(self.path("etc/systemd/system/acvs.service.d")), "the launcher wins over systemd here")
        self.assertIn("d123 p0x31 u123", self.read("sdcard/hwremap.conf"), "the MPC Live rules")
        bk = self.path("data/mpc-vst-plugins/backups")
        self.assertEqual(rfile(os.path.join(bk, os.listdir(bk)[0], "az01-launch-MPC")), HAKAI)
        self.assertEqual(self.run_script("install", "--confirmed")[0], 0, "installing again is harmless")
        self.assertEqual(self.read("usr/bin/az01-launch-MPC").count(SO), 2)
        self.assertEqual(self.run_script("uninstall", "--confirmed")[0], 0)
        self.assertEqual(self.read("usr/bin/az01-launch-MPC"), HAKAI)

    def test_unknown_launcher_is_refused(self):
        self.put("usr/bin/az01-launch-MPC", '#!/bin/sh\nLD_PRELOAD=/usr/lib/other.so /usr/bin/MPC "$@"\n')
        self.assertEqual(self.state(), "STATE state=unsupported supported=0 backup=0 reason=launcher")
        before = self.tree()
        code, out = self.run_script("install", "--confirmed")
        self.assertNotEqual(code, 0)
        self.assertEqual(self.tree(), before, out)

    def test_a_hand_made_install_is_refused(self):
        for rel in ("usr/lib/hwremap.so", "etc/systemd/system/acvs.service.d/hwremap.conf", "data/hwremap/hwremap.so"):
            with self.subTest(rel):
                self.put(rel, "x")
                self.assertEqual(self.state(), "STATE state=unsupported supported=0 backup=0 reason=manual-install")
                before = self.tree()
                self.assertNotEqual(self.run_script("install", "--confirmed")[0], 0)
                self.assertEqual(self.tree(), before)
                os.remove(self.path(rel))

    def test_existing_rules_are_kept_and_other_devices_get_none(self):
        self.put("sdcard/hwremap.conf", "35 b36\n")
        self.assertEqual(self.run_script("install", "--confirmed", "--no-restart")[0], 0)
        self.assertEqual(self.read("sdcard/hwremap.conf"), "35 b36\n")
        self.assertNotIn("restart", self.calls())
        self.assertEqual(self.run_script("uninstall", "--confirmed", "--no-restart")[0], 0)
        os.remove(self.path("sdcard/hwremap.conf"))
        self.put("proc/asound/cards", " 0 [MPCOne ]: USB-Audio - MPC One\n")
        self.assertEqual(self.run_script("install", "--confirmed")[0], 0)
        rules = [l for l in self.read("sdcard/hwremap.conf").splitlines() if l and not l.startswith("#") and l != "log 0"]
        self.assertEqual(rules, [], "no rules for a device without known button numbers")
        self.run_script("uninstall", "--confirmed")
        self.assertEqual(self.run_script("install", "--confirmed", "--device", "mpc-live")[0], 0, "unless chosen")

    def test_typed_words(self):
        before = self.tree()
        code, out = self.run_script("install", stdin="yes\n")
        self.assertNotEqual(code, 0)
        self.assertIn("cancelled", out)
        self.assertEqual(self.tree(), before)
        self.assertEqual(self.run_script("install", stdin="PATCH\n")[0], 0)
        code, out = self.run_script("uninstall", stdin="PATCH\n")
        self.assertNotEqual(code, 0)
        self.assertTrue(os.path.exists(self.path("data/hwremap/hwremap.so")))
        self.assertEqual(self.run_script("uninstall", stdin="REMOVE\n")[0], 0)
        self.assertFalse(os.path.exists(self.path("data/hwremap")))

    def test_a_failed_install_rolls_back(self):
        before = self.tree()
        code, out = self.run_script("install", "--confirmed", HWR_FAIL_RELOAD="1")
        self.assertNotEqual(code, 0)
        self.assertIn("rolling back", out)
        after = {k: v for k, v in self.tree().items() if not k.startswith("data/mpc-vst-plugins/backups/")}
        self.assertEqual(after, before)

    def test_a_lost_entry_says_install_again(self):
        self.assertEqual(self.run_script("install", "--confirmed")[0], 0)
        os.remove(self.path("etc/systemd/system/acvs.service.d/90-mpc-addins.conf"))
        self.assertEqual(self.state(), "STATE state=partial supported=1 backup=1 reason=not-wired")
        self.assertEqual(self.run_script("install", "--confirmed")[0], 0)
        self.assertEqual(self.state(), "STATE state=partial supported=1 backup=1 reason=not-loaded")

    def test_other_version_is_left_alone(self):
        self.assertEqual(self.run_script("install", "--confirmed")[0], 0)
        self.put("data/hwremap/VERSION", "0\n")
        self.assertEqual(self.state(), "STATE state=unsupported supported=0 backup=1 reason=other-version")
        self.assertNotEqual(self.run_script("uninstall", "--confirmed")[0], 0)
        self.assertNotEqual(self.run_script("install", "--confirmed")[0], 0)

    def test_unknown_flag_is_refused(self):
        self.assertNotEqual(self.run_script("install", "--yes")[0], 0)
        self.assertNotEqual(self.run_script("install", "--device", "mpc-x")[0], 0)


class Build(unittest.TestCase):
    def test_committed_script_is_the_build_of_its_own_library(self):
        src = rfile(SCRIPT)
        so = embedded_so(src)
        md5 = re.search(r"^SO_MD5=([0-9a-f]{32})$", src, re.M).group(1)
        self.assertEqual(hashlib.md5(so).hexdigest(), md5)
        self.assertEqual(so[:4], b"\x7fELF")
        self.assertEqual(so[18:20], b"\x28\x00", "ARM")
        t = tempfile.mkdtemp()
        try:
            wfile(os.path.join(t, "hwremap.so"), so, "wb")
            subprocess.run([sys.executable, os.path.join(PDIR, "build_script.py"), os.path.join(t, "hwremap.so"), os.path.join(t, "out.sh")],
                           check=True, capture_output=True)
            self.assertEqual(rfile(os.path.join(t, "out.sh")), src,
                             "hwremap-patch.sh is stale: run tools/mpc_patch/hwremap/build_script.py (addin-lib.sh, src/ or the template changed)")
        finally:
            shutil.rmtree(t, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
