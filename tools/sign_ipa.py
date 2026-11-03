#!/usr/bin/env python3
"""Sign the unsigned app IPA locally with zsign + your bought cert. Nothing uploaded anywhere.

Put your 3 cert files in spotifyAPP/cert/ :
    Certificate.p12  (or any .p12 name)
    Certificate.mobileprovision  (or any .mobileprovision name)
    password.txt     (one line: the cert password)

Then run:  python tools/sign_ipa.py
Output:     dist/app-signed.ipa
"""
import subprocess, sys, glob
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CERT = ROOT / "cert"
DIST = ROOT / "dist"
ZSIGN = ROOT / "tools" / "zsign.exe"

p12s = glob.glob(str(CERT / "*.p12")) or glob.glob(str(CERT / "*.pfx"))
provs = glob.glob(str(CERT / "*.mobileprovision"))
pw_file = CERT / "password.txt"

if not (p12s and provs and pw_file.exists()):
    print("cert/ is not ready. Need: *.p12, *.mobileprovision, password.txt")
    for f in ("*.p12", "*.mobileprovision", "password.txt"):
        found = glob.glob(str(CERT / f))
        print(f"  {f}: {'OK' if found else 'MISSING'}")
    sys.exit(1)

password = pw_file.read_text(encoding="utf-8", errors="ignore").strip().splitlines()[0]
unsigned = DIST / "app-unsigned.ipa"
if not unsigned.exists():
    print(f"missing {unsigned}"); sys.exit(1)

DIST.mkdir(exist_ok=True)
out = DIST / "app-signed.ipa"
cmd = [str(ZSIGN), "-k", p12s[0], "-p", password, "-m", provs[0], "-o", str(out), str(unsigned)]
print("zsign:", " ".join(cmd[:2] + ["-p", "***", "-m", provs[0], "-o", str(out), str(unsigned)]))
r = subprocess.run(cmd, capture_output=True, text=True)
print(r.stdout[-1500:] if r.stdout else "", r.stderr[-800:] if r.stderr else "")
if r.returncode != 0 or not out.exists():
    print(f"SIGN_FAILED rc={r.returncode}"); sys.exit(1)
print(f"OK: {out} ({out.stat().st_size // 1024} KB) — ready to install / host")
