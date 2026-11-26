"""Verify the installed release through Android's accessibility tree, offline."""
import re
import subprocess
import time
from pathlib import Path
from xml.etree import ElementTree

def shell(*args):
    return subprocess.check_output(["adb", "shell", *args], text=True)

def find(label):
    deadline = time.monotonic() + 90
    visible = []
    while time.monotonic() < deadline:
        shell("uiautomator", "dump", "/sdcard/railway-window.xml")
        try:
            root = ElementTree.fromstring(shell("cat", "/sdcard/railway-window.xml"))
            visible = []
            for node in root.iter("node"):
                text = " ".join(filter(None, (node.get("text"), node.get("content-desc"))))
                bounds = [int(n) for n in re.findall(r"-?\d+", node.get("bounds", ""))]
                if text and len(bounds) == 4 and bounds[2] > bounds[0] and bounds[3] > bounds[1]:
                    visible.append(text)
                    if label in text:
                        return bounds
        except ElementTree.ParseError:
            pass
        time.sleep(1)
    raise RuntimeError(f"Could not find {label} in the Android UI. Visible: {visible[:50]}")

def tap(label):
    x1, y1, x2, y2 = find(label)
    shell("input", "tap", str((x1+x2)//2), str((y1+y2)//2))

find(Path(__file__).with_name("VERSION").read_text().strip())
tap("打开图层与工作区")
find("底图与站点")
tap("设置")
find("地图模式")
print("Installed signed APK, opened offline map, layers and settings on Android 15.")
