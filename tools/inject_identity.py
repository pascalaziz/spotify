#!/usr/bin/env python3
"""Inject product identity into the generic unsigned Shell IPA.

100% LOCAL — your URL / app name / icon never leave this PC.
Usage:  python tools/inject_identity.py [Shell-unsigned.ipa]
Output: dist/<AppName>-unsigned.ipa  (then sign at signer.esign-ios.com)
"""
import json, plistlib, shutil, sys, zipfile
import hashlib
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

# VERSION: unique per build, never typed by hand. The signer keys its cache on bundle id + version,
# so the version is derived from the app's actual bytes: same binary -> same version (idempotent),
# any change -> a new version the cache cannot answer for. An explicit argument wins when given.
def _derive_version(staged_app: Path) -> tuple[str, str]:
    h = hashlib.sha256()
    for f in sorted(p for p in staged_app.rglob("*") if p.is_file()):
        h.update(f.name.encode())
        h.update(f.read_bytes())
    d = int(h.hexdigest(), 16)
    major = 1
    minor = (d // 10**7) % 100
    patch = (d // 10**9) % 100
    build = (d % 900000) + 100000          # always 6 digits, never 1
    return f"{major}.{minor}.{patch}", str(build)

_ver, _build = _derive_version(app)
VERSION = sys.argv[2] if len(sys.argv) > 2 else _ver
BUILD = sys.argv[2] if len(sys.argv) > 2 else _build

# 1) shell.json — the URL the app loads on launch
(app / "shell.json").write_text(json.dumps({"url": URL}), encoding="utf-8")

# 2) Info.plist — display name, bundle id, icon list
plist_path = app / "Info.plist"
p = plistlib.loads(plist_path.read_bytes())
p["CFBundleDisplayName"] = APP_NAME
p["CFBundleName"] = APP_NAME
p["CFBundleIdentifier"] = BUNDLE_ID
# APP EXTENSIONS (2026-11-17): embedded PlugIns/*.app (the Live Activity widget) must keep a
# bundle id that is a CHILD of the main id, or signing/install breaks. The generic build ships
# com.webshell.<X>; rewrite to <BUNDLE_ID>.<same suffix> and rename its display name.
for ext_app in sorted(list((app / "PlugIns").glob("*.appex")) + list((app / "PlugIns").glob("*.app"))) if (app / "PlugIns").is_dir() else []:
    ep = ext_app / "Info.plist"
    if not ep.exists(): continue
    pe = plistlib.loads(ep.read_bytes())
    old = str(pe.get("CFBundleIdentifier") or "")
    suffix = old.split(".")[-1] if "." in old else "Widgets"
    pe["CFBundleIdentifier"] = BUNDLE_ID + "." + suffix
    pe["CFBundleDisplayName"] = APP_NAME
    ep.write_bytes(plistlib.dumps(pe))
# BUILD VERSION MUST BE UNIQUE PER BUILD (2026-11-06). The third-party signer (AppleJr) memoises
# signed output per bundle identifier + CFBundleVersion: every upload of a NEW binary carrying the
# same "1" got back the OLD signed .ipa (proved: uploaded a 185,992-byte binary, downloaded a
# 206,480-byte one, on all three certs and under a different filename). The version is therefore
# derived from the binaries themselves, so any change to the app produces a new identity that no
# cache can answer for. Inject with: python tools/inject_identity.py <ipa> [version]
p["CFBundleShortVersionString"] = VERSION
p["CFBundleVersion"] = BUILD
ICONS = {
    "AppIcon29x29@2x": 58, "AppIcon29x29@3x": 87,
    "AppIcon40x40@2x": 80, "AppIcon40x40@3x": 120,
    "AppIcon60x60@2x": 120, "AppIcon60x60@3x": 180,
    "AppIcon76x76@2x": 152,
}
entries = sorted({n.split("@")[0] for n in ICONS})
p["CFBundleIcons"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": entries + sorted(ICONS)}}
p["CFBundleIconFiles"] = entries + sorted(ICONS)
plist_path.write_bytes(plistlib.dumps(p))

# 3) icon PNGs from identity/icon-512.png
im = Image.open(IDENT / "icon-512.png").convert("RGBA")
resample = Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.LANCZOS
for name, size in ICONS.items():
    im.resize((size, size), resample).save(app / f"{name}.png")

# 3b) now-playing fallback artwork — the same identity art, bundled for the
# native card when a track has no thumbnail (loaded via UIImage(named:)).
im.resize((256, 256), resample).save(app / "nowplaying.png")

# 4) rezip — Mach-O binary keeps the exec bit
binary = app / app.stem
assert binary.exists(), f"binary not found: {binary}"
out = DIST / "app-unsigned.ipa"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(work.rglob("*")):
        if f.is_file():
            arc = f.relative_to(work).as_posix()
            zi = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            zi.external_attr = (0o100755 if f == binary else 0o100644) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, f.read_bytes())

shutil.rmtree(work, ignore_errors=True)
# the served build, readable by the web side (admin drawer shows it in a browser too)
(DIST / "app-version.txt").write_text(f"{VERSION} ({BUILD})", encoding="utf-8")
print(f"OK: {out} ({out.stat().st_size // 1024} KB)")
