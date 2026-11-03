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
        // Media bridge: the page's player state (window.axPlayer) is posted here every second
        // while anything changes; the app OWNS the Now Playing card (Spotify-style) so it
        // survives pause + backgrounding even when the web process is suspended.
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

    // Runs in the page from document-start. Reads the site's own player (window.axPlayer:
    // play/pause/next/prev/seekTo/playing/queue/_currentTime/_duration) and posts CHANGES
    // only — track change, play/pause, and ~5 s of position drift while playing. Paused =
    // no posts = the native card freezes on the last state (exactly right).
    static let mediaBridgeJS = """
    (function () {
      if (!window.__AX_NATIVE) return;
      var last = '';
      function post(o) { try { window.webkit.messageHandlers.axMedia.postMessage(o); } catch (e) {} }
      setInterval(function () {
        try {
          var p = window.axPlayer; if (!p || !p.queue || p.index == null) return;
          var it = p.queue[p.index]; if (!it) return;
          var playing = !!p.playing;
          var title = it.title || 'Untitled';
          var artist = (typeof p.axArtist === 'function' && p.axArtist(it)) || '';
          var pos = Number((typeof p._currentTime === 'function' ? p._currentTime() : 0) || 0);
          var dur = Number((typeof p._duration === 'function' ? p._duration() : 0) || 0);
          var key = title + '|' + artist + '|' + playing + '|' + (dur ? Math.round(pos / 5) : 0);
          if (key !== last) { last = key; post({ title: title, artist: artist, playing: playing, pos: pos, dur: dur }); }
        } catch (e) {}
      }, 1000);
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
    private var card: [String: Any] = [:]

    func attach(_ web: WKWebView) {
        self.web = web
        web.configuration.userContentController.add(self, name: "shellRetry")
        web.configuration.userContentController.add(self, name: "axMedia")
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
        if message.name == "axMedia", let d = message.body as? [String: Any] {
            card["title"] = d["title"]
            card["artist"] = d["artist"]
            card["dur"] = d["dur"]
            card["pos"] = d["pos"]
            card["playing"] = d["playing"]
            updateNowPlayingCard()
            configureRemoteCommandsIfNeeded()
        }
    }

    // MARK: - Native Now Playing (the app owns the card, Spotify-style)

    private func updateNowPlayingCard() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = (card["title"] as? String) ?? ""
        info[MPMediaItemPropertyArtist] = (card["artist"] as? String) ?? ""
        if let dur = card["dur"] as? Double, dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur }
        if let pos = card["pos"] as? Double { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos }
        info[MPNowPlayingInfoPropertyPlaybackRate] = ((card["playing"] as? Bool) ?? false) ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

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
