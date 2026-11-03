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
        // Interruptions (calls, other apps' audio) must not permanently kill the session:
        // reactivate it when they end. The player itself stays where the system left it.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { _ in
            try? AVAudioSession.sharedInstance().setActive(true)
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
        cc.playCommand.addTarget { [weak self] _ in self?.js("window.axPlayer&&window.axPlayer.play()"); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.js("window.axPlayer&&window.axPlayer.pause()"); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.js("window.axPlayer&&window.axPlayer.next()"); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.js("window.axPlayer&&window.axPlayer.prev()"); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
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
    private var title = ""
    private var artist = ""
    private var dur = 0.0
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
            if let s = d["data"] as? String, let dd = Data(base64Encoded: s) { buf.append(dd) }
        case "chunk":
            if let s = d["data"] as? String, let dd = Data(base64Encoded: s) { buf.append(dd) }
        case "finish":
            load()
        case "resume":
            av?.play()
        case "pause":
            av?.pause()
        case "seek":
            if let t = d["t"] as? Double {
                av?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            }
        default:
            break
        }
    }

    private func load() {
        guard !buf.isEmpty else { emit("{type:'error'}"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ax-track.mp3")
        do { try buf.write(to: url, options: .atomic) } catch { emit("{type:'error'}"); return }
        if let o = timeObs, let p = av { p.removeTimeObserver(o) }
        rateObs?.invalidate()
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        av = player
        rateObs = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            self?.state(playing: p.rate > 0)
        }
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                 queue: .main) { [weak self] t in
            self?.tick(t.seconds)
        }
        if autoPlay { player.play() }
        card()
    }

    private func tick(_ t: Double) {
        let d = av?.currentItem?.duration.seconds ?? 0
        let dur2 = (d.isFinite && d > 0) ? d : dur
        emit("{type:'time',t:\(t),dur:\(dur2)}")
        card()
    }

    private func state(playing: Bool) {
        emit("{type:'state',playing:\(playing)}")
    }

    private func ended() {
        state(playing: false)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
