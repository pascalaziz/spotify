#!/usr/bin/env python3
"""Inject product identity into the generic unsigned Shell IPA.

100% LOCAL — your URL / app name / icon never leave this PC.
Usage:  python tools/inject_identity.py [Shell-unsigned.ipa]
Output: dist/<AppName>-unsigned.ipa  (then sign at signer.esign-ios.com)
"""
import json, plistlib, shutil, sys, zipfile
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
IDENT = ROOT / "identity"
DIST = ROOT / "dist"

ident = json.loads((IDENT / "identity.json").read_text(encoding="utf-8"))
APP_NAME, BUNDLE_ID, URL = ident["app_name"], ident["bundle_id"], ident["url"]

src = Path(sys.argv[1]) if len(sys.argv) > 1 else DIST / "Shell-unsigned.ipa"
work = DIST / "work"
shutil.rmtree(work, ignore_errors=True)
work.mkdir(parents=True)

with zipfile.ZipFile(src) as z:
    z.extractall(work)

apps = list((work / "Payload").glob("*.app"))
assert apps, "no .app inside Payload"
app = apps[0]

# 1) shell.json — the URL the app loads on launch
(app / "shell.json").write_text(json.dumps({"url": URL}), encoding="utf-8")

# 2) Info.plist — display name, bundle id, icon list
plist_path = app / "Info.plist"
p = plistlib.loads(plist_path.read_bytes())
p["CFBundleDisplayName"] = APP_NAME
p["CFBundleName"] = APP_NAME
p["CFBundleIdentifier"] = BUNDLE_ID
ICONS = {
    "AppIcon29x29@2x": 58, "AppIcon29x29@3x": 87,
    "AppIcon40x40@2x": 80, "AppIcon40x40@3x": 120,
    "AppIcon60x60@2x": 120, "AppIcon60x60@3x": 180,
    "AppIcon76x76@2x": 152,
}
entries = sorted({n.split("@")[0] for n in ICONS})
p["CFBundleIcons"] = {"CFBundleIconFiles": entries}
plist_path.write_bytes(plistlib.dumps(p))

# 3) icon PNGs from identity/icon-512.png
im = Image.open(IDENT / "icon-512.png").convert("RGBA")
resample = Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.LANCZOS
for name, size in ICONS.items():
    im.resize((size, size), resample).save(app / f"{name}.png")

# 4) rezip — Mach-O binary keeps the exec bit
binary = app / app.stem
assert binary.exists(), f"binary not found: {binary}"
out = DIST / f"{APP_NAME}-unsigned.ipa"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(work.rglob("*")):
        if f.is_file():
            arc = f.relative_to(work).as_posix()
            zi = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            zi.external_attr = (0o100755 if f == binary else 0o100644) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.write(f, arc)

shutil.rmtree(work, ignore_errors=True)
print(f"OK: {out} ({out.stat().st_size // 1024} KB)")
