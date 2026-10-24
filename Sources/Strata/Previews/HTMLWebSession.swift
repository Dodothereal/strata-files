import AppKit
import WebKit
import StrataModel

/// One WebKit lifetime. Both resource delivery and navigation are refused after closure.
@MainActor package final class HTMLWebSession: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate {
    package enum Navigation: Equatable { case document, anchor, external, refuse }
    package typealias Reader = @Sendable (URL) async throws -> HTMLPreviewResource
    private let documentURL: URL
    private let read: Reader
    private let openLink: (URL) -> Void
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    package var pendingTasks: [Task<Void, Never>] { Array(requests.values) }
    private var remainingRequests = HTMLPreviewDocument.requestLimit
    private var remainingBytes = 3 * TextFile.limit + HTMLPreviewDocument.assetLimit
    private var initial = true
    private var closed = false
    package var onFinish: (() -> Void)?
    package var onFailure: (() -> Void)?
    private static var rules: Task<WKContentRuleList, Error>?

    package init(url: URL, read: @escaping Reader, openLink: @escaping (URL) -> Void) {
        documentURL = url; self.read = read; self.openLink = openLink
    }

    isolated deinit { close() }

    package static func contentRules() async throws -> WKContentRuleList {
        if let rules { return try await rules.value }
        let task = Task { @MainActor in
            guard let store = WKContentRuleListStore(url: SecureStorage.caches) else { throw PreviewError.unsupported }
            // Start with a closed network boundary, then permit only the private scheme handled below.
            let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^strata-html://"},"action":{"type":"ignore-previous-rules"}}]"#
            guard let list = try await store.compileContentRuleList(forIdentifier: "StrataOfflineHTML.v1", encodedContentRuleList: json) else {
                throw PreviewError.unsupported
            }
            return list
        }
        rules = task
        do { return try await task.value }
        catch { rules = nil; throw error }
    }

    package func configuration(rules: WKContentRuleList) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(rules)
        configuration.setURLSchemeHandler(self, forURLScheme: HTMLPreviewDocument.scheme)
        return configuration
    }

    package func close() {
        guard !closed else { return }
        closed = true
        let pending = requests.values
        requests = [:]
        pending.forEach { $0.cancel() }
        onFinish = nil; onFailure = nil
    }

    package func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard !closed, let url = urlSchemeTask.request.url, urlSchemeTask.request.httpMethod == "GET" else {
            urlSchemeTask.didFailWithError(URLError(.cancelled)); return
        }
        guard remainingRequests > 0 else { urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return }
        remainingRequests -= 1
        let reader = read
        requests[key] = Task { [weak self] in
            let result: Result<HTMLPreviewResource, Error>
            do { try Task.checkCancellation(); result = .success(try await reader(url)) }
            catch { result = .failure(error) }
            guard let self, !closed, !Task.isCancelled, requests[key] != nil else { return }
            switch result {
            case .success(let resource):
                guard resource.data.count <= remainingBytes else {
                    requests.removeValue(forKey: key)
                    urlSchemeTask.didFailWithError(URLError(.dataLengthExceedsMaximum)); return
                }
                remainingBytes -= resource.data.count
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": resource.mime, "Content-Security-Policy": HTMLPreviewDocument.policy,
                    "X-DNS-Prefetch-Control": "off", "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
                ]) else { requests.removeValue(forKey: key); urlSchemeTask.didFailWithError(URLError(.badServerResponse)); return }
                urlSchemeTask.didReceive(response)
                guard !closed, requests[key] != nil else { return }
                urlSchemeTask.didReceive(resource.data)
                guard !closed, requests.removeValue(forKey: key) != nil else { return }
                urlSchemeTask.didFinish()
            case .failure(let error):
                requests.removeValue(forKey: key)
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    package func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    /// Only the first document load and clicked same-document anchors navigate inside this preview.
    package static func navigation(_ url: URL?, document: URL, method: String?, mainFrame: Bool, link: Bool, initial: Bool) -> Navigation {
        guard let url, method == "GET" else { return .refuse }
        if link, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
           url.user == nil, url.password == nil { return .external }
        guard mainFrame, var target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var source = URLComponents(url: document, resolvingAgainstBaseURL: false) else { return .refuse }
        let fragment = target.fragment
        target.fragment = nil; source.fragment = nil
        guard target == source else { return .refuse }
        if link, fragment != nil { return .anchor }
        return initial && !link && fragment == nil ? .document : .refuse
    }

    package func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                         decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !closed, !navigationAction.shouldPerformDownload else { decisionHandler(.cancel); return }
        let decision = Self.navigation(navigationAction.request.url, document: documentURL, method: navigationAction.request.httpMethod,
                                       mainFrame: navigationAction.targetFrame?.isMainFrame == true,
                                       link: navigationAction.navigationType == .linkActivated, initial: initial)
        switch decision {
        case .document: initial = false; decisionHandler(.allow)
        case .anchor: decisionHandler(.allow)
        case .external:
            decisionHandler(.cancel)
            if let url = navigationAction.request.url { openLink(url) }
        case .refuse: decisionHandler(.cancel)
        }
    }

    package func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                         decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(!closed && navigationResponse.isForMainFrame && navigationResponse.canShowMIMEType
                        && navigationResponse.response.url == documentURL ? .allow : .cancel)
    }

    package func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if !closed { onFinish?() } }
    package func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if !closed { onFailure?() } }
    package func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if !closed { onFailure?() } }
    package func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if !closed { onFailure?() } }
    package func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                         for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    package func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                         completionHandler: @escaping @MainActor ([URL]?) -> Void) { completionHandler(nil) }
    package func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                         type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
