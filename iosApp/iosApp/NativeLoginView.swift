import SwiftUI
import WebKit

@MainActor
final class NativeLoginModel: ObservableObject {
    @Published private(set) var isWebLoading = true
    @Published private(set) var isVerifying = false
    @Published private(set) var errorMessage: String?

    let loginURL: URL?

    private let completionURL = "https://www.zhihu.com/"
    private let verifier: NativeWebLoginVerifier
    private let onLoginSuccess: () -> Void
    private var submissionGate = LoginSubmissionGate()

    init(accountStore: AccountJSONStore, onLoginSuccess: @escaping () -> Void) {
        verifier = NativeWebLoginVerifier(accountStore: accountStore)
        loginURL = URL(string: "https://www.zhihu.com/signin?next=%2F")
        self.onLoginSuccess = onLoginSuccess
    }

    func activate() {
        submissionGate.activate()
        if loginURL == nil {
            isWebLoading = false
            errorMessage = "登录地址无效"
        }
    }

    func cancelByUser() -> Bool {
        guard submissionGate.cancelByUser() else { return false }
        isVerifying = false
        return true
    }

    func cancelAfterDismissal() {
        submissionGate.deactivate()
        isVerifying = false
    }

    func navigationStarted() {
        guard !submissionGate.hasSubmission else { return }
        isWebLoading = true
        errorMessage = nil
    }

    func navigationFinished(pageURL: URL?, cookieStore: WKHTTPCookieStore) {
        isWebLoading = false
        guard LoginCompletionMatcher.matches(pageURL: pageURL, completionURL: completionURL),
              let pageURL,
              let submissionID = submissionGate.beginSubmission()
        else {
            return
        }

        isVerifying = true
        errorMessage = nil
        cookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, self.submissionGate.accepts(submissionID) else { return }
                do {
                    let cookiesJSON = try ZhihuCookieCollector.jsonString(from: cookies, for: pageURL)
                    self.completeLogin(cookiesJSON: cookiesJSON, submissionID: submissionID)
                } catch {
                    _ = self.submissionGate.finish(submissionID)
                    self.isVerifying = false
                    self.errorMessage = "无法读取登录信息，请重试"
                }
            }
        }
    }

    func navigationFailed(_ error: Error) {
        guard !submissionGate.hasSubmission else { return }
        isWebLoading = false
        errorMessage = error.localizedDescription
    }

    private func completeLogin(cookiesJSON: String, submissionID: UUID) {
        Task {
            do {
                try await verifier.verifyAndSave(cookiesJSON: cookiesJSON)
                guard submissionGate.finish(submissionID) else { return }
                isVerifying = false
                submissionGate.deactivate()
                onLoginSuccess()
            } catch {
                guard submissionGate.finish(submissionID) else { return }
                isVerifying = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

@MainActor
private final class NativeWebLoginVerifier {
    private let accountStore: AccountJSONStore

    init(accountStore: AccountJSONStore) {
        self.accountStore = accountStore
    }

    func verifyAndSave(cookiesJSON: String) async throws {
        let cookies = try RiskControlCookieCodec.cookieValues(from: cookiesJSON)
        guard cookies["d_c0"]?.isEmpty == false else { throw ZhihuAPIError.authenticationRequired }
        let candidate = try Self.accountJSON(cookies: cookies)
        let temporaryStore = NativeLoginMemoryAccountStore(json: candidate)
        let client = ZhihuAPIClient(accountStore: temporaryStore)
        let profileData = try await client.data(
            for: URL(string: "https://www.zhihu.com/api/v4/me")!,
            authentication: .accountRequired
        )
        let profile = try NativeAccountCodec.decodeProfileResponse(profileData)
        let verified = try NativeAccountCodec.merging(profile: profile, into: temporaryStore.load())
        try accountStore.save(verified)
    }

    private static func accountJSON(cookies: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "login": false,
            "username": "",
            "cookies": cookies,
            "userAgent": ZhihuAPIClient.defaultUserAgent,
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private final class NativeLoginMemoryAccountStore: AccountJSONStore, @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?
    init(json: String) { self.json = json }
    func load() throws -> String? { synchronized { json } }
    func save(_ accountJSON: String) throws { synchronized { json = accountJSON } }
    func clear() throws { synchronized { json = nil } }
    func update(_ transform: (String?) throws -> String?) throws {
        try synchronized { json = try transform(json) }
    }
    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

struct NativeLoginView: View {
    @StateObject private var model: NativeLoginModel
    private let onClose: () -> Void

    init(
        accountStore: AccountJSONStore,
        onClose: @escaping () -> Void,
        onLoginSuccess: @escaping () -> Void
    ) {
        self.onClose = onClose
        _model = StateObject(
            wrappedValue: NativeLoginModel(
                accountStore: accountStore,
                onLoginSuccess: onLoginSuccess
            )
        )
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    loginContent
                }
            } else {
                NavigationView {
                    loginContent
                }
                .navigationViewStyle(.stack)
            }
        }
        .accessibilityIdentifier("login_native_shell")
        .onAppear(perform: model.activate)
        .onDisappear(perform: model.cancelAfterDismissal)
        .interactiveDismissDisabled(model.isVerifying)
    }

    private var loginContent: some View {
        VStack(spacing: 0) {
            statusView

            if let loginURL = model.loginURL {
                NativeLoginWebView(
                    url: loginURL,
                    onNavigationStarted: model.navigationStarted,
                    onNavigationFinished: model.navigationFinished,
                    onNavigationFailed: model.navigationFailed
                )
            } else {
                Spacer()
            }
        }
        .navigationTitle("登录知乎")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    guard model.cancelByUser() else { return }
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("login_close")
                .disabled(model.isVerifying)
            }

            ToolbarItem(placement: .bottomBar) {
                Label("安全网页登录", systemImage: "globe")
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("login_mode_web")
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if model.isVerifying {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在验证登录")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("login_verify_loading")
            Divider()
        } else if model.isWebLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在加载")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("login_web_loading")
            Divider()
        } else if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
        }
    }
}

enum NativeLoginWebSessionPolicy {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        #if targetEnvironment(simulator)
        // Some simulator runtimes fail to render CJK through WebKit's system font aliases.
        configuration.userContentController.addUserScript(WKUserScript(
            source: simulatorFontFallbackScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .defaultClient
        ))
        #endif
        return configuration
    }

    #if targetEnvironment(simulator)
    private static let simulatorFontFallbackScript = """
    (() => {
        const host = location.hostname.toLowerCase();
        if (host !== 'zhihu.com' && !host.endsWith('.zhihu.com')) return;

        const installStyle = () => {
            if (!document.documentElement) return false;
            const style = document.createElement('style');
            const fontFamily = '"PingFang SC", "Helvetica Neue", sans-serif';
            style.textContent =
                ':root { --zFontSansSerif: ' + fontFamily + ' !important; }' +
                'html body { font-family: ' + fontFamily + ' !important; }';
            document.documentElement.appendChild(style);
            return true;
        };

        if (installStyle()) return;
        const observer = new MutationObserver(() => {
            if (installStyle()) observer.disconnect();
        });
        observer.observe(document, { childList: true });
    })();
    """
    #endif
}

private struct NativeLoginWebView: UIViewRepresentable {
    let url: URL
    let onNavigationStarted: () -> Void
    let onNavigationFinished: (URL?, WKHTTPCookieStore) -> Void
    let onNavigationFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = NativeLoginWebSessionPolicy.makeConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "login_webview"
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: NativeLoginWebView

        init(parent: NativeLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onNavigationStarted()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onNavigationFinished(
                webView.url,
                webView.configuration.websiteDataStore.httpCookieStore
            )
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onNavigationFailed(error)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onNavigationFailed(error)
        }
    }
}
