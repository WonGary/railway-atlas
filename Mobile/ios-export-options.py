"""Read the Apple-signed profile and prepare a local IPA export for this team."""
import datetime
import os
import plistlib
import re
import shutil
import sys
from pathlib import Path

work = Path(sys.argv[1])
profile = plistlib.loads((work / "profile.plist").read_bytes())
entitlements = profile["Entitlements"]
team = profile["TeamIdentifier"][0]
uuid = profile["UUID"]
prefix, bundle = entitlements["application-identifier"].split(".", 1)
if (not re.fullmatch(r"[A-Z0-9]{10}", team)
        or not re.fullmatch(r"[0-9A-Fa-f-]{36}", uuid)
        or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle)
        or prefix not in profile["ApplicationIdentifierPrefix"]
        or profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices")
        or entitlements.get("get-task-allow") or not entitlements.get("beta-reports-active")
        or profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)):
    sys.exit("Choose an unexpired App Store Connect profile for an explicit App ID.")
profiles = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
profiles.mkdir(parents=True, exist_ok=True)
shutil.copyfile(work / "atlas.mobileprovision", profiles / f"{uuid}.mobileprovision")
(work / "ExportOptions.plist").write_bytes(plistlib.dumps({
    "method": "app-store-connect", "destination": "export", "teamID": team,
    "signingStyle": "manual", "signingCertificate": "Apple Distribution",
    "provisioningProfiles": {bundle: uuid}, "manageAppVersionAndBuildNumber": False,
    "uploadSymbols": False,
}))
with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as env:
    env.write(f"SIGN_TEAM={team}\nSIGN_PROFILE={uuid}\nSIGN_BUNDLE={bundle}\n")
