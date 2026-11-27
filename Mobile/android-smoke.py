"""Verify the installed release through Android's accessibility tree, offline."""
import os
import re
import subprocess
import time
from pathlib import Path
from xml.etree import ElementTree


SERIAL = os.environ.get("ANDROID_SERIAL")
PACKAGE = "app.railwayatlas.android"
UI_XML = "/sdcard/railway-window.xml"


def adb_command(*args):
    command = ["adb"]
    if SERIAL:
        command.extend(["-s", SERIAL])
    return command + list(args)


def shell(*args, timeout=12):
    return subprocess.check_output(adb_command("shell", *args), text=True,
                                   stderr=subprocess.STDOUT, timeout=timeout).strip()


def dump_ui():
    output = shell("uiautomator", "dump", UI_XML)
    # uiautomator sometimes returns success on a null root and leaves an older XML file.
    if "dumped to" not in output.lower():
        raise ValueError(output[-300:] or "uiautomator returned no result")
    return ElementTree.fromstring(shell("cat", UI_XML))


def find(label):
    deadline = time.monotonic() + 55
    diagnostic = "No Android snapshot"
    while time.monotonic() < deadline:
        try:
            visible = []
            for node in dump_ui().iter("node"):
                if node.get("package") != PACKAGE or node.get("visible-to-user") == "false":
                    continue
                labels = (node.get("text", "").strip(), node.get("content-desc", "").strip())
                bounds = list(map(int, re.findall(r"-?\d+", node.get("bounds", ""))))
                if len(bounds) != 4 or bounds[2] <= bounds[0] or bounds[3] <= bounds[1]:
                    continue
                if label in labels:
                    print(f"Found {label} at {bounds}", flush=True)
                    return bounds
                visible.extend(text for text in labels if text)
            diagnostic = f"Visible app labels: {visible[:40]}"
        except (ValueError, ElementTree.ParseError, subprocess.SubprocessError) as exc:
            diagnostic = str(exc)
        time.sleep(1)
    raise RuntimeError(f"Timed out looking for {label}. {diagnostic}")


def tap(label):
    x1, y1, x2, y2 = find(label)
    shell("input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


def main():
    find(Path(__file__).with_name("VERSION").read_text().strip())
    tap("打开图层与工作区")
    find("底图与站点")
    tap("设置")
    find("地图设置")
    print("Opened the offline map, layers and settings in the installed APK on Android 15.")


if __name__ == "__main__":
    main()
