import SwiftUI
import WebKit

// ── The only two lines you ever change ────────────────────────────────
// Site address (PC host today, VPS tomorrow — the app never needs an update,
// DNS moves the domain, the app keeps pointing here).
let APP_URL = URL(string: "https://imfan.org")!
// Main-frame navigations on this host (and subdomains) stay in the app;
// everything else the user taps opens in Safari.
let APP_HOST = "imfan.org"

let AX_BG = UIColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1)   // #0b0d12
let AX_ACCENT = UIColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1)  // cyan

struct WebShell: View {
    var body: some View {
        WebView()
    }
}

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true              // video stays in its card, never forced fullscreen
        config.mediaTypesRequiringUserActionForPlayback = [] // playback follows the site's own tap-to-play
        // default (persistent) data store: cookies + IndexedDB + OPFS survive relaunches,
        // Service Workers run in-app on iOS 16.4+ → Aurorix offline mode keeps working.
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = true
        web.underPageBackgroundColor = AX_BG
        web.scrollView.backgroundColor = AX_BG
        web.scrollView.alwaysBounceVertical = true
        context.coordinator.attach(web)

        let refresh = UIRefreshControl()
        refresh.tintColor = AX_ACCENT
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pullReload), for: .valueChanged)
        web.scrollView.addSubview(refresh)
        context.coordinator.refresh = refresh

        web.load(URLRequest(url: APP_URL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var web: WKWebView?
    var refresh: UIRefreshControl?
    private var offlineShown = false

    func attach(_ web: WKWebView) {
        self.web = web
        web.configuration.userContentController.add(self, name: "axRetry")
    }

    @objc func pullReload() { web?.reload() }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.url else { decisionHandler(.cancel); return }

        // iframes (YouTube embeds, players) always load — never navigate away
        if navigationAction.targetFrame?.isMainFrame != true {
            decisionHandler(.allow)
            return
        }
        let host = (url.host ?? "").lowercased()
        if host == APP_HOST || host.hasSuffix("." + APP_HOST) {
            decisionHandler(.allow)
            return
        }
        // anything else on the main frame (Watch on YouTube, external links) → Safari
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    // target="_blank" / window.open → Safari instead of a dead tap
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.url { UIApplication.shared.open(url) }
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
        guard let web = web, !offlineShown else { return }
        offlineShown = true
        web.loadHTMLString(Self.offlineHTML, baseURL: nil)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "axRetry" {
            offlineShown = false
            web?.load(URLRequest(url: APP_URL))
        }
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
        border:0;border-radius:12px;padding:14px 40px;min-width:44px;min-height:44px}
      button:active{opacity:.8}
    </style></head><body>
    <div class="c">
      <h1>You&rsquo;re offline</h1>
      <p>The app needs a connection the first time it opens. Saved downloads and offline playlists keep working once they&rsquo;re cached.</p>
      <button onclick="window.webkit.messageHandlers.axRetry.postMessage(0)">Retry</button>
    </div>
    </body></html>
    """
}
