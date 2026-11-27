//
//  BrowserView.swift
//  JetBird
//
//  Tabbed browser. Pop-ups (window.open / target=_blank to other sites) open in a new tab
//  like in a desktop browser: the page that opened them stays alive, so sites that count clicks
//  before letting the real link through behave normally.
//

import SwiftUI
import WebKit
import Combine

struct PendingDownload: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    let tab: BrowserTab?
}

enum BrowserPresenter {
    /// Shows an alert above whatever is currently on screen. Returns false if nothing could present it.
    @MainActor
    static func present(_ alert: UIAlertController) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
        guard var top = window?.rootViewController else { return false }
        while let presented = top.presentedViewController { top = presented }
        top.present(alert, animated: true)
        return true
    }
}

// MARK: - Tab

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    /// Set for tabs opened by a site's script (pop-ups)
    let openerID: UUID?
    weak var store: BrowserStore?

    @Published var addressText = ""
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0

    private var pendingURL: URL?
    private var cancellables = Set<AnyCancellable>()
    private var activeRuleList: WKContentRuleList?

    init(store: BrowserStore,
         configuration: WKWebViewConfiguration? = nil,
         openerID: UUID? = nil,
         pendingURL: URL? = nil) {
        let config = configuration ?? WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        self.openerID = openerID
        self.pendingURL = pendingURL
        self.store = store
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if let pendingURL = pendingURL { addressText = pendingURL.absoluteString }

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
        webView.publisher(for: \.title)
            .sink { [weak self] value in self?.title = value ?? "" }
            .store(in: &cancellables)
        webView.publisher(for: \.url)
            .sink { [weak self] url in
                if let url = url { self?.addressText = url.absoluteString }
            }
            .store(in: &cancellables)
    }

    /// Current address, also for tabs that were restored but not loaded yet.
    var currentURL: URL? { webView.url ?? pendingURL }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = currentURL?.host { return host }
        return L("New tab")
    }

    func loadPendingIfNeeded() {
        guard webView.url == nil, let url = pendingURL else { return }
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    // MARK: Navigation

    func load(_ text: String, engine: AppSettings.SearchEngine) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingURL = nil

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

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reloadOrStop() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

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

    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        cancellables.removeAll()
    }

    // MARK: Downloads

    /// Cookies, referer and user agent so that downloads from logged-in pages keep working.
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
        let agent = try? await webView.evaluateJavaScript("navigator.userAgent")
        if let userAgent = agent as? String, !userAgent.isEmpty {
            result["User-Agent"] = userAgent
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
        store?.offerDownload(url: url, filename: name, from: self)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            // tel:, mailto:, app links ... are handed to the system
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store?.pageFinished(self)
    }

    // MARK: WKUIDelegate

    /// Registrable-domain approximation ("www.superpsx.com" -> "superpsx.com").
    private static func siteKey(_ host: String?) -> String? {
        guard var value = host?.lowercased(), !value.isEmpty else { return nil }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        let parts = value.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return value }
        if parts.count >= 3, parts[parts.count - 1].count == 2, parts[parts.count - 2].count <= 3 {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    /// target="_blank" and window.open():
    ///  * a link you tapped that stays on the same site opens in this tab;
    ///  * everything else opens in a new tab and the page that opened it stays alive,
    ///    exactly like in a desktop browser.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let store = store, let url = navigationAction.request.url else { return nil }

        let current = Self.siteKey(webView.url?.host)
        let sameSite = current != nil && current == Self.siteKey(url.host)
        if navigationAction.navigationType == .linkActivated && sameSite {
            webView.load(navigationAction.request)
            return nil
        }
        return store.openPopupTab(configuration: configuration, opener: self).webView
    }

    /// window.close()
    func webViewDidClose(_ webView: WKWebView) {
        store?.close(self)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("OK"), style: .default) { _ in completionHandler() })
        if !BrowserPresenter.present(alert) { completionHandler() }
    }

    /// Without this every confirm() returns false and some buttons never work.
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("OK"), style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in completionHandler(false) })
        if !BrowserPresenter.present(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: L("OK"), style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in completionHandler(nil) })
        if !BrowserPresenter.present(alert) { completionHandler(nil) }
    }
}

// MARK: - Store (all tabs)

@MainActor
final class BrowserStore: ObservableObject {
    static let homeURL = URL(string: "https://www.google.com")!

    private struct Session: Codable {
        var urls: [String]
        var selected: Int
    }

    private static let sessionKey = "jetbird.browser.session.v1"

    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published var pendingDownload: PendingDownload?

    let history = BrowserHistoryStore.shared

    private var settings = AppSettings()
    private var ruleList: WKContentRuleList?

    init() {
        restoreSession()
    }

    var selected: BrowserTab? {
        tabs.first { $0.id == selectedID }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL? = BrowserStore.homeURL, select shouldSelect: Bool = true) -> BrowserTab {
        let tab = BrowserTab(store: self, pendingURL: url)
        tab.apply(settings: settings, ruleList: ruleList)
        tabs.append(tab)
        if shouldSelect { select(tab) } else { saveSession() }
        return tab
    }

    func openPopupTab(configuration: WKWebViewConfiguration, opener: BrowserTab) -> BrowserTab {
        let tab = BrowserTab(store: self, configuration: configuration, openerID: opener.id)
        tab.apply(settings: settings, ruleList: ruleList)
        tabs.append(tab)
        if !(settings.popupsInBackground ?? false) {
            selectedID = tab.id
        }
        return tab
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
        tab.loadPendingIfNeeded()
        saveSession()
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasSelected = tab.id == selectedID
        let openerID = tab.openerID
        tab.tearDown()
        tabs.remove(at: index)

        if tabs.isEmpty {
            newTab()
            return
        }
        if wasSelected {
            let next = tabs.first { $0.id == openerID } ?? tabs[min(index, tabs.count - 1)]
            select(next)
        } else {
            saveSession()
        }
    }

    func closeAll() {
        for tab in tabs { tab.tearDown() }
        tabs = []
        selectedID = nil
        newTab()
    }

    func apply(settings newSettings: AppSettings, ruleList list: WKContentRuleList?) {
        settings = newSettings
        ruleList = list
        for tab in tabs { tab.apply(settings: newSettings, ruleList: list) }
    }

    // MARK: Events from tabs

    func pageFinished(_ tab: BrowserTab) {
        if tab.openerID == nil, let url = tab.webView.url {
            history.record(url: url, title: tab.webView.title)
        }
        saveSession()
    }

    func offerDownload(url: URL, filename: String, from tab: BrowserTab) {
        pendingDownload = PendingDownload(url: url, filename: filename, tab: tab)
    }

    // MARK: Session (remember the last visited sites)

    func saveSession() {
        // Pop-up tabs (usually ads) are not restored
        let persistent = tabs.filter { $0.openerID == nil && $0.currentURL != nil }
        let urls = persistent.compactMap { $0.currentURL?.absoluteString }
        guard !urls.isEmpty else { return }
        let selectedIndex = persistent.firstIndex { $0.id == selectedID } ?? 0
        if let data = try? JSONEncoder().encode(Session(urls: urls, selected: selectedIndex)) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    private func restoreSession() {
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            for address in session.urls {
                if let url = URL(string: address) {
                    tabs.append(BrowserTab(store: self, pendingURL: url))
                }
            }
            if !tabs.isEmpty {
                let index = min(max(session.selected, 0), tabs.count - 1)
                select(tabs[index])
                return
            }
        }
        newTab()
    }
}

// MARK: - Views

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
    @EnvironmentObject private var link: PS4LinkModel
    @StateObject private var store = BrowserStore()
    @State private var showTabs = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            if let tab = store.selected {
                BrowserPage(tab: tab, store: store, showTabs: $showTabs, showHistory: $showHistory)
                    .id(tab.id)
            } else {
                Spacer()
            }
        }
        .onAppear {
            store.apply(settings: settings.settings, ruleList: filters.ruleList)
        }
        .onReceive(settings.$settings) { newValue in
            store.apply(settings: newValue, ruleList: filters.ruleList)
        }
        .onReceive(filters.$ruleList) { list in
            store.apply(settings: settings.settings, ruleList: list)
        }
        .sheet(isPresented: $showTabs) { TabsView(store: store) }
        .sheet(isPresented: $showHistory) { HistoryView(store: store) }
        .confirmationDialog(
            "Download this file?",
            isPresented: Binding(
                get: { store.pendingDownload != nil },
                set: { if !$0 { store.pendingDownload = nil } }
            ),
            titleVisibility: .visible,
            presenting: store.pendingDownload
        ) { item in
            Button("Save to phone") {
                Task { await startDownload(item, destination: .phone) }
            }
            if link.isPaired && item.url.scheme?.lowercased() == "https" {
                Button("Send to PS4") {
                    Task { await startDownload(item, destination: .ps4) }
                }
                Button("Send to PS4 and install (PKG)") {
                    Task { await startDownload(item, destination: .ps4, install: true) }
                }
                Button("Phone + PS4") {
                    Task { await startDownload(item, destination: .both) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.filename)
        }
    }

    private func startDownload(_ item: PendingDownload, destination: TransferDestination, install: Bool = false) async {
        let headers = await item.tab?.requestHeaders(for: item.url) ?? [:]
        manager.addDownload(
            url: item.url,
            filename: item.filename,
            headers: headers,
            parts: settings.settings.downloadParts,
            destination: destination,
            isParallelInstall: install
        )
        onDownloadQueued()
    }
}

/// Address bar, page and toolbar of one tab.
struct BrowserPage: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    @Binding var showTabs: Bool
    @Binding var showHistory: Bool

    @EnvironmentObject private var settings: AppSettingsStore
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar

            if tab.openerID != nil {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Opened by a site")
                    Spacer(minLength: 0)
                    Button("Close tab") { store.close(tab) }
                        .font(.footnote.bold())
                }
                .font(.footnote)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.18))
            }

            if tab.isLoading {
                ProgressView(value: tab.progress)
                    .progressViewStyle(.linear)
            }

            WebViewContainer(webView: tab.webView)

            Divider()
            toolbar
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
            if let field = notification.object as? UITextField {
                DispatchQueue.main.async { field.selectAll(nil) }
            }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search or enter address", text: $tab.addressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        tab.load(tab.addressText, engine: settings.settings.searchEngine)
                        addressFocused = false
                    }

                if !tab.addressText.isEmpty {
                    Button {
                        tab.addressText = ""
                        addressFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button { tab.reloadOrStop() } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var toolbar: some View {
        HStack {
            Button { tab.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
            Spacer()
            Button { tab.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
            Spacer()
            Button { store.newTab() } label: { Image(systemName: "plus") }
            Spacer()
            Button { showTabs = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    Text("\(store.tabs.count)")
                        .font(.caption2.bold())
                }
            }
            Spacer()
            Button { showHistory = true } label: { Image(systemName: "clock") }
        }
        .font(.title3)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }
}

// MARK: - Tabs

struct TabsView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            tabList
                .navigationTitle("Tabs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
    }

    private var tabList: some View {
        List {
            ForEach(store.tabs) { tab in
                row(for: tab)
            }
        }
        .listStyle(.plain)
    }

    private func row(for tab: BrowserTab) -> some View {
        TabRow(
            tab: tab,
            isSelected: tab.id == store.selectedID,
            onSelect: { select(tab) },
            onClose: { store.close(tab) }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Close all", role: .destructive, action: closeAll)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Done", action: { dismiss() })
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: addTab) {
                Image(systemName: "plus")
            }
        }
    }

    private func select(_ tab: BrowserTab) {
        store.select(tab)
        dismiss()
    }

    private func closeAll() {
        store.closeAll()
        dismiss()
    }

    private func addTab() {
        store.newTab()
        dismiss()
    }
}

struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            selectButton
            closeButton
        }
    }

    private var selectButton: some View {
        Button(action: onSelect) {
            rowLabel
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "globe")
                .foregroundColor(isSelected ? Color.accentColor : Color.secondary)
            titles
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tab.displayTitle)
                .font(.body)
                .lineLimit(1)
            Text(tab.currentURL?.host ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - History

struct HistoryRow: View {
    let entry: HistoryEntry
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)
                Text(entry.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct HistoryView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var history = BrowserHistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmClear = false

    private struct DaySection: Identifiable {
        let day: Date
        let items: [HistoryEntry]
        var id: Date { day }
    }

    private var filteredEntries: [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return history.entries }
        return history.entries.filter { entry in
            entry.title.lowercased().contains(needle) || entry.url.lowercased().contains(needle)
        }
    }

    private var sections: [DaySection] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: filteredEntries) { entry in
            calendar.startOfDay(for: entry.date)
        }
        let days = byDay.keys.sorted(by: >)
        return days.map { day in
            DaySection(day: day, items: byDay[day] ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            historyList
                .searchable(text: $query, prompt: "Search history")
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .confirmationDialog("Clear history", isPresented: $confirmClear, titleVisibility: .visible) {
                    clearActions
                }
        }
    }

    private var historyList: some View {
        List {
            if filteredEntries.isEmpty {
                Text("No history yet")
                    .foregroundColor(.secondary)
            }
            ForEach(sections) { section in
                historySection(section)
            }
        }
    }

    private func historySection(_ section: DaySection) -> some View {
        Section {
            ForEach(section.items) { entry in
                HistoryRow(entry: entry, onOpen: { open(entry) })
            }
            .onDelete { offsets in
                delete(offsets, in: section)
            }
        } header: {
            Text(section.day, style: .date)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Clear history", role: .destructive, action: { confirmClear = true })
                .disabled(history.entries.isEmpty)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Done", action: { dismiss() })
        }
    }

    @ViewBuilder
    private var clearActions: some View {
        Button("Clear history", role: .destructive, action: { history.clear() })
        Button("Cancel", role: .cancel, action: {})
    }

    private func delete(_ offsets: IndexSet, in section: DaySection) {
        for index in offsets {
            history.remove(section.items[index].id)
        }
    }

    private func open(_ entry: HistoryEntry) {
        guard let url = URL(string: entry.url) else { return }
        if let tab = store.selected {
            tab.webView.load(URLRequest(url: url))
        } else {
            store.newTab(url: url)
        }
        dismiss()
    }
}
