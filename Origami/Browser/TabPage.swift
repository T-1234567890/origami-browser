import AppKit
import WebKit
import Observation

@MainActor @Observable
final class TabPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    @ObservationIgnored let linkPeekObserver = LinkPeekObserver()
    let webView: WKWebView
    var destinationHistory = TabDestinationHistory()
    var nativeRevision = 0
    var aiTitle: String?
    var answerFromHistory = false
    var isAsking = Personalization.shared.defaultAsk
    var newTabDraft = ""
    var askModelSelections: [AIProviderID: String] = [:]
    var article: ReaderArticle?
    var isPassivePreview = false
    var previewUnavailable: (() -> Void)?
    var readerVisible = false
    var readerWhenReady = false
    var jsonText: String?
    var showsJSON = true
    var discoveredFeeds: [URL] = []
    var responseDetails: ResponseDetails?
    var documentGeneration = UUID()
    var navigationStarted: Date?
    @ObservationIgnored var documentTask: Task<Void, Never>?

    var nativePage: InternalPage? { destinationHistory.current.flatMap { InternalRoute.page(for: $0.url) } }
    @ObservationIgnored private var webHistoryItems: [UUID: WKBackForwardListItem] = [:]
    @ObservationIgnored private var pendingEntry: UUID?
    let profileID: UUID
    let tabID: UUID
    @ObservationIgnored private let services: BrowserServices?
    @ObservationIgnored var onServiceError: ((String) -> Void)?
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private let mediaObserver = MediaFrameObserver()
    var mediaState = TabMediaState()
    private(set) var mediaPlaybackSuspended = false
    var activity = TabActivity()
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var errorMessage: String?
    var favicon: NSImage?
    @ObservationIgnored private var requestedURL: URL?
    var currentURL: URL? { nativePage?.url ?? requestedURL ?? webView.url }
    var pageTitle: String? {
        if nativePage == .newtab, let aiTitle { return aiTitle }
        if let nativePage { return nativePage.title }
        if requestedURL != nil { return currentURL?.host }
        return webView.title.flatMap { $0.isEmpty ? nil : $0 }
    }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var openPeek: ((URL) -> Void)?
    @ObservationIgnored var openTab: ((URLRequest) -> Void)?
    @ObservationIgnored var createPopup: ((WKWebViewConfiguration) -> WKWebView)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let pageDialog = PageDialog()
    @ObservationIgnored private var faviconTask: Task<Void, Never>?

    init(configuration suppliedConfiguration: WKWebViewConfiguration? = nil, services: BrowserServices? = nil,
         profileID: UUID = BrowserProfile.defaultID, tabID: UUID = UUID()) {
        self.services = services; self.profileID = profileID; self.tabID = tabID
        let configuration = suppliedConfiguration ?? WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = Self.browserIdentity
        configuration.websiteDataStore = (try? services?.websiteStore(profileID: profileID)) ?? .nonPersistent()
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.addUserScript(WKUserScript(source: ActivityScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: MediaSessionScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ScriptRuntime.install((try? services?.power.scripts(profileID)) ?? [], controller: configuration.userContentController)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(linkPeekObserver, contentWorld: LinkPeekObserver.world, name: "origamiLinkHover")
        configuration.userContentController.addUserScript(WKUserScript(source: LinkPeekObserver.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: LinkPeekObserver.world))
        mediaObserver.webView = webView
        mediaObserver.changed = { [weak self] in self?.refreshMediaState() }
        configuration.userContentController.add(mediaObserver, name: "origamiMedia")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Public WebKit inspection is enabled in release builds too, including popup tabs.
        webView.isInspectable = true
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() }
        ]
        mediaTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                mediaObserver.expire()
                refreshMediaState()
                activity.hasDownload = services?.downloads.hasActiveDownload(tabID: tabID) ?? false
            }
        }
    }
    // WKWebView omits Safari compatibility tokens on macOS. Keep WebKit's own
    // platform/engine identity and append the installed Safari version when available.
    private static let browserIdentity: String = {
        let safariVersion = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = safariVersion ?? "18.4" // Compatibility baseline for macOS 15.4.
        return "Version/\(version) Safari/605.1.15"
    }()

    func confirmAction(_ message: String) async -> Bool {
        await withCheckedContinuation { continuation in
            pageDialog.show(relativeTo: webView, title: "Confirm", message: message, accept: "Confirm") { continuation.resume(returning: $0 != nil) }
        }
    }
    func setMuted(_ muted: Bool) async {
        _ = try? await webView.callAsyncJavaScript("window.__origamiActivity?.setMuted(muted)", arguments: ["muted": muted], in: nil, contentWorld: .page)
        mediaState.isMuted = (try? await webView.evaluateJavaScript("window.__origamiActivity?.muted")) as? Bool
    }
    private func refreshMediaState() {
        var next = nativePage == nil ? mediaObserver.current : TabMediaState()
        next.hasCapture = webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
        if next != mediaState { mediaState = next }
        if activity.isPlayingMedia != next.isPlayingMedia { activity.isPlayingMedia = next.isPlayingMedia }
        if activity.hasCapture != next.hasCapture { activity.hasCapture = next.hasCapture }
    }
    func controlMedia(_ action: String, time: Double? = nil, sessionID: String? = nil) async -> Bool {
        guard ["play", "pause", "previoustrack", "nexttrack", "seekto"].contains(action),
              let id = mediaState.id, sessionID == nil || sessionID == id, let frame = mediaObserver.frame(for: id) else { return false }
        do {
            let result = try await webView.callAsyncJavaScript("return await Promise.race([window.__origamiMedia?.perform(action, id, time), new Promise(resolve => setTimeout(() => resolve(false), 3000))])",
                arguments: ["action": action, "id": id, "time": time as Any? ?? NSNull()], in: frame, contentWorld: .page)
            return result as? Bool == true
        } catch { return false }
    }
    func dismissDialog() { pageDialog.cancel() }

    nonisolated private func scheduleUpdate() {
        Task { @MainActor [weak self] in self?.update() }
    }
    private func update() {
        let suspend = nativePage != nil
        webView.isInspectable = !suspend
        if mediaPlaybackSuspended != suspend {
            mediaPlaybackSuspended = suspend
            webView.setAllMediaPlaybackSuspended(suspend, completionHandler: nil)
            refreshMediaState()
        }
        if nativePage == nil && !webView.isLoading && (requestedURL == nil || requestedURL == webView.url) {
            recordWebNavigation()
            if requestedURL == webView.url { requestedURL = nil }
        }
        isLoading = nativePage == nil && webView.isLoading
        progress = nativePage == nil ? webView.estimatedProgress : 0
        canGoBack = destinationHistory.canGoBack
        canGoForward = destinationHistory.canGoForward
        onChange?()
    }
    private func recordWebNavigation() {
        guard let item = webView.backForwardList.currentItem, let url = webView.url, item.url == url else { return }
        if let pendingEntry {
            destinationHistory.select(pendingEntry, url: url)
            webHistoryItems[pendingEntry] = item
            self.pendingEntry = nil
        } else if let existing = webHistoryItems.first(where: { $0.value === item }), destinationHistory.entries.contains(where: { $0.id == existing.key }) {
            destinationHistory.select(existing.key, url: url)
        } else {
            resetDocuments()
        let entry = destinationHistory.visit(url)
            webHistoryItems[entry.id] = item
        }
        let ids = Set(destinationHistory.entries.map(\.id))
        webHistoryItems = webHistoryItems.filter { ids.contains($0.key) }
    }
    func load(_ url: URL) {
        errorMessage = nil; dismissDialog()
        let entry = destinationHistory.visit(url)
        requestedURL = url
        if InternalRoute.page(for: url) != nil {
            pendingEntry = nil; faviconTask?.cancel(); webView.stopLoading(); favicon = nil; update()
        } else {
            pendingEntry = entry.id; webView.load(URLRequest(url: url)); update()
        }
    }
    func goBack() { traverse(-1) }
    func goForward() { traverse(1) }
    private func traverse(_ direction: Int) {
        guard let entry = destinationHistory.move(direction) else { return }
        resetDocuments()
        errorMessage = nil; dismissDialog(); requestedURL = entry.url
        if InternalRoute.page(for: entry.url) != nil {
            pendingEntry = nil; webView.stopLoading(); update(); return
        }
        pendingEntry = entry.id
        if let item = webHistoryItems[entry.id] {
            if webView.backForwardList.currentItem === item {
                pendingEntry = nil; requestedURL = nil; update(); return
            }
            let items = webView.backForwardList.backList + webView.backForwardList.forwardList
            if items.contains(where: { $0 === item }) { webView.go(to: item); update(); return }
        }
        webView.load(URLRequest(url: entry.url)); update()
    }
    func reload(withoutCache: Bool = false) {
        errorMessage = nil
        if nativePage != nil { nativeRevision += 1; return }
        pendingEntry = destinationHistory.current?.id
        if let requestedURL { webView.load(URLRequest(url: requestedURL, cachePolicy: withoutCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)) }
        else { Self.reloadWebView(webView, withoutCache: withoutCache) }
    }
    static func reloadWebView(_ view: WKWebView, withoutCache: Bool) {
        if withoutCache { view.reloadFromOrigin() } else { view.reload() }
    }
    func resetDocuments() {
        documentTask?.cancel(); documentGeneration = UUID(); article = nil; readerVisible = false; jsonText = nil; discoveredFeeds = []; responseDetails = nil; navigationStarted = Date()
    }
    func dispose() {
        documentTask?.cancel()
        dismissDialog()
        mediaTask?.cancel()
        faviconTask?.cancel()
        observations.removeAll()
        mediaObserver.changed = nil
        mediaObserver.reset()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "origamiLinkHover", contentWorld: LinkPeekObserver.world)
        linkPeekObserver.changed = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "origamiMedia")
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onChange = nil; openTab = nil; createPopup = nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        resetDocuments()
        errorMessage = nil; favicon = nil; faviconTask?.cancel(); update()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        documentGeneration = UUID(); documentTask?.cancel()
        article = nil; readerVisible = false; jsonText = nil; discoveredFeeds = []
        guard nativePage == nil else { return }
        recordWebNavigation()
        mediaObserver.reset()
        errorMessage = nil
        requestedURL = nil
        if let url = webView.url, let origin = PermissionService.origin(url), let services {
            let muted = (try? services.permissions.siteRule("muted", origin: origin, profileID: profileID)) ?? false
            Task { @MainActor [weak self] in await self?.setMuted(muted) }
            let autoplay = (try? services.permissions.decision(.autoplay, origin: origin, profileID: profileID)) ?? .ask
            Task { @MainActor [weak self] in
                _ = try? await self?.webView.callAsyncJavaScript("window.__origamiActivity?.setAutoplayPolicy(block)", arguments: ["block": autoplay == .block], in: nil, contentWorld: .page)
            }
        }
        update()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard nativePage == nil else { return }
        errorMessage = nil
        update()
        loadFavicon()
        if let navigationStarted { responseDetails?.seconds = Date().timeIntervalSince(navigationStarted) }
        scheduleDocumentDiscovery()

        if let url = webView.url {
            do { if services?.isPrivate != true { try services?.history.record(url, title: webView.title ?? url.host ?? "", profileID: profileID) } }
            catch { onServiceError?("History could not be saved: \(error.localizedDescription)") }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    private func report(_ error: Error) {
        guard nativePage == nil else { return }
        let error = error as NSError
        let cancelled = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        // WKWebView still emits this legacy WebKit policy-interruption error (102).
        // A cancelled policy decision is not a failed network request.
        let policyInterrupted = error.domain == "WebKitErrorDomain" && error.code == 102
        if !cancelled && !policyInterrupted { errorMessage = error.localizedDescription }
        update()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard nativePage == nil else { return }
        errorMessage = "This page stopped responding. Reload to continue."
        update()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        // Native destinations are entered through browser actions, never remote JavaScript.
        if scheme == "origami" || nativePage != nil { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload || (navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.option)) {
            guard ["http", "https", "blob", "data"].contains(scheme) else { decisionHandler(.cancel); return }
            decisionHandler(downloadAllowed(source: navigationAction.sourceFrame.request.url) ? .download : .cancel); return
        }
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            if navigationAction.modifierFlags.contains(.command), navigationAction.navigationType == .linkActivated {
                openTab?(navigationAction.request)
                decisionHandler(.cancel)
            } else {
                if navigationAction.targetFrame?.isMainFrame == true {
                    resetDocuments()
                    requestedURL = url
                    update()
                }
                decisionHandler(.allow)
            }
        } else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false,
               webView.window != nil {
                let decision = (try? services?.externalProtocols.decision(for: url, source: navigationAction.sourceFrame.request.url, profileID: profileID)) ?? .ask
                if decision == .block { return }
                if decision == .allow { services?.externalProtocols.openOnce(url); return }
                let source = navigationAction.sourceFrame.request.url
                pageDialog.choices(relativeTo: webView, title: "Open an external application?",
                                   message: "\(source?.host ?? "This page") wants to open a \(scheme): link.") { [weak self] response in
                    guard let self else { return }
                    if let source, let origin = PermissionService.origin(source), response == "Always Open" || response == "Block" {
                        do { try self.services?.externalProtocols.set(response == "Always Open" ? .allow : .block, origin: origin, scheme: scheme, profileID: self.profileID) }
                        catch { self.onServiceError?(error.localizedDescription); return }
                    }
                    if response == "Open Once" || response == "Always Open" { self.services?.externalProtocols.openOnce(url) }
                }
            }
        }
    }
    private func downloadAllowed(source: URL?) -> Bool {
        guard !isPassivePreview else { previewUnavailable?(); return false }
        guard let services else { return false }
        guard let source, let origin = PermissionService.origin(source) else { return true }
        return (try? services.permissions.decision(.downloads, origin: origin, profileID: profileID)) != .block
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            responseDetails = ResponseDetails(status: response.statusCode, headers: response.allHeaderFields.reduce(into: [:]) { result, pair in result[String(describing: pair.key)] = String(describing: pair.value) }, mime: response.mimeType ?? "")
        }
        if isPassivePreview && !["text/html", "application/xhtml+xml"].contains(navigationResponse.response.mimeType?.lowercased() ?? "") {
            decisionHandler(.cancel); previewUnavailable?(); return
        }
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        if attachment || !navigationResponse.canShowMIMEType {
            decisionHandler(downloadAllowed(source: webView.url) ? .download : .cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        services?.downloads.accept(download, profileID: profileID, tabID: tabID)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        services?.downloads.accept(download, profileID: profileID, tabID: tabID)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let url = frame.request.url, let site = PermissionService.origin(url), let services else { decisionHandler(.deny); return }
        let categories: [SitePermission] = type == .camera ? [.camera] : type == .microphone ? [.microphone] : [.camera, .microphone]
        let choices = categories.map { (try? services.permissions.decision($0, origin: site, profileID: profileID)) ?? .block }
        if choices.contains(.block) { decisionHandler(.deny) }
        else if choices.allSatisfy({ $0 == .allow }) { decisionHandler(.grant) }
        else { decisionHandler(.prompt) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if let source = navigationAction.sourceFrame.request.url, let origin = PermissionService.origin(source),
           (try? services?.permissions.decision(.popups, origin: origin, profileID: profileID)) == .block { return nil }
        return createPopup?(configuration)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        dialog(message, allowsCancel: false) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        dialog(message) { completionHandler($0 != nil) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        dialog(prompt, input: defaultText ?? "", completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = webView.window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    private func dialog(_ message: String, allowsCancel: Bool = true, input: String? = nil,
                        completion: @escaping (String?) -> Void) {
        pageDialog.show(relativeTo: webView, title: webView.url?.host ?? "Website", message: message,
                        allowsCancel: allowsCancel, input: input, completion: completion)
    }
    private func loadFavicon() {
        guard let pageURL = webView.url, ["https", "http"].contains(pageURL.scheme) else { return }
        faviconTask = Task { [weak self] in
            guard let self else { return }
            let declared = try? await webView.evaluateJavaScript("document.querySelector('link[rel~=icon]')?.href") as? String
            let url = declared.flatMap(URL.init(string:)) ?? URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
            guard let url, ["https", "http"].contains(url.scheme) else { return }
            guard let image = await FaviconService.fetch(url), !Task.isCancelled, webView.url == pageURL else { return }
            favicon = image
            services?.favicons.remember(image, for: pageURL, profile: profileID)
        }
    }
}
