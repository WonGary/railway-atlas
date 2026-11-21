"""Sign a friend-test APK on the publisher's Mac, retaining the update identity."""
import argparse
import os
from pathlib import Path
import secrets
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("signer", type=Path)
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--key-dir", type=Path, required=True)
args = parser.parse_args()
os.umask(0o077)
folder = args.key_dir
folder.mkdir(mode=0o700, parents=True, exist_ok=True)
if folder.is_symlink() or folder.stat().st_uid != os.getuid() or folder.stat().st_mode & 0o077:
    raise SystemExit("Choose a private directory owned by the current user.")
key = folder / "railway-atlas-test.p12"
password = folder / "keystore-password"
if args.output.exists() or not args.source.is_file():
    raise SystemExit("Supply an unsigned APK and an unused output filename.")
if key.exists() != password.exists():
    raise SystemExit("Both signing files are required. Recover the missing file from your backup.")
if not key.exists():
    with password.open("x", encoding="ascii") as f:
        f.write(secrets.token_urlsafe(36) + "\n")
    subprocess.run(["keytool", "-genkeypair", "-alias", "railway-atlas", "-keyalg", "RSA",
                    "-keysize", "3072", "-validity", "11000", "-dname", "CN=Railway Atlas Test Builds",
                    "-keystore", str(key), "-storetype", "PKCS12", "-storepass:file", str(password)], check=True)
tool = ["java", "-jar", str(args.signer)]
subprocess.run(tool + ["sign", "--ks", str(key), "--ks-key-alias", "railway-atlas",
                      "--ks-pass", f"file:{password}", "--v4-signing-enabled", "false",
                      "--out", str(args.output), str(args.source)], check=True)
subprocess.run(tool + ["verify", "--verbose", "--print-certs", str(args.output)], check=True)
