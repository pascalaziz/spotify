# Aurorix iOS shell (spotifyAPP)

Thin native WKWebView shell around the existing Aurorix PWA (`C:\Users\Admin\Music\spotify\aurorix`).
The app IS the PWA — no new UI, no server work ('already' rule: everything inside is Aurorix itself).
Binary is ~1–2 MB. Built UNSIGNED by a free GitHub Actions macOS runner (no Mac, no $99 account).

## The only lines you ever touch

- **URL** → `Aurorix/Sources/WebShell.swift`, top:
  `let APP_URL = URL(string: "https://imfan.org")!`
  (PC host today → VPS later: DNS moves, app never needs an update)
- **Host allowed in-app** → same file, `let APP_HOST = "imfan.org"`
- **App name** → `project.yml` → `CFBundleDisplayName`
- **Icon** → `Aurorix/Resources/Assets.xcassets/AppIcon.appiconset/appicon-1024.png`
  (source: aurorix `public/icons/icon-maskable-512.png` upscaled)
- **Version** → `project.yml` → `MARKETING_VERSION`

## Build the IPA (free, no Mac)

1. Create a **public** GitHub repo (public = free unlimited Actions; macOS runners cost 10x on private).
2. Push this folder to `main`.
3. Actions tab → **build-ipa** → runs on push (or "Run workflow" button).
4. When green: download the **Aurorix-unsigned-ipa** artifact → `Aurorix-unsigned.ipa` inside.

Local push (from this folder, git already works):

```
git remote add origin https://github.com/<you>/aurorix-ios.git
git push -u origin main
```

## Sign + publish (the no-$99 path)

1. `signer.esign-ios.com` → upload the unsigned IPA → Server Certificate → Sign → download signed IPA.
2. Host `app.ipa` + `manifest.plist` on HTTPS (imfan.org or buildinstaller.com).
3. Users open in Safari:
   `itms-services://?action=download-manifest&url=https://imfan.org/manifest.plist`
   → Install → Settings → General → VPN & Device Management → Trust. ~1 year, no weekly re-sign.
4. Cert revoked (all users die at once) → re-sign same IPA with the new cert → users re-install.

## What the shell does (device-first)

- Persistent data store: cookies + IndexedDB + OPFS downloads survive relaunch; Service Workers run in-app on iOS 16.4+ → Aurorix offline mode works.
- Inline media (video card never forced fullscreen), back/forward swipe gesture, pull-to-refresh, dark launch screen (#0b0d12).
- `imfan.org` navigations stay in-app; every other main-frame link (e.g. Watch on YouTube) opens Safari; YouTube embeds are iframes → always work.
- Offline first-load → dark Retry page; saved/offline content keeps playing once cached.

## Honest limits

- In-app Service Worker needs iOS 16.4+; on older iOS the app is online-only (Safari keeps full offline).
- Push notifications not wired (no NSE) — not part of Aurorix today.
- First ESign trust prompt per device is expected ("Untrusted Developer" → Trust).
