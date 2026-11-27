"""Build the web checkpoint alone or package the four portable distributions."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
from zipfile import ZipFile, ZIP_DEFLATED, ZipInfo

root = Path(__file__).resolve().parents[1]
web = root / "Web"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--web-only", action="store_true", help="Package Web/PWA without building desktop binaries.")
args = parser.parse_args()
out = args.output.absolute()
out.mkdir(parents=True, exist_ok=True)
version = (root / "Mobile/VERSION").read_text().strip()


def build(stage, system, arch):
    binary = stage / f"{system}-{arch}"
    subprocess.run(["go", "build", "-trimpath", "-ldflags=-s -w", "-o", binary, root / "Portable/main.go"],
                   check=True, env={**os.environ, "GOOS": system, "GOARCH": arch, "CGO_ENABLED": "0"})
    return binary


def archive(label, extra):
    path = out / f"Railway-Atlas-{version}-{label}.zip"
    with ZipFile(path, "x", compression=ZIP_DEFLATED) as dest:
        for item in sorted(web.rglob("*")):
            if (item.is_file() and item.name != "card-contours.json" and
                    not any(p.startswith(".") for p in item.relative_to(web).parts)):
                dest.write(item, "Web/" + item.relative_to(web).as_posix())
        for name, item in extra.items():
            dest.write(item, name)
        if label.startswith("macOS"):
            launcher = ZipInfo("打开铁道漫游.command")
            launcher.create_system = 3
            launcher.external_attr = 0o100755 << 16
            dest.writestr(launcher, '#!/bin/sh\ncd "$(dirname "$0")" || exit 1\nexec ./Railway-Atlas\n')
        dest.write(root/"Portable/使用说明.txt", "使用说明.txt")
    return path


with tempfile.TemporaryDirectory(prefix="railway-build-") as stage_name:
    stage = Path(stage_name)
    files = [archive("Web-PWA", {})]
    if not args.web_only:
        mac = stage / "Railway-Atlas"
        subprocess.run(["lipo", "-create", build(stage, "darwin", "arm64"), build(stage, "darwin", "amd64"), "-output", mac], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "app.railwayatlas.portable", mac], check=True)
        subprocess.run(["codesign", "--verify", "--strict", "--all-architectures", mac], check=True)
        files.append(archive("macOS-universal", {"Railway-Atlas": mac}))
        for label, arch in [("x64", "amd64"), ("arm64", "arm64")]:
            files.append(archive("Windows-" + label, {"Railway-Atlas.exe": build(stage, "windows", arch)}))
with (out/"SHA256SUMS.txt").open("x", encoding="ascii", newline="\n") as sums:
    for path in sorted(files):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        sums.write(f"{digest}  {path.name}\n")
        print(path.name, path.stat().st_size)
