#!/usr/bin/env python3
"""Generate hwremap-patch.sh from script.template.sh, the rules files in src/, the addin installer's addin-lib.sh and a
hwremap.so built from https://github.com/mmiroshnikov/akai_standalone_remap at SOURCE_COMMIT (its ./build.sh; the build is
reproducible, so the md5 below says which one it is).

  python3 build_script.py <path to hwremap.so> [output]

Output: hwremap-patch.sh (LF line endings). Run after editing the template or src/, or for a new hwremap.so (then update
SOURCE_COMMIT and SO_MD5 together)."""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
VERSION = "1"   # this patch's revision; uninstall refuses another one's install
SOURCE_COMMIT = "9d2aa57a570b0c4788f88b04ca242bb82176c380"
SO_MD5 = "526e04859c172d3093ffca3264b0df33"


def so_printf(data):
    lines = []
    for i in range(0, len(data), 64):
        lines.append("        printf '%s'" % "".join("\\%03o" % b for b in data[i:i + 64]))
    return "\n".join(lines)


def text(path):
    body = open(path, encoding="utf-8").read()
    assert body.endswith("\n") and "HWR_EOF_" not in body, path
    return body


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    so = open(sys.argv[1], "rb").read()
    if hashlib.md5(so).hexdigest() != SO_MD5:
        sys.exit("%s is not the hwremap.so of %s (md5 %s, expected %s)" % (sys.argv[1], SOURCE_COMMIT[:7], hashlib.md5(so).hexdigest(), SO_MD5))
    lib = text(os.path.join(ROOT, "tools", "release", "addin", "addin-lib.sh")).rstrip("\n")
    tpl = open(os.path.join(HERE, "script.template.sh"), encoding="utf-8").read()
    res = (tpl.replace("@@ADDIN_LIB@@", lib)
              .replace("@@SO_PRINTF@@", so_printf(so))
              .replace("@@CONF_MPC_LIVE@@", text(os.path.join(HERE, "src", "mpc-live.conf")))
              .replace("@@CONF_FORCE@@", text(os.path.join(HERE, "src", "force.conf")))
              .replace("@@SOURCE_COMMIT@@", SOURCE_COMMIT)
              .replace("@@SO_MD5@@", SO_MD5)
              .replace("@@VERSION@@", VERSION))
    assert "@@" not in res
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "hwremap-patch.sh")
    with open(out, "w", newline="\n", encoding="utf-8") as f:
        f.write(res)
    print("wrote", os.path.basename(out) + ":", len(res.splitlines()), "lines,", len(res), "bytes")


if __name__ == "__main__":
    main()
