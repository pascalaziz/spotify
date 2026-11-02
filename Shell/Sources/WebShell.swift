import SwiftUI
import WebKit

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
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true               // video stays inline, never forced fullscreen
        config.mediaTypesRequiringUserActionForPlayback = []  // playback follows the site's own tap-to-play
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

    func attach(_ web: WKWebView) {
        self.web = web
        web.configuration.userContentController.add(self, name: "shellRetry")
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
