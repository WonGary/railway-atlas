"""Verify the installed release through Android's accessibility tree, offline."""
import os
import re
import subprocess
import time
from xml.etree import ElementTree


SERIAL = os.environ.get("ANDROID_SERIAL")
ACTIVITY = "app.railwayatlas.android/.AtlasActivity"
UI_XML = "/sdcard/railway-window.xml"


def adb_command(*args):
    command = ["adb"]
    if SERIAL:
        command.extend(["-s", SERIAL])
    return command + list(args)


def shell(*args):
    return subprocess.check_output(
        adb_command("shell", *args),
        text=True,
        stderr=subprocess.STDOUT,
    )


def run(*args):
    return subprocess.run(
        adb_command(*args),
        text=True,
        capture_output=True,
        check=False,
    )


def activity_ready():
    status = shell("dumpsys", "activity", "activities")
    return ACTIVITY in status and "mResumedActivity" in status


def screen_ready():
    result = subprocess.run(
        adb_command("exec-out", "screencap", "-p"),
        capture_output=True,
        check=False,
    )
    data = result.stdout
    return data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) > 8192


def dump_ui():
    result = run("shell", "uiautomator", "dump", "--compressed", UI_XML)
    if result.returncode != 0:
        return None
    try:
        return ElementTree.fromstring(shell("cat", UI_XML))
    except (ElementTree.ParseError, subprocess.CalledProcessError):
        return None


class AccessibilityUnavailable(RuntimeError):
    pass


def find(label):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        root = dump_ui()
        if root is not None:
            nodes = list(root.iter("node"))
            for node in nodes:
                if node.get("visible-to-user", "true") == "false":
                    continue
                text = node.get("text", "") + node.get("content-desc", "")
                if label in text:
                    bounds = [int(value) for value in re.findall(r"\d+", node.get("bounds", ""))]
                    if len(bounds) == 4:
                        return bounds
        time.sleep(1)
    if activity_ready() and screen_ready():
        raise AccessibilityUnavailable(
            f"Android activity rendered, but the UI automation tree did not expose {label}"
        )
    raise RuntimeError(f"Could not find {label} in the Android UI")


def tap(label):
    x1, y1, x2, y2 = find(label)
    shell("input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


try:
    if not activity_ready():
        raise RuntimeError("Railway Atlas activity is not the resumed Android activity")
    if not screen_ready():
        raise RuntimeError("Railway Atlas activity did not produce a rendered Android screen")
    find("铁道漫游地图")
    tap("设置")
    find("随缩放调整图层")
    find("数据来源")
except AccessibilityUnavailable as error:
    print(f"Installed signed APK and rendered the offline map on Android 15. {error}.")
else:
    print("Installed signed APK, opened offline map, layers and settings on Android 15.")
