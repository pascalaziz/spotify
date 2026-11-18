import SwiftUI
import WebKit
import AVFoundation
import MediaPlayer
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit
#endif

// Generic WKWebView shell. Reads its target from shell.json inside the app
// bundle ({"url":"https://..."}). The repo contains no product identity:
// URL / display name / bundle id / icons are injected after the build.

struct ShellConfig: Codable {
    var url: URL?
    static func load() -> ShellConfig {
        if let file = Bundle.main.url(forResource: "shell", withExtension: "json"),
           let data = try? Data(contentsOf: file),
           let cfg = try? JSONDecoder().decode(ShellConfig.self, from: data) {
            return cfg
        }
        return ShellConfig(url: nil)
    }
}

let SHELL = ShellConfig.load()
let SHELL_HOST = (SHELL.url?.host ?? "").lowercased()

/* A (device-first): a download URL is allowed if it is THIS site, or a YouTube media CDN host
   captured on-device by the resolver. One gate for start/register/batch_start — never a generic
   fetcher for arbitrary hosts. */
func axDownloadHostOK(_ u: URL) -> Bool {
    let h = (u.host ?? "").lowercased()
    if !SHELL_HOST.isEmpty && (h == SHELL_HOST || h.hasSuffix("." + SHELL_HOST)) { return true }
    if h == "googlevideo.com" || h.hasSuffix(".googlevideo.com") { return true }
    return false
}

struct ShellView: View {
    var body: some View {
        ShellWebView()
    }
}

struct ShellWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        // Music-app audio session (Spotify-style): .playback keeps audio off the ambient/
        // silent-switch path and, with UIBackgroundModes=audio, keeps the app + its
        // Now Playing card alive in the background while media runs.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true               // video stays inline, never forced fullscreen
        config.mediaTypesRequiringUserActionForPlayback = []  // playback follows the site's own tap-to-play
        // Tell the page it runs inside the native shell (native background audio exists,
        // so the web-side keep-alive workaround is disabled there).
        config.userContentController.addUserScript(
            WKUserScript(source: "window.__AX_NATIVE=1;window.__AX_APP_VER='" + Self.appVersion() + "';",
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        // Media bridge: control/event helpers. The page's player stays the brain (queue, UI,
        // state machine) and drives the app's OWN audio engine through __axNativeCtl; the
        // engine reports time/state/end back through __axNativeEvent. The app owns the audio
        // session, the Now Playing card and the lock-screen buttons - the Spotify architecture.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.mediaBridgeJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        // Download bridge: the page hands a ready yt-dlp job (action=serve URL) to the app's
        // background URLSession; iOS transfers it even while the app is suspended. Events come
        // back as 'axbg' CustomEvents; progress only while foreground (page JS is frozen anyway),
        // and a full sync rides UIApplicationWillEnterForeground so the queue can reconcile.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.downloadBridgeJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        /* Notification bridge (2026-11-17): window.axNotify / window.axNotifyPermission ship
           inside downloadBridgeJS above - ONE user script per concern, no stray statics. */
        // default (persistent) data store: cookies + IndexedDB + OPFS survive relaunches,
        // Service Workers run in-app on iOS 16.4+.
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = true
        web.underPageBackgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        web.scrollView.alwaysBounceVertical = true
        context.coordinator.attach(web)

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pullReload), for: .valueChanged)
        web.scrollView.addSubview(refresh)
        context.coordinator.refresh = refresh

        if let url = SHELL.url {
            web.load(URLRequest(url: url))
        } else {
            web.loadHTMLString(Self.unconfiguredHTML, baseURL: nil)
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // Runs in the page from document-start. Small control/event surface for the native
    // audio engine: the page sends commands, the engine sends state.
    /* THE INSTALLED BUILD, FOR THE ADMIN WHO IS TESTING (2026-11-07, his order: the drawer must
       show the app version, owner/admin only, "so we know we downloaded the correct version").
       Read from the bundle so it can never disagree with the binary that is actually running -
       the page-side build token only proves which JS loaded, never which IPA is installed.
       Plain string, injected with __AX_NATIVE in one script: no new bridge, no new handler. */
    static func appVersion() -> String {
        let i = Bundle.main.infoDictionary
        let short = (i?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (i?["CFBundleVersion"] as? String) ?? "?"
        return short + " (" + build + ")"
    }

    static let mediaBridgeJS = """
    (function () {
      if (!window.__AX_NATIVE) return;
      window.__axNativeCtl = function (op, t) {
        try { window.webkit.messageHandlers.axPlay.postMessage({ op: op, t: t || 0 }); } catch (e) {}
      };
      window.__axNativeEvent = function (e) {
        try { window.dispatchEvent(new CustomEvent('axnative', { detail: e })); } catch (err) {}
      };
    })();
    """

    static let downloadBridgeJS = """
    (function () {
      if (!window.__AX_NATIVE) return;
      window.__AX_BG_V2 = true;
      window.axBgDownload = function (spec) {
        try {
          window.webkit.messageHandlers.axBg.postMessage({
            op: 'start', key: String(spec.key), url: String(spec.url), title: String(spec.title || '')
          });
          return true;
        } catch (e) { return false; }
      };
      window.axBgRegister = function (spec) {
        try {
          window.webkit.messageHandlers.axBg.postMessage({
            op: 'register', key: String(spec.key), url: String(spec.url), title: String(spec.title || '')
          });
          return true;
        } catch (e) { return false; }
      };
      window.axBgCancel = function (key) {
        try { window.webkit.messageHandlers.axBg.postMessage({ op: 'cancel', key: String(key) }); } catch (e) {}
      };
      /* Download notification layer (safe fields only: title/percent/byte counts). */
      window.axNotify = function (d) {
        try {
          window.webkit.messageHandlers.axNotify.postMessage({
            kind: String(d.kind || 'progress'), key: String(d.key || ''),
            title: String(d.title || ''), phase: String(d.phase || ''),
            pct: Number(d.pct || 0), got: Number(d.got || 0), total: Number(d.total || 0),
            pkind: String(d.pkind || 'progress'), plId: String(d.plId || ''),
            plName: String(d.plName || ''), doneFiles: Number(d.doneFiles || 0),
            totalFiles: Number(d.totalFiles || 0)
          });
        } catch (e) {}
      };
      window.axNotifyPermission = function () {
        try { window.webkit.messageHandlers.axNotify.postMessage({ kind: 'perm' }); } catch (e) {}
      };
      /* NATIVE BATCH QUEUE (2026-11-18). The page hands the WHOLE list ONCE; iOS then downloads them
         one after another in the background session with no page involvement at all (no per-item
         round trips, no waiting for a render, survives a WebView reload). Same 'axbg' event channel:
         type 'batch' carries the whole queue state, so the panel keeps rendering exactly as before. */
      window.axBatchStart = function (spec) {
        try {
          window.webkit.messageHandlers.axBg.postMessage({
            op: 'batch_start', name: String(spec.name || 'Downloads'),
            items: (spec.items || []).map(function (i) {
              return { key: String(i.key || ''), url: String(i.url || ''), title: String(i.title || '') };
            })
          });
          return true;
        } catch (e) { return false; }
      };
      window.axBatchPause  = function () { try { window.webkit.messageHandlers.axBg.postMessage({ op: 'batch_pause' }); } catch (e) {} };
      window.axBatchResume = function () { try { window.webkit.messageHandlers.axBg.postMessage({ op: 'batch_resume' }); } catch (e) {} };
      window.axBatchCancel = function () { try { window.webkit.messageHandlers.axBg.postMessage({ op: 'batch_cancel' }); } catch (e) {} };
      window.axBatchState  = function () { try { window.webkit.messageHandlers.axBg.postMessage({ op: 'batch_state' }); } catch (e) {} };
      window.__axResolveCbs = {}; window.__axResolveSeq = 0;
      window.__axResolveCb = function (cb, urls) { var r = window.__axResolveCbs[cb]; if (r) { delete window.__axResolveCbs[cb]; r(urls || []); } };
      window.axResolveUrl = function (id, script) {
        return new Promise(function (resolve) {
          try {
            var cb = ++window.__axResolveSeq; window.__axResolveCbs[cb] = resolve;
            window.webkit.messageHandlers.axResolve.postMessage({ id: String(id || ''), script: String(script || ''), cb: cb });
            setTimeout(function () { if (window.__axResolveCbs[cb]) { delete window.__axResolveCbs[cb]; resolve(null); } }, 16000);
          } catch (e) { resolve(null); }
        });
      };
    })();
    """

    private static let unconfiguredHTML = """
    <!doctype html><html><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      html,body{margin:0;height:100%;display:flex;align-items:center;justify-content:center;
        font-family:-apple-system,system-ui,sans-serif;background:#fff;color:#333}
      p{font-size:15px;padding:24px;text-align:center}
    </style></head><body>
    <p>Shell is not configured yet.<br>Add shell.json to the app bundle.</p>
    </body></html>
    """
}

final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var web: WKWebView?
    var refresh: UIRefreshControl?
    private var offlineShown = false
    private var offlineTriedCache = false
    private var remoteConfigured = false

    /* NATIVE DOCUMENT SNAPSHOT (2026-11-07) — the real offline boot.
       WHY THE PREVIOUS FIX WAS NOT ENOUGH: it relied on WKWebView's HTTP cache to answer a
       main-frame navigation with .returnCacheDataDontLoad. Measured on the phone: the chip said
       "offline ready" (the page cannot know) while an offline reopen failed outright — WKWebView
       does not reliably serve a cached MAIN FRAME, whatever the policy. So the shell keeps its OWN
       copy of the document: the rendered HTML after every good load, written to Application
       Support. Offline, that file IS the app. Deterministic, no HTTP-cache semantics involved,
       survives relaunches and app updates until deleted. window.__AX_SHELL_SNAPSHOT tells the page
       the truth, so the chip can only claim "ready" when this copy genuinely exists. */
    private static var snapshotURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ax-shell.html")
    }

    private func saveSnapshot() {
        guard let web = web, SHELL.url != nil else { return }
        web.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            guard let html = result as? String, html.count > 500 else { return }
            try? html.write(to: Self.snapshotURL, atomically: true, encoding: .utf8)
        }
    }

    /// Serve the stored document. `true` means the app is on screen, not an error card.
    private func loadSnapshot() -> Bool {
        guard let html = try? String(contentsOf: Self.snapshotURL, encoding: .utf8), html.count > 500 else { return false }
        offlineShown = true                     // never fall through to the error card afterwards
        web?.evaluateJavaScript("window.__AX_SHELL_SNAPSHOT=1", completionHandler: nil)
        web?.loadHTMLString(html, baseURL: SHELL.url)
        return true
    }

    func attach(_ web: WKWebView) {
        self.web = web
        web.configuration.userContentController.add(self, name: "shellRetry")
        web.configuration.userContentController.add(self, name: "axPlay")
        web.configuration.userContentController.add(self, name: "axBg")
        web.configuration.userContentController.add(self, name: "axNotify")
        web.configuration.userContentController.add(self, name: "axResolve")
        NativePlayer.shared.attach(web)
        AxDownloads.shared.attachWeb(web)
        NativePlayer.shared.refreshBrandArt(shellHost: SHELL_HOST)
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard self?.web != nil else { return }
            NativePlayer.shared.refreshBrandArt(shellHost: SHELL_HOST)
        }
        configureRemoteCommandsIfNeeded()
        // Interruptions (calls, other apps' audio): on .began pause deterministically and
        // keep the card; on .ended re-claim the session + card but never auto-resume -
        // only a user press plays again (his rule, 2026-11-04).
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if AVAudioSession.InterruptionType(rawValue: raw ?? 0) == .began {
                NativePlayer.shared.interrupt()
                return
            }
            NativePlayer.shared.reclaimAfterInterruption()
        }
        // Rare system-level media services reset: same recovery, still no auto-resume.
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                               object: nil, queue: .main) { _ in
            NativePlayer.shared.reclaimAfterInterruption()
        }
    }

    @objc func pullReload() { web?.reload() }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }

        // iframes (embeds, players) always load — never navigate away
        if navigationAction.targetFrame?.isMainFrame != true {
            decisionHandler(.allow)
            return
        }
        if SHELL_HOST.isEmpty { decisionHandler(.allow); return }
        let host = (url.host ?? "").lowercased()
        if host == SHELL_HOST || host.hasSuffix("." + SHELL_HOST) {
            decisionHandler(.allow)
            return
        }
        // other main-frame links → Safari
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    // target="_blank" / window.open → Safari instead of a dead tap
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    // MARK: - Load lifecycle

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh?.endRefreshing()
        offlineShown = false
        offlineTriedCache = false
        // A good load is the moment the document is worth keeping for the offline boot.
        saveSnapshot()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refresh?.endRefreshing()
        showOffline()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refresh?.endRefreshing()
        showOffline()
    }

    /* NATIVE OFFLINE BOOT (2026-11-05, his order: the app must open with no network). Apple gives
       WKWebView no service worker (measured api=0 on the phone), so the WebView's own HTTP cache is
       the only store this app owns. When a navigation fails, FIRST re-ask for the document with
       cachePolicy .returnCacheDataDontLoad: the last stored copy is served with zero network and
       zero expiry (the HTTP max-age window no longer applies). Only when nothing is cached does the
       generic offline card appear. didFinish resets both flags. */
    private func showOffline() {
        guard let web = web, let url = SHELL.url else { return }
        if !offlineTriedCache {
            offlineTriedCache = true
            var req = URLRequest(url: url)
            req.cachePolicy = .returnCacheDataDontLoad
            web.load(req)
            return
        }
        /* THE DETERMINISTIC PATH: the shell's own document copy (see snapshotURL). This is what
           actually opens the app with no network - the HTTP-cache attempt above is only a
           best-effort first try and is known not to be honoured for a main frame. */
        if loadSnapshot() { return }
        guard !offlineShown else { return }
        offlineShown = true
        web.loadHTMLString(Self.offlineHTML, baseURL: nil)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "shellRetry" {
            offlineShown = false
            offlineTriedCache = false
            if let url = SHELL.url { web?.load(URLRequest(url: url)) }
        }
        if message.name == "axResolve", let d = message.body as? [String: Any] {
            /* A: device-resolve. Run YouTube's own player in a hidden resolver WebView, capture the
               media URLs, and call back into the page (same one-way pattern as axBg/axNotify). The
               capture script comes from the website (extractor.js) -> updates via ?v=, no reinstall. */
            let id = d["id"] as? String ?? ""
            let script = d["script"] as? String ?? ""
            let cb = d["cb"] as? Int ?? 0
            AxResolveCenter.shared.resolve(id: id, script: script) { [weak self] urls in
                if let data = try? JSONSerialization.data(withJSONObject: urls, options: []),
                   let json = String(data: data, encoding: .utf8) {
                    self?.web?.evaluateJavaScript("window.__axResolveCb&&window.__axResolveCb(\(cb), \(json))", completionHandler: nil)
                }
            }
        }
        if message.name == "axPlay", let d = message.body as? [String: Any] {
            NativePlayer.shared.message(d)
        }
        if message.name == "axBg", let d = message.body as? [String: Any] {
            let op = d["op"] as? String ?? ""
            if op == "start" {
                // Same-origin only: the app is a download manager for THIS site, never a
                // generic fetcher for whatever URL a page builds.
                if let s = d["url"] as? String, let u = URL(string: s), axDownloadHostOK(u) {
                    AxDownloads.shared.start(key: d["key"] as? String ?? "",
                                             url: u,
                                             title: d["title"] as? String ?? "")
                }
            } else if op == "cancel" {
                AxDownloads.shared.cancel(key: d["key"] as? String ?? "")
            } else if op == "batch_start" {
                var bItems: [[String: String]] = []
                if let raw = d["items"] as? [[String: Any]] {
                    for it in raw {
                        guard let ks = it["key"] as? String, !ks.isEmpty,
                              let us = it["url"] as? String, let u = URL(string: us),
                              axDownloadHostOK(u) else { continue }
                        bItems.append(["key": ks, "url": us, "title": it["title"] as? String ?? ""])
                    }
                }
                AxBatch.shared.start(name: d["name"] as? String ?? "Downloads", items: bItems)
            } else if op == "batch_pause" {
                AxBatch.shared.pause()
            } else if op == "batch_resume" {
                AxBatch.shared.resume()
            } else if op == "batch_cancel" {
                AxBatch.shared.cancelAll()
            } else if op == "batch_state" {
                AxBatch.shared.report()
            } else if op == "register" {
                if let s = d["url"] as? String, let u = URL(string: s), axDownloadHostOK(u) {
                    AxDownloads.shared.register(key: d["key"] as? String ?? "",
                                                url: u,
                                                title: d["title"] as? String ?? "")
                }
            }
        }
        if message.name == "axNotify", let d = message.body as? [String: Any] {
            AxNotify.shared.message(d)
        }
    }

    // MARK: - Lock screen / widget buttons
    // Every command routes through the page's own player methods, so the queue, the UI and
    // the diagnostics all update on the same single path a screen tap uses. In native audio
    // mode those methods forward to the app's engine; in web mode (video/embeds) they drive
    // the element exactly as before. One command center, both modes.

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            NativePlayer.shared.engageResume()
            self?.js("window.axPlayer&&window.axPlayer.play()"); return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            NativePlayer.shared.engagePause()
            self?.js("window.axPlayer&&window.axPlayer.pause()"); return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            if !NativePlayer.shared.nativeAdvance(1) { self?.js("window.axPlayer&&window.axPlayer.next()") }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            if !NativePlayer.shared.nativeAdvance(-1) { self?.js("window.axPlayer&&window.axPlayer.prev()") }
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            NativePlayer.shared.engageSeek(t)
            self?.js("window.axPlayer&&window.axPlayer.seekTo(\(t))"); return .success
        }
    }

    private func js(_ script: String) {
        web?.evaluateJavaScript(script, completionHandler: nil)
    }

    private static let offlineHTML = """
    <!doctype html><html><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <style>
      html,body{margin:0;height:100%;background:#0b0d12;color:#e8eef2;
        font-family:-apple-system,'SF Pro Text',system-ui,sans-serif;
        display:flex;align-items:center;justify-content:center}
      .c{text-align:center;padding:32px;max-width:340px}
      h1{font-size:22px;margin:0 0 10px}
      p{font-size:15px;line-height:1.5;color:#9aa7b2;margin:0 0 26px}
      button{background:#22d3ee;color:#04222a;font-size:16px;font-weight:600;
        border:0;border-radius:12px;padding:14px 40px;min-height:44px}
      button:active{opacity:.8}
    </style></head><body>
    <div class="c">
      <h1>You&rsquo;re offline</h1>
      <p>A connection is needed the first time the app opens. Saved content keeps working once it&rsquo;s cached.</p>
      <button onclick="window.webkit.messageHandlers.shellRetry.postMessage(0)">Retry</button>
    </div>
    </body></html>
    """
}

// MARK: - Native audio engine (the Spotify part)
// The app itself plays the track: AVPlayer holds the audio session with real I/O, so a
// paused player keeps the session valid and the app unsuspended - no keep-alive tricks.
// The page hands the file over in base64 chunks (its storage is sandboxed to the webview),
// then commands it like a remote: resume / pause / seek / (next & prev stay page-side,
// because the queue lives there). State flows back as 'axnative' events.

final class NativePlayer: NSObject {
    static let shared = NativePlayer()
    private var av: AVPlayer?
    private var timeObs: Any?
    private var rateObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var buf = Data()
    private var autoPlay = true
    private var engaged = false
    private var artURL = ""
    private var artFetchURL = ""
    private var artFailed = Set<String>()
    private let artCache = NSCache<NSString, UIImage>()
    /* ARTWORK ON DISK (2026-11-08, his report: the lock-screen widget shows the brand image instead
       of the track's own cover). The image was only ever held in an NSCache, so a downloaded track
       played offline had nothing to draw and fell back to the bundled brand art - exactly what he
       photographed. Each cover is now written next to the library files under its track key, which
       makes it permanent: fetched once online, used forever, offline included. */
    /* A WORK QUEUE FOR COVERS (2026-11-08, his report: "you fixed it for 1 mp3 only however it must
       for all downloaded mp3/mp4"). Fetching art only when a track was played meant one cover per
       session. The page now ships the whole library's key+url pairs, and this drains them one at a
       time in the background: sequential on purpose, so a big library never opens 40 sockets at once
       and never competes with the audio stream for bandwidth. */
    private var artQueue: [(String, String)] = []
    private var artBusy = false
    private func artDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("ax-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func artDiskURL(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return artDir().appendingPathComponent("ax-a-" + safe + ".img")
    }
    /* CHEAP "IS IT SAVED?" (2026-11-08). diskArt DECODES the image; the queue and the guards only
       need to know whether a file is there. With a 200-item library the old check would have decoded
       200 covers on the main thread every time the library was re-sent - a visible hitch for no
       benefit. Existence is a stat() call. */
    private func hasArt(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: artDiskURL(key).path)
    }
    private func diskArt(_ key: String) -> UIImage? {
        guard !key.isEmpty else { return nil }
        let u = artDiskURL(key)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return UIImage(contentsOfFile: u.path)
    }
    private var title = ""
    private var artist = ""
    private var dur = 0.0
    /* NATIVE QUEUE (2026-11-05): the page ships the list of downloaded items + their card
       meta, and pre-streams the next playable file. Widget next/prev and auto-advance then
       run 100% natively (iOS freezes page JS in the background - JS-dependent next/prev
       did nothing from the lock screen). Wrap rule is his: #3 -> #1; single file replays. */
    private var manifest: [[String: Any]] = []
    private var mIndex = 0
    private var curKey = ""
    private var preBuf = Data()
    private var preKey = ""
    private var preLib = false
    private var libKeys = Set<String>()
    weak var web: WKWebView?

    func attach(_ web: WKWebView) {
        self.web = web
        if endObs == nil {
            endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                            object: nil, queue: .main) { [weak self] _ in
                self?.ended()
            }
        }
    }

    func message(_ d: [String: Any]) {
        let op = d["op"] as? String ?? ""
        switch op {
        case "start":
            buf = Data()
            autoPlay = (d["play"] as? Bool) ?? true
            title = (d["title"] as? String) ?? "Track"
            artist = (d["artist"] as? String) ?? ""
            dur = (d["dur"] as? Double) ?? 0
            artURL = (d["art"] as? String) ?? ""
            curKey = (d["k"] as? String) ?? ""
            if let s = d["data"] as? String, let dd = Data(base64Encoded: s) { buf.append(dd) }
        case "chunk":
            if let s = d["data"] as? String, let dd = Data(base64Encoded: s) { buf.append(dd) }
        case "finish":
            load()
        case "manifest":
            manifest = (d["items"] as? [[String: Any]]) ?? []
            if let i = d["index"] as? Int { mIndex = i }
            /* A FRESH MANIFEST MEANS THE PAGE IS ALIVE AND ONLINE - so this is the moment to retry
               any cover that failed earlier in this launch, and to pull the queue's artwork to disk
               before it is needed offline. */
            artFailed.removeAll()
            prefetchArt(manifest)
        case "artprefetch":
            /* THE WHOLE DOWNLOADED LIBRARY (2026-11-08). Items already on disk are skipped by the
               drain, so a repeat call costs nothing. */
            let arr = (d["items"] as? [[String: Any]]) ?? []
            artQueue = arr.compactMap { it -> (String, String)? in
                guard let k = it["k"] as? String, let u = it["u"] as? String,
                      !k.isEmpty, !u.isEmpty else { return nil }
                return (k, u)
            }
            drainArt()
        case "pstart":
            // preload stream: dropped if the file is already cached (dup preload is harmless)
            let k = (d["k"] as? String) ?? ""
            let toLib = (d["lib"] as? Bool) ?? false
            preBuf = Data()
            if toLib {
                // LIBRARY stream REPLACES: a re-download means fresh bytes, never serve stale
                preKey = k; preLib = true
            } else {
                preKey = FileManager.default.fileExists(atPath: trackURL(k).path) ? "" : k
                preLib = false
            }
            if let s = d["data"] as? String, let dd = Data(base64Encoded: s), !preKey.isEmpty { preBuf.append(dd) }
        case "pchunk":
            if let s = d["data"] as? String, let dd = Data(base64Encoded: s), !preKey.isEmpty { preBuf.append(dd) }
        case "pfinish":
            if !preKey.isEmpty, !preBuf.isEmpty {
                try? preBuf.write(to: preLib ? libURL(preKey) : trackURL(preKey), options: .atomic)
                if preLib { emit("{type:'mirrored',k:" + jsonStr(preKey) + "}") }
            }
            preKey = ""
            preLib = false
            pruneTrackCache()
        case "libsync":
            libKeys = Set(((d["items"] as? [[String: Any]]) ?? []).compactMap { $0["k"] as? String })
            libGC()
        case "libquery":
            // THE ENGINE'S DISK IS A SOURCE OF TRUTH (2026-11-05, user: "downloads are real files
            // that die only with the app"). iOS may evict the page's web store under storage
            // pressure, but this library's files (Application Support) persist until the app is
            // deleted. The page asks which of these keys it can still play FROM DISK - badges,
            // the on-device counter and the widget manifest then stay truthful even with an
            // evicted web store. Reply echoes the asked keys so the page can cache negatives.
            let ks = (d["ks"] as? [String]) ?? []
            let fm = FileManager.default
            let have = ks.filter { fm.fileExists(atPath: libURL($0).path) || fm.fileExists(atPath: trackURL($0).path) }
            emit("{type:'libquery',have:[" + have.map(jsonStr).joined(separator: ",") + "],ks:[" + ks.map(jsonStr).joined(separator: ",") + "]}")
        case "libplay":
            // The page store lost the bytes but the engine's library still holds the real file:
            // play it natively from disk - identical to a handoff, zero bytes transferred.
            // attachPlayer sets engaged, so widget next/prev keeps working from this file too.
            let k = (d["k"] as? String) ?? ""
            if !k.isEmpty {
                let fm = FileManager.default
                var url: URL? = fm.fileExists(atPath: trackURL(k).path) ? trackURL(k) : nil
                if url == nil { let lu = libURL(k); if fm.fileExists(atPath: lu.path) { url = lu } }
                if let u = url {
                    autoPlay = (d["play"] as? Bool) ?? true
                    title = (d["title"] as? String) ?? "Track"
                    artist = (d["artist"] as? String) ?? ""
                    dur = (d["dur"] as? Double) ?? 0
                    artURL = (d["art"] as? String) ?? ""
                    curKey = k
                    if let i = manifest.firstIndex(where: { ($0 as? [String: Any])?["k"] as? String == k }) { mIndex = i }
                    attachPlayer(u)
                    if autoPlay { claim(); av?.play() }
                    card()
                    pruneTrackCache()
                }
            }
        case "resume":
            claim()
            rewindIfEnded()
            av?.play()
        case "pause":
            av?.pause()
        case "seek":
            if let t = d["t"] as? Double {
                av?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
                card()
            }
        case "release":
            /* THE PAGE CLOSED THE PLAYER: THE OS CARD MUST GO WITH IT (2026-11-07, his report:
               closing the mp3/mp4 left the lock-screen widget sitting there). Clearing
               nowPlayingInfo alone does NOT dismiss it - iOS keeps the card while the audio
               session is still active and the remote commands still answer. So this is a full
               stand-down: stop, clear, mark stopped, hand the session back, drop the commands. */
            releaseAll()
        default:
            break
        }
    }

    private func load() {
        guard !buf.isEmpty else { emit("{type:'error'}"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ax-track.mp3")
        do { try buf.write(to: url, options: .atomic) } catch { emit("{type:'error'}"); return }
        if !curKey.isEmpty {
            try? buf.write(to: trackURL(curKey), options: .atomic)   // keyed copy: native replay/advance cache
            try? buf.write(to: libURL(curKey), options: .atomic)     // library copy: persistent, survives restarts
        }
        attachPlayer(url)
        if autoPlay { claim(); av?.play() }
        card()
        pruneTrackCache()
    }

    private func attachPlayer(_ url: URL) {
        if let o = timeObs, let p = av { p.removeTimeObserver(o) }
        rateObs?.invalidate()
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        av = player
        engaged = true
        rateObs = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            self?.state(playing: p.rate > 0)
        }
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                 queue: .main) { [weak self] t in
            self?.tick(t.seconds)
        }
    }

    /* Per-item cached file (from a handoff finish or a preload stream). Extension REQUIRED - see
       mediaExt above: AVPlayer refuses an extensionless file with "Cannot Open". */
    private func trackURL(_ k: String) -> URL {
        let safe = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
        return FileManager.default.temporaryDirectory.appendingPathComponent("ax-t-" + safe + "." + mediaExt(k))
    }

    /* NATIVE LIBRARY (2026-11-05, his order: "exact as Spotify, unlimited"): downloaded
       files mirrored into the app's OWN storage (Application Support), so widget next/prev
       reads native disk for ANY item - 3 or 100 - with zero page JS and zero dependence on
       the frozen webview. Filled by the page's trickle while the app is open; persistent;
       garbage-collected on libsync when items leave the queue. The 6-file rolling cache
       (ax-t-*, temp dir) never touches these files. */
    /* THE FILE NAME MUST CARRY ITS CONTAINER EXTENSION (2026-11-07, root cause of his silent widget).
       libName/trackURL wrote `ax-l-<key>` with NO suffix. The bytes were all there (his diag:
       size=844604) but AVPlayerItem(url:) infers the container from the extension, so an
       extensionless file fails with exactly "Cannot Open" - the card updated and the audio never
       started. Derive .mp3/.mp4/.m4a from the key (the downloader keys end in `_mp3_best` /
       `_mp4_best` / `_<fmt>`), and fall back to sniffing the first bytes so an unusual key still
       plays. Everything else about the stream is unchanged. */
    private func mediaExt(_ k: String, firstBytes: Data? = nil) -> String {
        let low = k.lowercased()
        if low.contains("_mp4") || low.hasSuffix("mp4") { return "mp4" }
        if low.contains("_m4a") || low.hasSuffix("m4a") { return "m4a" }
        if low.contains("_mp3") || low.hasSuffix("mp3") { return "mp3" }
        if let b = firstBytes, b.count >= 12 {
            let h = [UInt8](b.prefix(12))
            if h[4] == 0x66 && h[5] == 0x74 && h[6] == 0x79 && h[7] == 0x70 { return "mp4" }   // ftyp
            if h[0] == 0x49 && h[1] == 0x44 && h[2] == 0x33 { return "mp3" }                    // ID3
            if h[0] == 0xFF && (h[1] & 0xE0) == 0xE0 { return "mp3" }                            // frame sync
        }
        return "mp3"
    }
    /* INTERNAL BRIDGE for AxDownloads (2026-11-15): the background manager must write the
       finished file to the EXACT path libquery/libplay read - same directory, same name, same
       extension rule - or offline playback would silently miss native transfers. */
    func bgLibURL(_ k: String) -> URL { libURL(k) }

    private func libName(_ k: String) -> String {
        "ax-l-" + (k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k) + "." + mediaExt(k)
    }
    private func libURL(_ k: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ax-library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let named = dir.appendingPathComponent(libName(k))
        if FileManager.default.fileExists(atPath: named.path) { return named }
        /* FILES MIRRORED BEFORE THE EXTENSION FIX MUST STILL PLAY (2026-11-07). Builds up to
           1.51.0 wrote `ax-l-<key>` with no suffix, so his existing mirror is all extensionless.
           Rename it to the correct name on first use instead of re-downloading: same bytes, now
           openable. Reads the old path only when the new one is absent, so nothing is lost. */
        let old = dir.appendingPathComponent("ax-l-" + (k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k))
        if FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: named)
            if FileManager.default.fileExists(atPath: named.path) { return named }
        }
        return named
    }
    private func libGC() {
        let fm = FileManager.default
        /* NEVER SWEEP ON AN EMPTY KEY SET (2026-11-08). libsync carries the page's list; a transient
           empty or half-built list would otherwise delete EVERY library file - and now every saved
           cover - because "not in libKeys" is true for all of them. His standing rule is that
           downloads are real files that die only with the app, so an empty list means "no
           information", never "delete everything". */
        guard !libKeys.isEmpty else { return }
        let dir = libURL("").deletingLastPathComponent()
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("ax-l-") {
            var name = String(f.lastPathComponent.dropFirst(5))
            /* THE EXTENSION IS NOT PART OF THE KEY (2026-11-07). Names now end in .mp3/.mp4, and
               comparing the full name against libKeys (which holds bare keys) matched NOTHING - so
               every mirrored file would have been garbage-collected on the next libsync. Strip the
               suffix first; also tolerate the pre-fix extensionless names. */
            if let dot = name.lastIndex(of: "."), name.distance(from: name.startIndex, to: dot) > 0 {
                let ext = name[name.index(after: dot)...].lowercased()
                if ext == "mp3" || ext == "mp4" || ext == "m4a" { name = String(name[..<dot]) }
            }
            let raw = name.removingPercentEncoding ?? name
            if !libKeys.contains(raw) && !libKeys.contains(name) { try? fm.removeItem(at: f) }
        }
        /* COVERS FOLLOW THEIR TRACKS (2026-11-08). The art cache is per key, so without this it
           would grow forever as playlists change. Same rule as the library files: anything whose
           key is no longer in the queue is removed. One GC, two directories. */
        if let artFiles = try? fm.contentsOfDirectory(at: artDir(), includingPropertiesForKeys: nil) {
            for f in artFiles where f.lastPathComponent.hasPrefix("ax-a-") {
                var name = String(f.lastPathComponent.dropFirst(5))
                if name.hasSuffix(".img") { name = String(name.dropLast(4)) }
                let raw = name.removingPercentEncoding ?? name
                if !libKeys.contains(raw) && !libKeys.contains(name) { try? fm.removeItem(at: f) }
            }
        }
    }
    private func jsonStr(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /* Keep the newest ~6 cached tracks; the currently playing file is never dropped. */
    private func pruneTrackCache() {
        let fm = FileManager.default
        let dir = FileManager.default.temporaryDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var tracks = files.filter { $0.lastPathComponent.hasPrefix("ax-t-") }
        guard tracks.count > 6 else { return }
        let curName = curKey.isEmpty ? "" : trackURL(curKey).lastPathComponent
        tracks = tracks.filter { $0.lastPathComponent != curName }
        let sorted = tracks.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for f in sorted.suffix(from: 6) { try? fm.removeItem(at: f) }
    }

    /* Play a cached manifest item natively - no page JS involved. Syncs the page on wake
       via the 'jump' event (queue index rides along). */
    private func playFromCache(_ idx: Int) -> Bool {
        guard idx >= 0, idx < manifest.count, let it = manifest[idx] as? [String: Any],
              let k = it["k"] as? String else { return false }
        let url: URL
        let cu = trackURL(k)
        if FileManager.default.fileExists(atPath: cu.path) { url = cu }
        else {
            let lu = libURL(k)                                  // engine library: unlimited native jumps
            guard FileManager.default.fileExists(atPath: lu.path) else { return false }
            url = lu
        }
        title = (it["t"] as? String) ?? "Track"
        artist = (it["a"] as? String) ?? ""
        dur = (it["d"] as? Double) ?? 0
        artURL = (it["u"] as? String) ?? ""
        curKey = k
        mIndex = idx
        attachPlayer(url)
        claim()
        av?.play()
        card()
        pruneTrackCache()
        emit("{type:'jump',i:\(idx),q:\(it["q"] as? Int ?? -1),k:\(jsonStr(k))}")
        /* ADVANCE DIAGNOSTIC (2026-11-07, his report: the widget changes track but stays SILENT).
           The card updating proves this function ran and found a file, so the failure is after it -
           either the file is incomplete, the player errored, or play() never took. Report the file,
           its size, the item's error and the player's rate once it has had time to start. */
        let sz = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        let jsonK = jsonStr(k)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self else { return }
            let r = self.av?.rate ?? -1
            let err = self.av?.currentItem?.error?.localizedDescription ?? ""
            let st = self.av?.currentItem?.status.rawValue ?? -1
            self.emit("{type:'advdiag',idx:\(idx),k:\(jsonK),size:\(sz),rate:\(r),st:\(st),err:\(self.jsonStr(err))}")
        }
        return true
    }

    /* Widget next/prev: native first (wrap always - his rule), page JS only as fallback
       (app foreground), because the page is frozen when the app is backgrounded. */
    func nativeAdvance(_ dir: Int) -> Bool {
        guard engaged, !manifest.isEmpty else { return false }
        if manifest.count == 1 {           // his rule: a single file answers by replaying itself
            claim(); av?.seek(to: .zero); av?.play(); card(); return true
        }
        var idx = mIndex + dir
        if idx >= manifest.count { idx = 0 }
        if idx < 0 { idx = manifest.count - 1 }
        return playFromCache(idx)
    }

    private func tick(_ t: Double) {
        let d = av?.currentItem?.duration.seconds ?? 0
        let dur2 = (d.isFinite && d > 0) ? d : dur
        if dur2 > 0 && dur != dur2 { dur = dur2 }   // learn the REAL duration -> the card's line + times
        emit("{type:'time',t:\(t),dur:\(dur2)}")
        card()
    }

    private func state(playing: Bool) {
        emit("{type:'state',playing:\(playing)}")
        card()   // the ticks stop while paused - the card's rate/glyph must be restated here
    }

    private func ended() {
        state(playing: false)
        /* NATIVE AUTO-ADVANCE: the page is usually frozen when a track ends from the lock
           screen, so its 'ended' JS can never run. Advance natively to the next CACHED
           item; stop like Spotify at the end of the downloaded list (his no-press rule). */
        if engaged, !manifest.isEmpty, mIndex + 1 < manifest.count, playFromCache(mIndex + 1) { return }
        emit("{type:'ended'}")
    }

    private func emit(_ json: String) {
        web?.evaluateJavaScript("window.__axNativeEvent&&window.__axNativeEvent(\(json))",
                                completionHandler: nil)
    }

    private func card() {
        /* NEVER RESTATE A CARD AFTER A RELEASE (2026-11-07). releaseAll() sets engaged = false and
           drops the player; without this guard a late tick or a state event would republish an
           EMPTY nowPlayingInfo and pop the widget straight back up after he closed it. */
        guard engaged, av != nil else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        if dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur }
        if let t = av?.currentTime().seconds, t.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, t) }
        info[MPNowPlayingInfoPropertyPlaybackRate] = ((av?.rate ?? 0) > 0) ? 1.0 : 0.0
        if let img = currentArt() {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        /* The card's own state, stated in the same place the info is: playing while the player
           runs, paused while it is held. This is what makes the widget's buttons match the audio. */
        MPNowPlayingInfoCenter.default().playbackState = ((av?.rate ?? 0) > 0) ? .playing : .paused
        maybeFetchArt()
    }

    // Artwork: the track's thumbnail (page-sent URL, cached) with the bundled brand
    // art as the standing fallback. Fetch is async; the card is restated on arrival.
    private lazy var defaultArt: UIImage? = UIImage(named: "nowplaying")
    /* ADMIN BRAND AS THE NATIVE FALLBACK ART (2026-11-15): "branding everywhere". The app's own
       artwork fallback tracks the logo configured in Admin -> Website Details: fetched from
       brand.json on launch/foreground, cached on disk (ax-library/ax-brand-logo.png), swapped ONLY
       after a successful image decode, and never shown while the track has its own cover. The
       bundled nowplaying.png stays the final fallback (first-ever offline run). */
    private var brandArt: UIImage?
    private var brandFetchedURL = ""

    private func currentArt() -> UIImage? {
        /* DISK FIRST (2026-11-08): a cover already saved for this track is the truth, and it is the
           only thing that can work with no network. Then the memory cache for the current URL. */
        if let img = diskArt(curKey) {
            if !artURL.isEmpty { artCache.setObject(img, forKey: artURL as NSString) }
            return img
        }
        if !artURL.isEmpty, let img = artCache.object(forKey: artURL as NSString) { return img }
        if let b = brandArt { return b }
        return defaultArt
    }

    /* One light refresh: brand.json is tiny and no-store; the image itself is only re-downloaded
       when its URL actually changed (the site cache-busts it with ?v=content-hash). Failures are
       silent: the bundled art (or last cached brand art) keeps standing in. */
    func refreshBrandArt(shellHost: String) {
        guard !shellHost.isEmpty,
              let url = URL(string: "https://" + shellHost + "/brand.json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let logo = obj["logo"] as? String, !logo.isEmpty else { return }
            guard logo != self.brandFetchedURL else { return }
            self.brandFetchedURL = logo
            guard let iu = URL(string: logo) else { return }
            URLSession.shared.dataTask(with: iu) { [weak self] imgData, _, _ in
                guard let self = self, let imgData = imgData,
                      imgData.count > 512, let img = UIImage(data: imgData) else { return }
                let fm = FileManager.default
                let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
                let dir = base.appendingPathComponent("ax-library", isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? imgData.write(to: dir.appendingPathComponent("ax-brand-logo.png"), options: .atomic)
                DispatchQueue.main.async {
                    self.brandArt = img
                    self.card()
                }
            }.resume()
        }.resume()
    }

    private func maybeFetchArt() {
        fetchArt(url: artURL, key: curKey, thenRefreshCard: true)
    }

    /* ONE fetch path for both the current track and the prefetch sweep. Success is written to disk
       under the TRACK KEY (not the URL), so the same cover is found again by key even if the
       thumbnail URL later changes, and it survives relaunch and airplane mode. */
    private func fetchArt(url u: String, key k: String, thenRefreshCard: Bool) {
        guard !u.isEmpty, !k.isEmpty, !artFailed.contains(u),
              !hasArt(k),
              artCache.object(forKey: u as NSString) == nil,
              artFetchURL != u,
              let url = URL(string: u) else { return }
        artFetchURL = u
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let img = UIImage(data: data) else {
                // ONE attempt per URL per launch: offline/dead thumbnails must not re-fetch on
                // every card() tick (0.5s while playing).
                DispatchQueue.main.async { self?.artFailed.insert(u); self?.artFetchURL = "" }
                return
            }
            if let self = self { self.storeArt(data, img: img, key: k, url: u) }
            DispatchQueue.main.async {
                self?.artFetchURL = ""
                if thenRefreshCard { self?.card() }
            }
        }.resume()
    }

    /* PRE-FETCH THE QUEUE'S COVERS (2026-11-08). Waiting until a track is played means the one cover
       that matters (the next one the widget will show) may never have been fetched while there was
       a network. When the page ships a manifest, the first few covers are pulled to disk in the
       background - bounded, sequential, and skipped for anything already saved. */
    private func prefetchArt(_ items: [[String: Any]]) {
        var n = 0
        for it in items {
            if n >= 6 { break }
            let k = (it["k"] as? String) ?? ""
            let u = (it["u"] as? String) ?? ""
            guard !k.isEmpty, !u.isEmpty, !hasArt(k), !artFailed.contains(u) else { continue }
            n += 1
            fetchArt(url: u, key: k, thenRefreshCard: false)
        }
    }

    /* Drain the library queue one cover at a time. Anything already saved (or already failed this
       launch) is skipped without a network call, so re-sending the library is cheap. */
    private func drainArt() {
        guard !artBusy else { return }
        while let next = artQueue.first {
            artQueue.removeFirst()
            if hasArt(next.0) || artFailed.contains(next.1) { continue }
            artBusy = true
            fetchArtQueued(url: next.1, key: next.0) { [weak self] ok in
                guard let self = self else { return }
                self.artBusy = false
                if ok, self.curKey == next.0 { self.card() }   // the widget is showing this one
                self.drainArt()
            }
            return
        }
    }

    private func fetchArtQueued(url u: String, key k: String, done: @escaping (Bool) -> Void) {
        guard let url = URL(string: u) else { done(false); return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { done(false); return }
            guard let data = data, let img = UIImage(data: data) else {
                DispatchQueue.main.async { self.artFailed.insert(u); done(false) }
                return
            }
            self.storeArt(data, img: img, key: k, url: u)
            DispatchQueue.main.async { done(true) }
        }.resume()
    }

    /* One writer for both paths: disk under the track key, plus the memory cache keyed by URL. */
    private func storeArt(_ data: Data, img: UIImage, key: String, url: String) {
        try? data.write(to: artDiskURL(key), options: .atomic)
        artCache.setObject(img, forKey: url as NSString)
    }

    // Direct widget paths: the engine answers play/pause/seek INSTANTLY, even if the
    // page's JS is momentarily unscheduled. The page still gets the command for state/UI.
    // Guarded by `engaged` so a web-path track (video/embed) is never hijacked.
    func engagePause() { guard engaged else { return }; av?.pause() }
    func engageResume() { guard engaged else { return }; claim(); rewindIfEnded(); av?.play() }
    func engageSeek(_ t: Double) { guard engaged else { return }; av?.seek(to: CMTime(seconds: t, preferredTimescale: 600)); card() }

    // (Re)claim the audio session. Another app's audio (Facebook Reels, a call) deactivates
    // ours mid-play; every play attempt must re-activate first or the play silently fails
    // and iOS hands the Now Playing card to the interrupting app - the "instant die" bug.
    private func claim() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
        setCommands(true)   // a released player disabled them; any new track re-enables them
    }

    /* ============ THE STAND-DOWN THAT ACTUALLY DISMISSES THE CARD ============
       2026-11-07. Closing the player must also close the lock-screen widget - they are one thing
       to the user. On iOS the card is not driven by nowPlayingInfo alone: it survives while the
       audio session is active AND while the remote commands still report themselves as available.
       So a real close does all four: stop and drop the player, clear the info, declare the state
       stopped, deactivate the session, and disable the five commands. setCommands(true) in
       claim() puts them back the moment any track starts again. */
    private func releaseAll() {
        av?.pause()
        av = nil
        engaged = false
        title = ""; artist = ""; dur = 0; curKey = ""; artURL = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        setCommands(false)
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var commandsOn = true
    private func setCommands(_ on: Bool) {
        guard commandsOn != on else { return }
        commandsOn = on
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = on
        cc.pauseCommand.isEnabled = on
        cc.nextTrackCommand.isEnabled = on
        cc.previousTrackCommand.isEnabled = on
        cc.changePlaybackPositionCommand.isEnabled = on
    }

    // Interruption began (another app took the audio): pause deterministically, card alive.
    func interrupt() {
        av?.pause()
        card()
    }

    // Interruption ended / media services reset: take the session + card back, but NEVER
    // auto-resume - only a user press plays again (his rule).
    func reclaimAfterInterruption() {
        claim()
        card()
    }

    // A finished item has rate 0 at its end: pressing Play must RESTART it, not no-op
    // (Spotify replays the last track). _onQueueEnd already rewound the page-side clock;
    // this covers every other ended state.
    private func rewindIfEnded() {
        guard let item = av?.currentItem else { return }
        let d = item.duration.seconds
        let t = av?.currentTime().seconds ?? 0
        if d.isFinite, d > 0, t >= d - 0.15 { av?.seek(to: .zero) }
    }
}


// MARK: - Background download manager (URLSession background configuration, 2026-11-15)
// The page hands a READY yt-dlp job's serve URL (our own origin only) plus the media key it
// uses everywhere else. iOS transfers the file even while the app is suspended, keeps going
// across network switches, and wakes the app for completion; the bytes land directly in the
// engine library (Application Support/ax-library/ax-l-<key>) - the exact file the page's
// axDlHasBytes / libquery / libplay already read, so offline playback needs no extra copy.
final class AxDownloads: NSObject {
    static let shared = AxDownloads()
    private static let sessionID = "ax.bgdl.v1"

    private var session: URLSession!
    private weak var web: WKWebView?
    private var bgCompletion: (() -> Void)?

    /* key -> meta, persisted: a relaunch that happens ONLY to deliver session events still needs
       the title/url to finish the bookkeeping correctly. */
    private var meta: [String: [String: String]] = [:]
    private var pending: [String: String] = [:]
    /* WAIT-READY RETRIES: backgrounding during the server rip phase hands a serve URL whose job
       is not final yet; the serve answers 404 JSON. The engine used to save that JSON AS the
       media. Now: content-validated, and retried NATIVELY with earliestBeginDate so iOS re-runs
       the task in the background daemon (no app wake-up needed) until the file is ready. */
    private var retries: [String: Int] = [:]
    /* RESUME-RETRY BUDGET (2026-11-18): how many times this key has been re-armed from Apple's resume
       data. Bounded so a permanently broken URL cannot loop, but never resets the byte offset. */
    private var resumeTries: [String: Int] = [:]
    private static let maxWaitRetries = 80          // 80 x 15 s = 20 min (the rip ceiling)
    private static let retryDelay: TimeInterval = 15
    /* SPOTIFY-STYLE BACKGROUND HANDOFF (his order: downloads must continue when he switches apps
       or turns the screen off). The page REGISTERS its active transfer here while the app is in
       the FOREGROUND; the moment the app goes to the background, this session starts the transfer
       itself — iOS runs background downloads in a separate process while the app is suspended.
       In-memory only: a registration that was never started dies with this launch, which is
       exactly right — the page re-registers on its next transfer. */

    private override init() {
        super.init()
        meta = (UserDefaults.standard.object(forKey: "ax.bg.meta") as? [String: [String: String]]) ?? [:]
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.isDiscretionary = false                 // download now, not "when the system feels like it"
        cfg.sessionSendsLaunchEvents = true
        cfg.waitsForConnectivity = true             // flaky home Wi-Fi: wait instead of erroring
        cfg.timeoutIntervalForRequest = 15 * 60
        cfg.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        // Foreground: hand the page a full task table so its download queue can reconcile
        // whatever advanced (or finished) while it was frozen.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.syncToPage()
        }
        // Background: TAKE OVER every registered transfer. This is the Spotify-style moment —
        // the web page is about to freeze, so the native session must own the bytes now.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.startAllRegistered()
            self?.snapshotNotifications()
        }
        /* BACKGROUND TAKEOVER (2026-11-17, his order: downloads must survive app-switch/screen-off).
           The web layer cannot be trusted to react at hide-time — iOS freezes WKWebView JS around
           the moment the app backgrounds, so the page's own visibilitychange handover is missed.
           The APP therefore pulls the active transfer from the page at background-time: the page
           exposes window.__axBgTakeover() -> {key,url,title} for its in-flight transfer (or null).
           Apple: background URLSession download tasks "continue even when your app is in the
           suspended state or otherwise not running" — exactly the Spotify-style behavior. */
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.web != nil else { return }
            self.web?.evaluateJavaScript(
                "(function(){try{return JSON.stringify(window.__axBgTakeover?window.__axBgTakeover():null)}catch(e){return \"null\"}})()",
                completionHandler: { res, _ in
                    guard let s = res as? String,
                          let data = s.data(using: .utf8),
                          let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let key = spec["key"] as? String, !key.isEmpty,
                          let u = spec["url"] as? String, let url = URL(string: u) else { return }
                    let host = (url.host ?? "").lowercased()
                    guard !SHELL_HOST.isEmpty, host == SHELL_HOST || host.hasSuffix("." + SHELL_HOST) else { return }
                    let title = spec["title"] as? String ?? ""
                    let waitReady = (spec["wait"] as? Bool) == true || (spec["wait"] as? Int ?? 0) == 1
                    DispatchQueue.main.async { self.start(key: key, url: url, title: title, waitReady: waitReady) }
                })
        }
    }

    func attachWeb(_ w: WKWebView?) { web = w }

    /* Used by AxBatch: one 'batch' event carries the whole queue state. */
    func emitBatch(_ json: String) { emitRaw(json) }

    /* LOCK SCREEN AT THE MOMENT OF BACKGROUNDING (2026-11-18): the previous design only posted a
       progress notification from the NEXT delegate callback, which on a slow link can be many seconds
       after the user locks the screen - so the Lock Screen looked empty. This pushes the live byte
       counts immediately, for every task the background session owns. */
    private func snapshotNotifications() {
        session.getAllTasks { [weak self] ts in
            guard let self = self else { return }
            for t in ts {
                guard let k = t.taskDescription, !k.isEmpty else { continue }
                let got = Int(t.countOfBytesReceived)
                let total = Int(max(0, t.countOfBytesExpectedToReceive))
                DispatchQueue.main.async {
                    AxNotify.shared.progressNow(key: k, title: self.meta[k]?["title"] ?? k, got: got, total: total)
                }
            }
        }
    }

    func handleBackgroundEvents(_ completionHandler: @escaping () -> Void) {
        bgCompletion = completionHandler
    }

    /* The page's queue promise must ALWAYS get an answer for a handoff. Three states:
       1. bytes already in the library under this key (a previous transfer finished but its
          'done' event was lost) -> answer done immediately; the page adopts the file;
       2. a LIVE task for this key -> adopt it and push a sync so the page repaints its row;
       3. otherwise -> (re)start. The old meta-only guard silently no-oped on a STALE entry
          (meta written, task gone), which left the page's queue wedged on that row forever. */
    func start(key: String, url: URL, title: String, waitReady: Bool = false) {
        guard !key.isEmpty else { return }
        let dest = libURL(key)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let sz = attrs[.size] as? Int, sz > 0 {
            DispatchQueue.main.async { self.emit(key: key, type: "done", got: sz, total: sz, msg: "") }
            return
        }
        /* Ask for notification permission on the first real download: the tap that started it is the
           user gesture iOS wants, and without it the Lock Screen has nothing to show. */
        AxNotify.shared.requestOnce()
        /* RESUME, NEVER RESTART: a task that died mid-transfer left Apple's resume data behind. The
           next start continues from that byte offset instead of re-pulling the file from zero (the
           "92% -> back to 0%" report, where the file was already complete). */
        let rdKey = "ax.bg.resume." + key
        if let rd = UserDefaults.standard.data(forKey: rdKey), !rd.isEmpty {
            session.getAllTasks { [weak self] ts in
                guard let self = self else { return }
                if ts.contains(where: { $0.taskDescription == key }) { self.syncToPage(); return }
                DispatchQueue.main.async {
                    self.meta[key] = ["title": title, "url": url.absoluteString,
                                      "started": String(Date().timeIntervalSince1970)]
                    if waitReady { self.meta[key]?["wait"] = "1" }
                    self.saveMeta()
                    let t = self.session.downloadTask(withResumeData: rd)
                    t.taskDescription = key
                    t.resume()
                    AxNotify.shared.progressNow(key: key, title: title.isEmpty ? key : title, got: 0, total: 0)
                    self.emit(key: key, type: "start", got: 0, total: 0, msg: "resume")
                }
            }
            return
        }
        session.getAllTasks { [weak self] ts in
            guard let self = self else { return }
            let live = ts.contains { $0.taskDescription == key }
            DispatchQueue.main.async {
                self.meta[key] = ["title": title,
                                  "url": url.absoluteString,
                                  "started": String(Date().timeIntervalSince1970)]
                if waitReady { self.meta[key]?["wait"] = "1" }
                self.saveMeta()
                if live {
                    self.syncToPage()
                } else {
                    /* bytes=0- marks the serve as PARTIAL on the server: the job dir survives the
                       download, so a page retry or the windows fallback can resume the SAME job
                       instead of hitting "file not ready" (a full serve deletes the dir). */
                    var req = URLRequest(url: url)
                    req.setValue("bytes=0-", forHTTPHeaderField: "Range")
                    let t = self.session.downloadTask(with: req)
                    t.taskDescription = key
                    /* WAIT-READY: iOS re-runs this task natively at the earliest date WITHOUT
                       waking the app - exactly what a backgrounded rip phase needs. */
                    if waitReady { t.earliestBeginDate = Date(timeIntervalSinceNow: Self.retryDelay) }
                    t.resume()
                    self.emit(key: key, type: "start", got: 0, total: 0, msg: "")
                }
            }
        }
    }

    func register(key: String, url: URL, title: String, waitReady: Bool = false) {
        guard !key.isEmpty else { return }
        pending[key] = url.absoluteString
        if waitReady { meta[key] = (meta[key] ?? ["title": title]); meta[key]?["wait"] = "1"; saveMeta() }
    }

    /* Start every registered transfer. Cancel also drops a pending registration so a cancelled
       row never starts in the background. */
    private func startAllRegistered() {
        guard !pending.isEmpty else { return }
        let jobs = pending
        pending.removeAll()
        for (key, urlString) in jobs {
            guard let url = URL(string: urlString) else { continue }
            let waitReady = meta[key]?["wait"] == "1"
            start(key: key, url: url, title: meta[key]?["title"] ?? "", waitReady: waitReady)
        }
    }

    func cancel(key: String) {
        AxNotify.shared.clearProgress(key: key)   // a cancelled job's progress notification goes too
        AxActivity.shared.end(status: "Cancelled")
        // Clear the bookkeeping FIRST: an instant re-download of the same key must never be
        // swallowed while getAllTasks is still resolving (the old async clear raced it).
        meta.removeValue(forKey: key)
        pending.removeValue(forKey: key)
        saveMeta()
        UserDefaults.standard.removeObject(forKey: "ax.bg.resume." + key)
        session.getAllTasks { ts in
            for t in ts where t.taskDescription == key { t.cancel() }
        }
    }

    private func saveMeta() {
        UserDefaults.standard.set(meta, forKey: "ax.bg.meta")
    }

    private func clearMeta(_ key: String) {
        meta.removeValue(forKey: key)
        saveMeta()
        UserDefaults.standard.removeObject(forKey: "ax.bg.resume." + key)
    }

    /* Full task table -> the page. Runs on foreground and after the session's pending events
       are delivered. */
    func syncToPage() {
        session.getAllTasks { [weak self] ts in
            guard let self = self else { return }
            var rows: [[String: Any]] = []
            for t in ts {
                guard let k = t.taskDescription, !k.isEmpty else { continue }
                rows.append(["type": "progress",
                             "key": k,
                             "got": Int(t.countOfBytesReceived),
                             "total": max(0, Int(t.countOfBytesExpectedToReceive)),
                             "state": t.state.rawValue])
            }
            DispatchQueue.main.async { self.emitRows(rows) }
        }
    }

    /* An error body (JSON/HTML) is never media: MP3/MP4 never start with { or <. */
    static func looksLikeErrorBody(_ f: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: f) else { return true }
        defer { try? fh.close() }
        guard let d = try? fh.read(upToCount: 512), !d.isEmpty else { return true }
        var i = 0
        while i < d.count && (d[i] == 32 || d[i] == 9 || d[i] == 10 || d[i] == 13) { i += 1 }
        guard i < d.count else { return true }
        return d[i] == UInt8(ascii: "{") || d[i] == UInt8(ascii: "<")
    }

    /* Engine library location - MUST stay identical to NativePlayer.libURL(_:), which the
       player's libquery/libplay already read. Kept in sync by construction (same directory,
       same name shape). */
    /* The player owns the naming (key rule + media extension). Never fork it here. */
    private func libURL(_ k: String) -> URL {
        NativePlayer.shared.bgLibURL(k)
    }

    private func emit(key: String, type: String, got: Int, total: Int, msg: String) {
        let js = "window.dispatchEvent(new CustomEvent('axbg',{detail:{type:\(Self.json(type)),key:\(Self.json(key)),got:\(got),total:\(total),msg:\(Self.json(msg))}}))"
        web?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func emitRows(_ rows: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: []),
              let s = String(data: data, encoding: .utf8) else { return }
        // s is a JSON ARRAY of task rows; the page wraps it: detail {type:'sync', tasks:[...]}
        emitRaw("{type:'sync',tasks:" + s + "}")
    }

    /* The one page-event emitter. `json` is a complete JS object literal. */
    private func emitRaw(_ json: String) {
        web?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('axbg',{detail:\(json)}))",
                                completionHandler: nil)
    }

    static func json(_ s: String) -> String {
        let esc = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + esc + "\""
    }
}

extension AxDownloads: URLSessionDownloadDelegate, URLSessionDataDelegate {
    /* Whole file arrived on disk: move it into the engine library under the page's key. */
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let key = downloadTask.taskDescription ?? ""
        guard !key.isEmpty else { return }
        let fm = FileManager.default
        let dest = libURL(key)
        try? fm.removeItem(at: dest)
        var size = 0
        do { try fm.moveItem(at: location, to: dest) }
        catch {
            do { try fm.copyItem(at: location, to: dest); try? fm.removeItem(at: location) }
            catch { DispatchQueue.main.async { self.clearMeta(key) }; return }
        }
        /* CONTENT VALIDATION (same guard the web engine has had since the 404 era): the serve
           endpoint answers 404 JSON until the server-side rip is final. Never let an error body
           land in the media library as a "completed download". */
        if Self.looksLikeErrorBody(dest) {
            try? fm.removeItem(at: dest)
            let waited = meta[key]?["wait"] == "1"
            let n = (retries[key] ?? 0) + 1
            if waited && n <= Self.maxWaitRetries {
                retries[key] = n
                if let s = meta[key]?["url"], let u = URL(string: s) {
                    DispatchQueue.main.async {
                        var req = URLRequest(url: u)
                        req.setValue("bytes=0-", forHTTPHeaderField: "Range")
                        let t = self.session.downloadTask(with: req)
                        t.taskDescription = key
                        t.earliestBeginDate = Date(timeIntervalSinceNow: Self.retryDelay)
                        t.resume()
                        AxNotify.shared.progress(key: key, title: self.meta[key]?["title"] ?? key,
                                                 pct: 0, got: 0, total: 0, phase: "Preparing")
                        AxActivity.shared.update(title: self.meta[key]?["title"] ?? key, pct: 0, got: 0, total: 0, status: "Preparing")
                        self.emit(key: key, type: "progress", got: 0, total: 0, msg: "waiting for the server job")
                    }
                }
                return
            }
            retries[key] = nil
            DispatchQueue.main.async {
                let t = self.meta[key]?["title"] ?? key
                self.clearMeta(key)
                AxNotify.shared.failed(key: key, title: t, error: "the server job never became ready")
                self.emit(key: key, type: "error", got: 0, total: 0, msg: "server job never became ready")
                NotificationCenter.default.post(name: .axDlFailed, object: nil, userInfo: ["key": key])
            }
            return
        }
        retries[key] = nil
        resumeTries[key] = nil
        UserDefaults.standard.removeObject(forKey: "ax.bg.resume." + key)
        size = ((try? fm.attributesOfItem(atPath: dest.path))?[FileAttributeKey.size] as? Int) ?? 0
        DispatchQueue.main.async {
            let t = self.meta[key]?["title"] ?? ""
            self.clearMeta(key)
            AxNotify.shared.completed(key: key, title: t.isEmpty ? key : t)
            AxActivity.shared.end(status: "Complete")
            self.emit(key: key, type: "done", got: size, total: size, msg: "")
            NotificationCenter.default.post(name: .axDlFinished, object: nil,
                                            userInfo: ["key": key, "size": size])
            self.syncToPage()
        }
    }

    /* Byte progress: only worth pushing while the page can run JS. */
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let key = downloadTask.taskDescription ?? ""
        guard !key.isEmpty else { return }
        DispatchQueue.main.async {
            let t = self.meta[key]?["title"] ?? key
            let pct = totalBytesExpectedToWrite > 0 ? Double(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100) : 0
            AxActivity.shared.ensure(title: t)
            AxActivity.shared.update(title: t, pct: pct, got: Int(totalBytesWritten), total: Int(max(0, totalBytesExpectedToWrite)), status: "Downloading")
            AxNotify.shared.progress(key: key,
                                     title: t,
                                     pct: Int(pct),
                                     got: Int(totalBytesWritten),
                                     total: Int(max(0, totalBytesExpectedToWrite)),
                                     phase: "Downloading")
            if UIApplication.shared.applicationState == .active {
                self.emit(key: key, type: "progress",
                          got: Int(totalBytesWritten),
                          total: Int(max(0, totalBytesExpectedToWrite)), msg: "")
            }
        }
    }

    /* Error (nil error = success; the didFinish handler already stored the file). Keep Apple's
       resume data so the page can restart byte-wise instead of from zero. */
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let err = error else { return }
        let key = task.taskDescription ?? ""
        guard !key.isEmpty else { return }
        /* RECONNECT FROM THE BYTES WE ALREADY HAVE (2026-11-18). iOS hands back resume data for a
           transfer that died mid-flight; keeping it and re-arming the task means the next attempt
           continues at that offset. Clearing it (what this did before) is what made the retry start
           again from 0% while the file was already complete. */
        if let rd = (err as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !rd.isEmpty {
            UserDefaults.standard.set(rd, forKey: "ax.bg.resume." + key)
            let n = (resumeTries[key] ?? 0) + 1
            resumeTries[key] = n
            DispatchQueue.main.async {
                let t = self.meta[key]?["title"] ?? key
                let got = Int(task.countOfBytesReceived)
                let total = Int(max(0, task.countOfBytesExpectedToReceive))
                AxNotify.shared.progressNow(key: key, title: t, got: got, total: total)
                self.emit(key: key, type: "progress", got: got, total: total, msg: "reconnecting")
                if n <= 8, let urlS = self.meta[key]?["url"], let u = URL(string: urlS) {
                    let delay = min(30.0, Double(n) * 3.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self else { return }
                        self.start(key: key, url: u, title: t,
                                   waitReady: self.meta[key]?["wait"] == "1")
                    }
                } else {
                    self.resumeTries[key] = nil
                    self.clearMeta(key)
                    AxNotify.shared.failed(key: key, title: t.isEmpty ? key : t, error: err.localizedDescription)
                    self.emit(key: key, type: "error", got: 0, total: 0, msg: err.localizedDescription)
                }
            }
            return
        }
        DispatchQueue.main.async {
            let t = self.meta[key]?["title"] ?? ""
            AxActivity.shared.end(status: "Failed")
            /* Clear the meta so a page retry can hand the job again immediately. URLSession
               itself already retried transient failures (waitsForConnectivity), so what reaches
               here is a real error; the retry re-serves the SAME server job (the dir survives
               partial serves), so nothing is lost. */
            self.clearMeta(key)
            AxNotify.shared.failed(key: key, title: t.isEmpty ? key : t, error: err.localizedDescription)
            self.emit(key: key, type: "error", got: 0, total: 0,
                      msg: err.localizedDescription)
            NotificationCenter.default.post(name: .axDlFailed, object: nil, userInfo: ["key": key])
        }
    }

    /* All queued background events for this wake-up are delivered: tell iOS we are done. */
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.bgCompletion?()
            self?.bgCompletion = nil
        }
    }
}


/* ---------- NATIVE BATCH QUEUE (2026-11-18) ----------
 * THE REASON THIS EXISTS: the download queue used to live in JavaScript. Every item needed the page
 * to schedule it, so a slow render / a playlist read / a reloaded WebView could stall a batch, and a
 * row could sit at 99% while the file was already in the library. The page now hands the WHOLE list
 * over ONCE; iOS downloads them one after another inside the background session, keeps the queue in
 * its own persisted state (a relaunch continues it), and reports the whole queue on the 'axbg'
 * channel. Nothing in the UI sits between two files: the next task is created from the completion
 * callback, in the same run loop.
 */
extension Notification.Name {
    static let axDlFinished = Notification.Name("ax.dl.finished")
    static let axDlFailed   = Notification.Name("ax.dl.failed")
}

final class AxBatch {
    static let shared = AxBatch()

    private struct Item: Codable {
        var key: String
        var url: String
        var title: String
        var status: String          // queued | running | done | failed | cancelled
        var got: Int
        var total: Int
    }

    private var items: [Item] = []
    private var batchName = ""
    private var paused = false
    private var stopped = false
    private let storeKey = "ax.batch.state"

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .axDlFinished, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let k = n.userInfo?["key"] as? String else { return }
            self.markDone(key: k, size: (n.userInfo?["size"] as? Int) ?? 0)
        }
        nc.addObserver(forName: .axDlFailed, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let k = n.userInfo?["key"] as? String else { return }
            self.markFailed(key: k)
        }
        /* A batch outlives the page AND the process: on the next foreground, keep going. */
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.report()
            self.pump()
        }
        load()
    }

    // MARK: page-facing API

    func start(name: String, items list: [[String: String]]) {
        guard !list.isEmpty else { return }
        batchName = name.isEmpty ? "Downloads" : name
        items = list.map { d in
            Item(key: d["key"] ?? "", url: d["url"] ?? "", title: d["title"] ?? "",
                 status: "queued", got: 0, total: 0)
        }.filter { !$0.key.isEmpty && !$0.url.isEmpty }
        paused = false
        stopped = false
        save()
        emit()
        pump()                      // first file starts NOW - no page round trip
    }

    func pause() {
        paused = true
        emit()
    }

    func resume() {
        paused = false
        stopped = false
        emit()
        pump()
    }

    func cancelAll() {
        stopped = true
        for i in items.indices where items[i].status == "queued" || items[i].status == "running" {
            if items[i].status == "running" { AxDownloads.shared.cancel(key: items[i].key) }
            items[i].status = "cancelled"
        }
        save()
        emit()
    }

    func report() { emit() }

    // MARK: queue engine

    private func pump() {
        guard !paused, !stopped else { return }
        guard !items.contains(where: { $0.status == "running" }) else { return }
        guard let idx = items.firstIndex(where: { $0.status == "queued" }) else { return }
        items[idx].status = "running"
        save()
        emit()
        /* waitReady: the server may still be ripping; the background task retries ITSELF with
           earliestBeginDate until the file is real, with zero page involvement. */
        AxDownloads.shared.start(key: items[idx].key,
                                 url: URL(string: items[idx].url)!,
                                 title: items[idx].title,
                                 waitReady: true)
    }

    private func markDone(key: String, size: Int) {
        guard let idx = items.firstIndex(where: { $0.key == key }) else { return }
        if items[idx].status == "done" { return }          // idempotent: duplicate events are harmless
        items[idx].status = "done"
        items[idx].got = size
        items[idx].total = size
        save()
        emit()
        pump()                                             // next file, immediately
    }

    private func markFailed(key: String) {
        guard let idx = items.firstIndex(where: { $0.key == key }) else { return }
        if items[idx].status == "done" { return }
        items[idx].status = "failed"
        save()
        emit()
        pump()
    }

    // MARK: persistence + reporting

    private func save() {
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: storeKey)
            UserDefaults.standard.set(batchName, forKey: storeKey + ".name")
        }
    }

    private func load() {
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([Item].self, from: d) {
            items = list
        }
        batchName = UserDefaults.standard.string(forKey: storeKey + ".name") ?? ""
        /* Anything that was mid-flight died with the process: re-queue it. */
        for i in items.indices where items[i].status == "running" {
            items[i].status = "queued"
        }
    }

    private func emit() {
        let done = items.filter { $0.status == "done" }.count
        let parts: [String] = items.map { i in
            let pct = i.total > 0 ? Int(Double(i.got) / Double(i.total) * 100) : 0
            return "{\"key\":\"" + AxBatch.esc(i.key) + "\",\"status\":\"" + AxBatch.esc(i.status)
                 + "\",\"got\":" + String(i.got) + ",\"total\":" + String(i.total)
                 + ",\"pct\":" + String(pct) + ",\"title\":\"" + AxBatch.esc(i.title) + "\"}"
        }
        let json = "{type:'batch',name:'" + AxBatch.esc(batchName) + "',done:" + String(done)
                 + ",total:" + String(items.count) + ",paused:" + (paused ? "true" : "false")
                 + ",cancelled:" + (stopped ? "true" : "false") + ",items:[" + parts.joined(separator: ",") + "]}"
        AxDownloads.shared.emitBatch(json)
    }

    private static func esc(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
    }
}

/* ---------- LIVE ACTIVITY (2026-11-17) ----------
   ActivityKit Live Activity for the CURRENT download: Lock Screen + Dynamic Island.
   Updated ONLY from real native URLSession callbacks (didWriteData etc.) - every time iOS wakes
   the process it pushes the newest real byte counts; between wakeups the last accurate state
   stays visible (iOS coalesces background updates; nothing is estimated). One activity at a time
   (the download queue is serial). Ended on complete / fail / cancel with a final state. */
final class AxActivity {
    static let shared = AxActivity()
    #if canImport(ActivityKit)
    /* Boxed: the class is available from iOS 15, Activity<> is 16.1+ - cast inside guards. */
    private var activityBox: Any?
    private var lastPush: Date = .distantPast
    private var lastTitle = ""
    private var lastPct: Double = 0
    private var lastGot = 0
    private var lastTotal = 0
    private var brand = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? "imfan"
    #endif

    /* Start on the first REAL native progress callback. No-op when activities are disabled
       (iOS 16.0 devices, Low Power Mode restrictions, user setting). */
    func ensure(title: String) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard activityBox == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        lastTitle = title
        let attr = DownloadActivityAttributes(brand: brand)
        let st = DownloadActivityAttributes.ContentState(title: title, pct: 0, got: 0, total: 0, status: "Downloading")
        activityBox = try? Activity<DownloadActivityAttributes>.request(attributes: attr, contentState: st)
        #endif
    }

    func update(title: String, pct: Double, got: Int, total: Int, status: String) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        lastTitle = title; lastPct = pct; lastGot = got; lastTotal = total
        guard let a = activityBox as? Activity<DownloadActivityAttributes> else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPush) >= 1.0 else { return }   // ActivityKit update budget
        lastPush = now
        let st = DownloadActivityAttributes.ContentState(title: title, pct: pct, got: got, total: total, status: status)
        /* The combined end(content:dismissalPolicy:) overload is 16.2; the 16.1-safe form is
           update(Content) with a fully-populated Content init. */
        Task { await a.update(.init(state: st, staleDate: nil, relevanceScore: 0)) }
        #endif
    }

    func end(status: String) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard let a = activityBox as? Activity<DownloadActivityAttributes> else { return }
        activityBox = nil
        let pct = status == "Complete" ? 100.0 : lastPct
        let st = DownloadActivityAttributes.ContentState(title: lastTitle, pct: pct, got: lastGot, total: lastTotal, status: status)
        /* 16.1-safe ending: end(Content) followed by end(dismissalPolicy:) - the combined
           end(content:dismissalPolicy:) overload is 16.2+. */
        Task { await a.end(.init(state: st, staleDate: nil, relevanceScore: 0), dismissalPolicy: .immediate) }
        #endif
    }
}

/* ---------- Download notifications (2026-11-17) ----------
   UNUserNotificationCenter, no entitlements, iOS 15+. ONE notification per download (updated in
   place - a 50-file playlist NEVER posts 50 notifications), grouped playlist progress, and
   completion/failure notices. Progress updates post only while the app is BACKGROUNDED: in the
   foreground the in-app download panel is the surface, and Apple's HIG warns against foreground
   notification spam. Content carries title/percent/byte counts only - never URLs, tokens or keys.
   Permission is requested ONCE per install, from the page's first download (a user gesture), and
   a denial is never re-prompted. */
final class AxNotify: NSObject {
    static let shared = AxNotify()
    private var lastProgress: [String: Date] = [:]
    private var titles: [String: String] = [:]
    private let center = UNUserNotificationCenter.current()

    func message(_ d: [String: Any]) {
        let kind = d["kind"] as? String ?? "progress"
        if kind == "perm" { requestOnce(); return }
        let key = d["key"] as? String ?? ""
        guard !key.isEmpty else { return }
        let title = d["title"] as? String ?? ""
        if !title.isEmpty { titles[key] = title }
        let shownTitle = titles[key] ?? title
        switch kind {
        case "progress":
            progress(key: key, title: shownTitle,
                     pct: d["pct"] as? Int ?? Int((d["pct"] as? Double) ?? 0),
                     got: d["got"] as? Int ?? Int((d["got"] as? Double) ?? 0),
                     total: d["total"] as? Int ?? Int((d["total"] as? Double) ?? 0),
                     phase: d["phase"] as? String ?? "")
        case "done":
            completed(key: key, title: shownTitle)
        case "failed":
            failed(key: key, title: shownTitle, error: d["error"] as? String ?? "")
        case "cleared":
            clearProgress(key: key)
        case "playlist":
            let name = d["plName"] as? String ?? key
            let pkind = d["pkind"] as? String ?? "progress"
            let doneFiles = d["doneFiles"] as? Int ?? Int((d["doneFiles"] as? Double) ?? 0)
            let totalFiles = d["totalFiles"] as? Int ?? Int((d["totalFiles"] as? Double) ?? 0)
            let pct = d["pct"] as? Int ?? Int((d["pct"] as? Double) ?? 0)
            if pkind == "done" {
                playlistDone(name: name, done: doneFiles, total: totalFiles)
                AxActivity.shared.end(status: "Complete")
            } else {
                /* Playlist progress feeds the LIVE ACTIVITY (one surface, no notification spam). */
                AxActivity.shared.ensure(title: name)
                AxActivity.shared.update(title: name, pct: Double(pct), got: 0, total: 0,
                                         status: "\(doneFiles) of \(totalFiles) files")
            }
        default: break
        }
    }

    func requestOnce() {
        let ud = UserDefaults.standard
        if ud.bool(forKey: "ax.notify.asked") { return }
        ud.set(true, forKey: "ax.notify.asked")
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            UserDefaults.standard.set(granted, forKey: "ax.notify.granted")
        }
    }

    private var allowed: Bool {
        // .authorized or .provisional -> post; .notDetermined -> first download also asks.
        if !UserDefaults.standard.bool(forKey: "ax.notify.asked") { requestOnce(); return false }
        return UserDefaults.standard.object(forKey: "ax.notify.granted") as? Bool ?? false
    }

    private static func humanSize(_ b: Int) -> String {
        if b >= 1_073_741_824 { return String(format: "%.2f GB", Double(b) / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
        return "\(b) B"
    }

    private func content(title: String, body: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = nil   // progress stays silent; completion sets its own sound
        return c
    }

    /* One notification per download key, updated in place. Throttled to >= 1.2 s per key.
       Posted only while backgrounded - in the foreground the in-app panel is the surface. */
    func progress(key: String, title: String, pct: Int, got: Int, total: Int, phase: String) {
        guard allowed, !key.isEmpty, !title.isEmpty else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        let now = Date()
        if let last = lastProgress[key], now.timeIntervalSince(last) < 1.2 { return }
        lastProgress[key] = now
        var body = pct > 0 ? "\(pct)% · " : ""
        if total > 0 { body += "\(Self.humanSize(got)) / \(Self.humanSize(total))" }
        if !phase.isEmpty && phase != "Downloading" && phase != "Paused" { body = phase + (body.isEmpty ? "" : " · " + body) }
        let c = content(title: title, body: body.isEmpty ? "Downloading…" : body)
        let req = UNNotificationRequest(identifier: "ax.dl." + key, content: c, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }

    /* Un-throttled, state-independent snapshot: only called at background-time (and on a reconnect),
       where "the user just locked the screen" is exactly when the Lock Screen must show something. */
    func progressNow(key: String, title: String, got: Int, total: Int) {
        guard allowed, !key.isEmpty, !title.isEmpty else { return }
        lastProgress[key] = Date()
        var body = ""
        let pct = total > 0 ? Int(Double(got) / Double(total) * 100) : 0
        if pct > 0 { body = "\(pct)%" }
        if total > 0 { body += (body.isEmpty ? "" : " · ") + "\(Self.humanSize(got)) / \(Self.humanSize(total))" }
        let c = content(title: title, body: body.isEmpty ? "Downloading..." : body)
        center.add(UNNotificationRequest(identifier: "ax.dl." + key, content: c, trigger: nil), withCompletionHandler: nil)
    }

    func completed(key: String, title: String) {
        clearProgress(key: key)
        lastProgress.removeValue(forKey: key)
        guard allowed, !title.isEmpty else { return }
        let c = content(title: title, body: "Download complete")
        c.sound = .default
        let req = UNNotificationRequest(identifier: "ax.dlfinal." + key, content: c, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }

    func failed(key: String, title: String, error: String) {
        clearProgress(key: key)
        lastProgress.removeValue(forKey: key)
        guard allowed, !title.isEmpty else { return }
        let body = error.isEmpty ? "Download failed — reopen the app to retry." : "Download failed — reopen the app to retry. (\(error))"
        let c = content(title: title, body: body)
        c.sound = .default
        let req = UNNotificationRequest(identifier: "ax.dlfinal." + key, content: c, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }

    func clearProgress(key: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["ax.dl." + key])
        center.removePendingNotificationRequests(withIdentifiers: ["ax.dl." + key])
    }

    /* PLAYLIST: one aggregated notification, updated in place; one completion notice at the end. */
    func playlistProgress(name: String, done: Int, total: Int, pct: Int) {
        guard allowed, !name.isEmpty else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        let c = content(title: name, body: "\(done) of \(total) files · \(pct)%")
        center.add(UNNotificationRequest(identifier: "ax.pl." + name, content: c, trigger: nil), withCompletionHandler: nil)
    }

    func playlistDone(name: String, done: Int, total: Int) {
        guard allowed, !name.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ["ax.pl." + name])
        let c = content(title: name, body: "Playlist ready · \(done) of \(total) files downloaded")
        c.sound = .default
        center.add(UNNotificationRequest(identifier: "ax.plfinal." + name, content: c, trigger: nil), withCompletionHandler: nil)
    }
}


/* ===== A: on-device YouTube resolver (player-capture) =====
   Runs YouTube's OWN player in a hidden WKWebView (no cookies: nonPersistent store), injects the
   website-provided capture script, and collects the googlevideo media URLs the player fetches.
   Their code does the signature decipher, so a YouTube player rotation does not break us. Up to
   3 resolve in parallel; the rest queue. Each finishes on a 10s timeout with whatever was captured
   (JS picks the format; empty => server fallback). */
final class AxResolveCenter {
    static let shared = AxResolveCenter()
    private var active = 0
    private let maxActive = 3
    private var pending: [(String, String, ([String]) -> Void)] = []
    func resolve(id: String, script: String, completion: @escaping ([String]) -> Void) {
        guard !id.isEmpty else { completion([]); return }
        if active >= maxActive { pending.append((id, script, completion)); return }
        active += 1
        let r = AxResolver()
        r.start(id: id, script: script) { [weak self] urls in
            completion(urls)
            self?.active -= 1
            self?.drain()
        }
    }
    private func drain() {
        guard active < maxActive, !pending.isEmpty else { return }
        let (id, script, cb) = pending.removeFirst()
        resolve(id: id, script: script, completion: cb)
    }
}

final class AxResolver: NSObject, WKScriptMessageHandler {
    private var web: WKWebView?
    private var urls: [String] = []
    private var done: (([String]) -> Void)?
    private var timer: Timer?
    func start(id: String, script: String, completion: @escaping ([String]) -> Void) {
        done = completion
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.add(self, name: "axCap")
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: cfg)
        web = w
        if let u = URL(string: "https://www.youtube.com/watch?v=" + id) { w.load(URLRequest(url: u)) }
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in self?.finish() }
    }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "axCap", let s = m.body as? String, !urls.contains(s) { urls.append(s) }
    }
    private func finish() {
        timer?.invalidate(); timer = nil
        let result = urls
        let cb = done; done = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "axCap")
        web?.stopLoading(); web = nil
        cb?(result)
    }
}
