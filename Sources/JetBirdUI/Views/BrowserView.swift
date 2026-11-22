//
//  BrowserView.swift
//  JetBirdUI
//
//  In-app browser with ad-blocking
//

import SwiftUI
import WebKit
import JetBirdCore

struct BrowserView: View {
    @EnvironmentObject var settings: AppSettingsStore
    @StateObject private var browserModel = BrowserViewModel()
    @State private var showTabBar = true
    @State private var showSearch = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            if showTabBar {
                TabBarView(tabs: $browserModel.tabs, selectedTab: $browserModel.selectedTabIndex)
                    .background(.regularMaterial)
            }

            // Address bar
            AddressBarView(
                url: browserModel.currentTab?.url ?? URL(string: "about:blank")!,
                isLoading: browserModel.currentTab?.isLoading ?? false,
                canGoBack: browserModel.currentTab?.canGoBack ?? false,
                canGoForward: browserModel.currentTab?.canGoForward ?? false,
                onGoBack: { browserModel.goBack() },
                onGoForward: { browserModel.goForward() },
                onReload: { browserModel.reload() },
                onSubmit: { url in browserModel.navigate(to: url) },
                onSearch: { showSearch = true }
            )
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.regularMaterial)

            // Web view
            if let tab = browserModel.currentTab {
                WebViewContainer(
                    url: tab.url,
                    isLoading: Binding(
                        get: { tab.isLoading },
                        set: { browserModel.updateLoading($0) }
                    ),
                    title: Binding(
                        get: { tab.title },
                        set: { browserModel.updateTitle($0) }
                    ),
                    canGoBack: Binding(
                        get: { tab.canGoBack },
                        set: { browserModel.updateCanGoBack($0) }
                    ),
                    canGoForward: Binding(
                        get: { tab.canGoForward },
                        set: { browserModel.updateCanGoForward($0) }
                    ),
                    onDownloadDetected: { url, filename, headers in
                        browserModel.handleDownload(url: url, filename: filename, headers: headers)
                    }
                )
            } else {
                ContentUnavailableView(
                    "No Tab",
                    systemImage: "safari",
                    description: Text("Tap + to open a new tab")
                )
            }

            // Bottom toolbar
            BottomToolbarView(
                onNewTab: { browserModel.newTab() },
                onCloseTab: { browserModel.closeCurrentTab() },
                onTabs: { },
                onBookmarks: { },
                onMenu: { }
            )
            .background(.regularMaterial)
        }
        .sheet(isPresented: $showSearch) {
            SearchView(searchEngine: settings.searchEngine) { query in
                browserModel.search(query: query, engine: settings.searchEngine)
                showSearch = false
            }
        }
        .onAppear {
            if browserModel.tabs.isEmpty {
                browserModel.newTab()
            }
        }
    }
}

// MARK: - Tab Bar

struct TabBarView: View {
    @Binding var tabs: [BrowserTab]
    @Binding var selectedTab: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs.indices, id: \.self) { index in
                    TabButton(
                        tab: tabs[index],
                        isSelected: index == selectedTab,
                        onTap: { selectedTab = index },
                        onClose: { tabs.remove(at: index) }
                    )
                }

                Button(action: { tabs.append(BrowserTab(url: URL(string: "about:blank")!)) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 36)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
    }
}

struct TabButton: View {
    let tab: BrowserTab
    let isSelected: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let favicon = tab.favicon, let image = UIImage(data: favicon) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if isSelected {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Address Bar

struct AddressBarView: View {
    let url: URL
    let isLoading: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onReload: () -> Void
    let onSubmit: (URL) -> Void
    let onSearch: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onGoBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)

            Button(action: onGoForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)

            Button(action: onReload) {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
            }

            TextField("Search or enter address", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    if let url = URL(string: text.hasPrefix("http") ? text : "https://\(text)") {
                        onSubmit(url)
                    } else {
                        onSearch()
                    }
                }
                .onAppear {
                    text = url.absoluteString
                }

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
            }
        }
    }
}

// MARK: - Web View Container

struct WebViewContainer: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var title: String
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    let onDownloadDetected: (URL, String, [String: String]) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Apply ad-block rules
        if let ruleList = ContentFilterEngine.shared.contentRuleList {
            config.userContentController.add(ruleList)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Load initial URL
        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Update URL if changed externally
        if webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isLoading: $isLoading,
            title: $title,
            canGoBack: $canGoBack,
            canGoForward: $canGoForward,
            onDownloadDetected: onDownloadDetected
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var isLoading: Bool
        @Binding var title: String
        @Binding var canGoBack: Bool
        @Binding var canGoForward: Bool
        let onDownloadDetected: (URL, String, [String: String]) -> Void

        init(
            isLoading: Binding<Bool>,
            title: Binding<String>,
            canGoBack: Binding<Bool>,
            canGoForward: Binding<Bool>,
            onDownloadDetected: @escaping (URL, String, [String: String]) -> Void
        ) {
            self._isLoading = isLoading
            self._title = title
            self._canGoBack = canGoBack
            self._canGoForward = canGoForward
            self.onDownloadDetected = onDownloadDetected
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            title = webView.title ?? ""
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        // Handle downloads
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Check if this is a download
            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                // Could check MIME type via HEAD request
                // For now, allow navigation
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // Check for Content-Disposition attachment
            if let response = navigationResponse.response as? HTTPURLResponse,
               let disposition = response.allHeaderFields["Content-Disposition"] as? String,
               disposition.contains("attachment") {

                let filename = extractFilename(from: disposition) ?? response.suggestedFilename ?? "download"
                var headers: [String: String] = [:]
                for (key, value) in response.allHeaderFields {
                    if let k = key as? String, let v = value as? String {
                        headers[k] = v
                    }
                }

                if let url = navigationResponse.response.url {
                    onDownloadDetected(url, filename, headers)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        private func extractFilename(from disposition: String) -> String? {
            let pattern = "filename\\*?=([^;]+)"
            let regex = try? NSRegularExpression(pattern: pattern)
            let range = NSRange(location: 0, length: disposition.utf16.count)
            if let match = regex?.firstMatch(in: disposition, range: range),
               let range = Range(match.range(at: 1), in: disposition) {
                var filename = String(disposition[range])
                filename = filename.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return filename
            }
            return nil
        }
    }
}

// MARK: - Bottom Toolbar

struct BottomToolbarView: View {
    let onNewTab: () -> Void
    let onCloseTab: () -> Void
    let onTabs: () -> Void
    let onBookmarks: () -> Void
    let onMenu: () -> Void

    var body: some View {
        HStack {
            Button(action: onNewTab) {
                Image(systemName: "plus")
            }
            .frame(maxWidth: .infinity)

            Button(action: onCloseTab) {
                Image(systemName: "xmark")
            }
            .frame(maxWidth: .infinity)

            Button(action: onTabs) {
                Image(systemName: "square.on.square")
            }
            .frame(maxWidth: .infinity)

            Button(action: onBookmarks) {
                Image(systemName: "bookmark")
            }
            .frame(maxWidth: .infinity)

            Button(action: onMenu) {
                Image(systemName: "ellipsis")
            }
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 20))
        .foregroundStyle(.primary)
        .padding(.vertical, 8)
    }
}

// MARK: - Search View

struct SearchView: View {
    let searchEngine: AppSettings.SearchEngine
    let onSearch: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("Search with \(searchEngine.displayName)")
                    .font(.title2)
                    .fontWeight(.medium)

                TextField("Search query", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
                    .focused($isFocused)
                    .onSubmit {
                        onSearch(query)
                    }

                Button("Search") {
                    onSearch(query)
                }
                .buttonStyle(.borderedProminent)
                .disabled(query.isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }
}

// MARK: - Browser View Model

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabIndex: Int = 0
    @Published var showDownloadSheet = false
    @Published var pendingDownload: (URL, String, [String: String])?

    var currentTab: BrowserTab? {
        guard selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    func newTab(url: URL = URL(string: "about:blank")!) {
        let tab = BrowserTab(url: url)
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
    }

    func closeCurrentTab() {
        guard !tabs.isEmpty else { return }
        tabs.remove(at: selectedTabIndex)
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = max(0, tabs.count - 1)
        }
        if tabs.isEmpty {
            newTab()
        }
    }

    func navigate(to url: URL) {
        guard selectedTabIndex < tabs.count else { return }
        tabs[selectedTabIndex].url = url
        tabs[selectedTabIndex].lastVisited = Date()
    }

    func goBack() {
        // WebView handles this
    }

    func goForward() {
        // WebView handles this
    }

    func reload() {
        // WebView handles this
    }

    func updateLoading(_ loading: Bool) {
        guard selectedTabIndex < tabs.count else { return }
        tabs[selectedTabIndex].isLoading = loading
    }

    func updateTitle(_ title: String) {
        guard selectedTabIndex < tabs.count else { return }
        tabs[selectedTabIndex].title = title
    }

    func updateCanGoBack(_ canGoBack: Bool) {
        guard selectedTabIndex < tabs.count else { return }
        tabs[selectedTabIndex].canGoBack = canGoBack
    }

    func updateCanGoForward(_ canGoForward: Bool) {
        guard selectedTabIndex < tabs.count else { return }
        tabs[selectedTabIndex].canGoForward = canGoForward
    }

    func handleDownload(url: URL, filename: String, headers: [String: String]) {
        pendingDownload = (url, filename, headers)
        showDownloadSheet = true
    }

    func search(query: String, engine: AppSettings.SearchEngine) {
        let url = engine.searchURL(query: query)
        navigate(to: url)
    }
}