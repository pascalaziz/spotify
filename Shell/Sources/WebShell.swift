import SwiftUI
import WebKit
import AVFoundation
import MediaPlayer

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
            WKUserScript(source: "window.__AX_NATIVE=1;",
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
    private var remoteConfigured = false

    func attach(_ web: WKWebView) {
        self.web = web
        web.configuration.userContentController.add(self, name: "shellRetry")
        web.configuration.userContentController.add(self, name: "axPlay")
        NativePlayer.shared.attach(web)
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
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refresh?.endRefreshing()
        showOffline()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refresh?.endRefreshing()
        showOffline()
    }

    private func showOffline() {
        guard let web = web, SHELL.url != nil, !offlineShown else { return }
        offlineShown = true
        web.loadHTMLString(Self.offlineHTML, baseURL: nil)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "shellRetry" {
            offlineShown = false
            if let url = SHELL.url { web?.load(URLRequest(url: url)) }
        }
        if message.name == "axPlay", let d = message.body as? [String: Any] {
            NativePlayer.shared.message(d)
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
            // the page moved to a web-path track (video/embed/link): stand down fully
            av?.pause()
            engaged = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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

    /* Per-item cached file (from a handoff finish or a preload stream). */
    private func trackURL(_ k: String) -> URL {
        let safe = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
        return FileManager.default.temporaryDirectory.appendingPathComponent("ax-t-" + safe)
    }

    /* NATIVE LIBRARY (2026-11-05, his order: "exact as Spotify, unlimited"): downloaded
       files mirrored into the app's OWN storage (Application Support), so widget next/prev
       reads native disk for ANY item - 3 or 100 - with zero page JS and zero dependence on
       the frozen webview. Filled by the page's trickle while the app is open; persistent;
       garbage-collected on libsync when items leave the queue. The 6-file rolling cache
       (ax-t-*, temp dir) never touches these files. */
    private func libName(_ k: String) -> String {
        "ax-l-" + (k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k)
    }
    private func libURL(_ k: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ax-library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(libName(k))
    }
    private func libGC() {
        let fm = FileManager.default
        let dir = libURL("").deletingLastPathComponent()
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("ax-l-") {
            let name = String(f.lastPathComponent.dropFirst(5))
            let raw = name.removingPercentEncoding ?? name
            if !libKeys.contains(raw) && !libKeys.contains(name) { try? fm.removeItem(at: f) }
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
        emit("{type:'jump',i:\(idx),q:\(it["q"] as? Int ?? -1)}")
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
        maybeFetchArt()
    }

    // Artwork: the track's thumbnail (page-sent URL, cached) with the bundled brand
    // art as the standing fallback. Fetch is async; the card is restated on arrival.
    private lazy var defaultArt: UIImage? = UIImage(named: "nowplaying")

    private func currentArt() -> UIImage? {
        if !artURL.isEmpty, let img = artCache.object(forKey: artURL as NSString) { return img }
        return defaultArt
    }

    private func maybeFetchArt() {
        let u = artURL
        guard !u.isEmpty, !artFailed.contains(u),
              artCache.object(forKey: u as NSString) == nil, artFetchURL != u,
              let url = URL(string: u) else { return }
        artFetchURL = u
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let img = UIImage(data: data) else {
                // ONE attempt per URL: offline/dead thumbnails must not re-fetch on
                // every card() tick (0.5s while playing). The bundled art stands in.
                DispatchQueue.main.async { self?.artFailed.insert(u); self?.artFetchURL = "" }
                return
            }
            self?.artCache.setObject(img, forKey: u as NSString)
            DispatchQueue.main.async { self?.artFetchURL = ""; self?.card() }
        }.resume()
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
