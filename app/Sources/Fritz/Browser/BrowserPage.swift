import AppKit
import Observation

#if !FRITZ_CHROMIUM
import WebKit
#endif

struct BrowserPageState: Equatable {
    var url: URL?
    var title = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var error: String?
}

@MainActor @Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let page: BrowserPage
    var address = ""

    init() {
        page = BrowserPage()
    }

    func openAddress() -> Bool {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return false }
        let candidate = input.contains("://") ? input : "https://" + input
        guard let url = URL(string: candidate), isBrowserURL(url),
              url.user == nil, url.password == nil else {
            page.showError("Enter a valid HTTP or HTTPS address.")
            return false
        }
        page.load(url)
        return true
    }
}

func isBrowserURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
    return url.host?.isEmpty == false
}

#if FRITZ_CHROMIUM
@MainActor @Observable
final class BrowserPage {
    private let browser: FritzChromiumPage
    private(set) var state = BrowserPageState()
    var view: NSView { browser.view }

    init() {
        browser = FritzChromiumPage()
        browser.onChange = { [weak self] url, title, loading, back, forward, error in
            self?.state = BrowserPageState(url: url, title: title, isLoading: loading,
                                           canGoBack: back, canGoForward: forward, error: error)
        }
    }

    func load(_ url: URL) { browser.load(url) }
    func goBack() { browser.goBack() }
    func goForward() { browser.goForward() }
    func reload() {
        if let url = state.url, state.error != nil { load(url) }
        else { browser.reload() }
    }
    func stop() { browser.stop() }
    func close() { browser.close() }
    func showError(_ message: String) { state.error = message }
}
#else
@MainActor @Observable
final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let webView = WKWebView()
    var view: NSView { webView }
    private(set) var state = BrowserPageState()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var currentNavigation: WKNavigation?

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            observe(\.url), observe(\.title), observe(\.isLoading),
            observe(\.canGoBack), observe(\.canGoForward),
        ]
    }

    private func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
        webView.observe(keyPath) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        if let url = webView.url, isBrowserURL(url) { state.url = url }
        state.title = webView.title ?? ""
        state.isLoading = webView.isLoading
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
    }

    func load(_ url: URL) {
        state.url = url
        begin(webView.load(URLRequest(url: url)))
    }

    private func begin(_ navigation: WKNavigation?) {
        currentNavigation = navigation
        state.error = nil
    }

    func goBack() { begin(webView.goBack()) }
    func goForward() { begin(webView.goForward()) }
    func reload() {
        if let url = state.url, state.error != nil || webView.url == nil { load(url) }
        else { begin(webView.reload()) }
    }
    func stop() { webView.stopLoading() }
    func close() {
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        stop()
    }

    func showError(_ message: String) { state.error = message }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        begin(navigation)
        refresh()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        webViewNavigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        webViewNavigationFailed(navigation, error: error)
    }

    private func webViewNavigationFailed(_ navigation: WKNavigation?, error: any Error) {
        guard navigation === currentNavigation else { return }
        let failure = error as NSError
        guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
        showError(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showError("The page process closed. Reload to try again.")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !action.shouldPerformDownload else { return .cancel }
        guard action.targetFrame?.isMainFrame != false else { return .allow }
        guard let url = action.request.url, isBrowserURL(url) else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, action.navigationType == .linkActivated,
           let url = action.request.url, isBrowserURL(url) {
            begin(webView.load(action.request))
        }
        return nil
    }
}
#endif
