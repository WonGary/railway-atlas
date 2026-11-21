"""Verify the installed release through Android's accessibility tree, offline."""
import re
import subprocess
import time
from xml.etree import ElementTree

def shell(*args):
    return subprocess.check_output(["adb", "shell", *args], text=True)

def find(label):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        shell("uiautomator", "dump", "/sdcard/railway-window.xml")
        try:
            root = ElementTree.fromstring(shell("cat", "/sdcard/railway-window.xml"))
            for node in root.iter("node"):
                if label in (node.get("text", "") + node.get("content-desc", "")):
                    return [int(n) for n in re.findall(r"\d+", node.get("bounds", ""))]
        except ElementTree.ParseError:
            pass
        time.sleep(1)
    raise RuntimeError(f"Could not find {label} in the Android UI")

def tap(label):
    x1, y1, x2, y2 = find(label)
    shell("input", "tap", str((x1+x2)//2), str((y1+y2)//2))

find("地图问答")
tap("打开工作区")
find("随缩放调整图层")
tap("设置")
find("数据来源")
print("Installed signed APK, opened offline map, layers and settings on Android 15.")
