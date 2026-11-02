# Web Shell → iOS IPA (private-identity pipeline)

Generic WKWebView shell compiled to an **unsigned IPA** by a free GitHub Actions
macOS runner — with **zero product files on GitHub**.

## How the privacy split works

| Where | What |
|---|---|
| **GitHub repo (public, generic)** | `project.yml`, `Shell/Sources/*.swift`, `scripts/build_ipa.sh`, `.github/workflows/build.yml` — no name, no URL, no icon, no bundle id of any product. It reads its URL at runtime from `shell.json` inside the app bundle. |
| **This PC only (`identity/`, git-ignored)** | `identity.json` (app name, bundle id, `https://imfan.org`), `icon-512.png` (Aurorix maskable icon) |
| **Local step after build** | `tools/inject_identity.py` unzips the generic IPA, writes `shell.json` + Info.plist name/bundle-id + icon PNGs, rezips → `dist/Aurorix-unsigned.ipa` |

The workflow also publishes the generic IPA as a **public release asset** → it can be
downloaded with plain `curl`, no GitHub login needed.

## Pipeline

1. Create an empty **public** GitHub repo (any generic name) → push this folder (`identity/` is git-ignored, it never leaves this PC).
2. Actions runs `build-ipa` on `macos-15` → `Shell-unsigned.ipa` in Releases.
3. `curl -L -o dist/Shell-unsigned.ipa <release-url>`
4. `python tools/inject_identity.py` → `dist/Aurorix-unsigned.ipa`
5. Sign at `signer.esign-ios.com` (Server Certificate) → signed IPA.
6. Host + `itms-services://` link → users install, trust once, ~1 year.

## Changing things

- URL / app name / bundle id → `identity/identity.json` (local only, no rebuild)
- Icon → replace `identity/icon-512.png` (local only, no rebuild)
- Shell behavior (webview settings) → `Shell/Sources/WebShell.swift` (needs CI rebuild)

## Shell features (device-first)

Persistent data store (cookies, IndexedDB, OPFS survive relaunch; in-app Service
Workers on iOS 16.4+ → Aurorix offline works), inline media, swipe back,
pull-to-refresh, target-host navigations in-app / everything else Safari,
offline Retry page, ~1–2 MB binary.

## Honest limits

- In-app Service Worker needs iOS 16.4+ (older iOS = online-only inside the app).
- Legacy `CFBundleIconFiles` icons (no asset catalog) — verified pattern for sideloaded IPAs; check the icon shows after your first install.
- First ESign trust prompt per device is expected.
