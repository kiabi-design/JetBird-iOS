//
//  BrowserView.swift
//  JetBird
//

import SwiftUI
import WebKit
import Combine

struct PendingDownload: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    @Published var addressText = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var pendingDownload: PendingDownload?

    private var cancellables = Set<AnyCancellable>()
    private var activeRuleList: WKContentRuleList?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        webView.publisher(for: \.canGoBack)
            .sink { [weak self] value in self?.canGoBack = value }
            .store(in: &cancellables)
        webView.publisher(for: \.canGoForward)
            .sink { [weak self] value in self?.canGoForward = value }
            .store(in: &cancellables)
        webView.publisher(for: \.isLoading)
            .sink { [weak self] value in self?.isLoading = value }
            .store(in: &cancellables)
        webView.publisher(for: \.estimatedProgress)
            .sink { [weak self] value in self?.progress = value }
            .store(in: &cancellables)
        webView.publisher(for: \.url)
            .sink { [weak self] url in
                if let url = url { self?.addressText = url.absoluteString }
            }
            .store(in: &cancellables)
    }

    // MARK: Navigation

    func load(_ text: String, engine: AppSettings.SearchEngine) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil {
            webView.load(URLRequest(url: url))
        } else if !trimmed.contains(" "), trimmed.contains("."),
                  let url = URL(string: "https://" + trimmed) {
            webView.load(URLRequest(url: url))
        } else {
            webView.load(URLRequest(url: engine.searchURL(query: trimmed)))
        }
    }

    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Applies ad-block and desktop-site settings.
    func apply(settings: AppSettings, ruleList: WKContentRuleList?) {
        let controller = webView.configuration.userContentController
        if let old = activeRuleList {
            controller.remove(old)
            activeRuleList = nil
        }
        if settings.enableAdBlock, let list = ruleList {
            controller.add(list)
            activeRuleList = list
        }
        webView.configuration.defaultWebpagePreferences.preferredContentMode =
            settings.showDesktopSite ? .desktop : .mobile
    }

    // MARK: Downloads

    /// Cookies and referer so that downloads from logged-in pages keep working.
    func requestHeaders(for url: URL) async -> [String: String] {
        var result: [String: String] = [:]

        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let host = url.host ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        if !matching.isEmpty, let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] {
            result["Cookie"] = header
        }
        if let referer = webView.url?.absoluteString {
            result["Referer"] = referer
        }
        return result
    }

    private func isDownloadLink(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let extra: Set<String> = ["iso", "bin", "dmg", "apk", "ipa", "exe", "msi"]
        if extra.contains(ext) { return true }
        switch FileCategory.from(mimeType: nil, filename: url.lastPathComponent) {
        case .compressed, .packages, .videos, .audio: return true
        default: return false
        }
    }

    private func offerDownload(url: URL, suggestedName: String?) {
        var name = suggestedName ?? url.lastPathComponent
        if name.isEmpty { name = "download" }
        pendingDownload = PendingDownload(url: url, filename: name)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           isDownloadLink(url) {
            offerDownload(url: url, suggestedName: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        var isAttachment = false
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.contains("attachment") {
            isAttachment = true
        }
        if navigationResponse.isForMainFrame, isAttachment || !navigationResponse.canShowMIMEType,
           let url = navigationResponse.response.url {
            offerDownload(url: url, suggestedName: navigationResponse.response.suggestedFilename)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures,
                 completionHandler: @escaping (WKWebView?) -> Void) {
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false {
            webView.load(navigationAction.request)
        }
        completionHandler(nil)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    var onDownloadQueued: () -> Void = {}

    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var filters: ContentFilterEngine
    @StateObject private var model = BrowserModel()
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search or enter address", text: $model.addressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        model.load(model.addressText, engine: settings.settings.searchEngine)
                        addressFocused = false
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button { model.reloadOrStop() } label: {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
            }

            WebViewContainer(webView: model.webView)

            Divider()
            HStack {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                Spacer()
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                Spacer()
                Button {
                    model.load("https://duckduckgo.com", engine: settings.settings.searchEngine)
                } label: { Image(systemName: "house") }
            }
            .font(.title3)
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
        }
        .onAppear {
            model.apply(settings: settings.settings, ruleList: filters.ruleList)
            if model.webView.url == nil {
                model.load("https://duckduckgo.com", engine: settings.settings.searchEngine)
            }
        }
        .onReceive(settings.$settings) { newValue in
            model.apply(settings: newValue, ruleList: filters.ruleList)
        }
        .onReceive(filters.$ruleList) { list in
            model.apply(settings: settings.settings, ruleList: list)
        }
        .alert(
            "Download this file?",
            isPresented: Binding(
                get: { model.pendingDownload != nil },
                set: { if !$0 { model.pendingDownload = nil } }
            ),
            presenting: model.pendingDownload
        ) { item in
            Button("Download") { Task { await startDownload(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.filename)
        }
    }

    private func startDownload(_ item: PendingDownload) async {
        let headers = await model.requestHeaders(for: item.url)
        manager.addDownload(
            url: item.url,
            filename: item.filename,
            headers: headers,
            parts: settings.settings.downloadParts
        )
        onDownloadQueued()
    }
}
